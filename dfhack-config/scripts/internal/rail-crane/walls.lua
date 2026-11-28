-- Terrain checks, block reservations, and native wall completion.
--@ module = true
local M = {}

local shapes = df.tiletype_shape
local tile_materials = df.tiletype_material
local MAGMA_CHAIN_REQUIRED = 'Magma requires a magma-safe chain'
local floor_shapes = {
    [shapes.FLOOR] = true,
    [shapes.PEBBLES] = true,
    [shapes.BOULDER] = true,
    [shapes.BROOK_TOP] = true,
    [shapes.RAMP] = true,
}

local function position(x, y, z)
    return {x=x, y=y, z=z}
end

local function tile(pos)
    local tiletype = dfhack.maps.getTileType(pos)
    if not tiletype then
        -- Dwarf Fortress does not allocate a map block for all open air.
        if not dfhack.maps.isValidTilePos(pos) then return end
        tiletype = df.tiletype.OpenSpace
    end
    local designation, occupancy = dfhack.maps.getTileFlags(pos)
    return df.tiletype.attrs[tiletype], designation, occupancy
end

local function at_height(pos, z)
    return position(pos.x, pos.y, z)
end

local function is_floor(attrs)
    return floor_shapes[attrs.shape]
        and attrs.special ~= df.tiletype_special.TRACK
        and attrs.material ~= tile_materials.FROZEN_LIQUID
        and attrs.material ~= tile_materials.TREE
        and attrs.material ~= tile_materials.PLANT
        and attrs.material ~= tile_materials.FIRE
        and attrs.material ~= tile_materials.CAMPFIRE
end

local function is_open(attrs)
    return attrs.shape == shapes.EMPTY or attrs.shape == shapes.RAMP_TOP
end

local function has_magma(designation)
    return designation and designation.flow_size > 0 and designation.liquid_type
end

local function blocked(pos, designation, occupancy, magma_safe)
    if designation and designation.hidden then return 'Tile is unrevealed' end
    if not magma_safe and has_magma(designation) then return MAGMA_CHAIN_REQUIRED end
    if occupancy and (occupancy.building ~= df.tile_building_occ.None or occupancy.vehicle) then
        return 'A building or vehicle blocks this column'
    end
    if dfhack.buildings.findAtTile(pos) then return 'A building blocks this column' end
end

function M.clearance(pos, platform_z, magma_safe)
    if pos.z > platform_z then return nil, 'Above the crane platform' end
    for z = pos.z + 1, platform_z do
        local over = at_height(pos, z)
        local attrs, designation, occupancy = tile(over)
        if not attrs or not is_open(attrs) then
            return nil, 'Overhead terrain blocks the cable at z=' .. z
        end
        local reason = blocked(over, designation, occupancy, magma_safe)
        if reason then return nil, reason .. ' at z=' .. z end
    end
    return true
end

function M.checkMagma(pos, platform_z)
    for z = pos.z, platform_z do
        if has_magma(dfhack.maps.getTileFlags(at_height(pos, z))) then
            return nil, MAGMA_CHAIN_REQUIRED .. ' at z=' .. z
        end
    end
    return true
end

function M.isWall(pos)
    local attrs = tile(pos)
    if not attrs or attrs.shape ~= shapes.WALL or attrs.material ~= tile_materials.CONSTRUCTION then
        return false
    end
    local construction = dfhack.constructions.findAtTile(pos)
    return construction ~= nil and not construction.flags.top_of_wall
end

local function solid_below(pos)
    if pos.z == 0 then return false end
    local attrs = tile(at_height(pos, pos.z - 1))
    return attrs and (attrs.shape == shapes.WALL or attrs.shape == shapes.BROOK_BED)
        and attrs.material ~= tile_materials.FROZEN_LIQUID
        and attrs.material ~= tile_materials.TREE
end

-- Returns the first wall level, leaving the requested top level to the caller.
function M.inspect(pos, platform_z, magma_safe)
    local clear, reason = M.clearance(pos, platform_z, magma_safe)
    if not clear then return nil, reason end
    if M.isWall(pos) then return nil, 'A constructed wall is already at the selected height' end
    for z = pos.z, 0, -1 do
        local current = at_height(pos, z)
        local attrs, designation, occupancy = tile(current)
        if not attrs then return nil, 'Outside the fortress map' end
        reason = blocked(current, designation, occupancy, magma_safe)
        if reason then return nil, reason .. ' at z=' .. z end
        if is_floor(attrs) then return z end
        if not is_open(attrs) then return nil, 'Terrain blocks the column at z=' .. z end
        if solid_below(current) then return z end
    end
    return nil, 'No solid foundation under this column'
end

function M.checkLift(pos, platform_z, magma_safe)
    local bottom, reason = M.inspect(pos, platform_z, magma_safe)
    if not bottom then return nil, reason end
    if bottom ~= pos.z then return nil, 'The wall needs support directly below it' end
    local _, occupancy = dfhack.maps.getTileFlags(pos)
    if occupancy and (occupancy.unit or occupancy.unit_grounded or occupancy.item) then
        return nil, 'A creature or loose item is in the wall footprint'
    end
    return true
end

local function has_job_reference(item)
    return dfhack.items.getSpecificRef(item, df.specific_ref_type.JOB) ~= nil
end

local function workshop_output(item, cache)
    local holder = dfhack.items.getHolderBuilding(item)
    if not holder then return end
    local kind = holder:getType()
    if kind ~= df.building_type.Workshop and kind ~= df.building_type.Furnace then return end

    local contents = cache[holder.id]
    if not contents then
        contents = {}
        for _, entry in ipairs(holder.contained_items) do
            if entry.item and entry.use_mode == df.building_item_role_type.TEMP then
                contents[entry.item.id] = true
            end
        end
        cache[holder.id] = contents
    end
    if contents[item.id] then
        return position(holder.centerx, holder.centery, holder.z)
    end
end

local function stock_location(item, reserved, outputs)
    local flags = item.flags
    if flags.removed or flags.garbage_collect or flags.forbid or flags.dump or flags.melt
        or flags.construction or flags.in_building or flags.owned or flags.artifact
        or flags.hostile or flags.trader or flags.encased or flags.on_fire or flags.spider_web
        or ((flags.hidden or flags.in_job) and not reserved)
        or #item.specific_refs ~= 0 or item.world_data_id ~= -1
        or item:getStackSize() < 1 then
        return
    end
    if flags.on_ground then return item.pos end
    if flags.in_inventory then
        local container = dfhack.items.getContainer(item)
        if not container then return end
        local outer = dfhack.items.getOuterContainerRef(container)
        local bin = outer and outer.object
        if not bin or not df.item:is_instance(bin) then return end
        local outer_flags = bin.flags
        if outer_flags.on_ground and not outer_flags.in_job and not outer_flags.forbid
            and not outer_flags.dump and not outer_flags.hostile and not outer_flags.trader then
            return bin.pos
        end
        return
    end
    -- Fresh workshop products are TEMP building contents until hauled out.
    return workshop_output(item, outputs)
end

local function available(visit, token)
    local outputs = {}
    for _, item in ipairs(df.global.world.items.other.BLOCKS) do
        local location = stock_location(item, false, outputs)
        if location and dfhack.maps.isValidTilePos(location) then
            local material = dfhack.matinfo.decode(item)
            if material and (not token or token == material:getToken()) then
                local stop = visit(item, material, location)
                if stop then return stop end
            end
        end
    end
end

local function distance(origin, location)
    return math.abs(origin.x - location.x) + math.abs(origin.y - location.y) + math.abs(origin.z - location.z)
end

function M.materials(origin)
    local choices, by_token = {}, {}
    available(function(item, material, location)
        local token = material:getToken()
        local entry = by_token[token]
        if not entry then
            entry = {token=token, label=dfhack.capitalizeStringWords(material:toString()), count=0}
            by_token[token] = entry
            choices[#choices + 1] = entry
        end
        entry.count = entry.count + item:getStackSize()
        if origin then
            local tiles = distance(origin, location)
            entry.distance = math.min(entry.distance or tiles, tiles)
        end
    end)
    table.sort(choices, function(a, b)
        if a.distance ~= b.distance then return a.distance < b.distance end
        if a.label ~= b.label then return a.label < b.label end
        return a.token < b.token
    end)
    return choices
end

function M.closest(origin)
    local choice = M.materials(origin)[1]
    return choice and choice.token
end

function M.countAvailable(token)
    local count = 0
    available(function(item) count = count + item:getStackSize() end, token)
    return count
end

local function reserve_block(item)
    if item:getStackSize() > 1 then
        local single = item:splitStack(1, true)
        if not single or single.id == item.id then return end
        -- Native splitting registers the new ID but leaves type vectors to callers.
        single:categorize(true)
        if single:getStackSize() ~= 1 or not stock_location(single, false, {}) then return end
        item = single
    end
    -- The crane owns this claim by item ID. Native jobs use the same flag
    -- and also have an actual job reference, which the crane never clears.
    item.flags.in_job = true
    return item.id
end

function M.reserve(token, origin)
    if not origin then return available(reserve_block, token) end

    local matches = {}
    available(function(item, _, location)
        matches[#matches + 1] = {item=item, distance=distance(origin, location)}
    end, token)
    table.sort(matches, function(a, b)
        if a.distance ~= b.distance then return a.distance < b.distance end
        return a.item.id < b.item.id
    end)
    for _, match in ipairs(matches) do
        local id = reserve_block(match.item)
        if id then return id end
    end
end

function M.resolve(id, token)
    local item = id and df.item.find(id)
    if not item or item:getType() ~= df.item_type.BLOCKS or not item.flags.in_job
        or item:getStackSize() ~= 1 or not stock_location(item, true, {}) then return end
    local material = dfhack.matinfo.decode(item)
    if material and material:getToken() == token then return item end
end

function M.release(id)
    local item = id and df.item.find(id)
    if not item or item:getType() ~= df.item_type.BLOCKS or has_job_reference(item)
        or item.flags.removed or item.flags.garbage_collect then return end
    item.flags.in_job = false
    item.flags.hidden = false
end

function M.stage(id, token, rear)
    local item = M.resolve(id, token)
    if not item or not dfhack.maps.getTileBlock(rear) or not dfhack.items.moveToGround(item, rear) then
        return nil, 'Could not stage the reserved block on the rear platform'
    end
    item.flags.in_job = true
    return true
end

function M.lift(id, token)
    local item = M.resolve(id, token)
    if not item then return nil, 'The reserved block is unavailable' end
    item.flags.hidden = true
    return true
end

local function create_wall_job(pos, item, designation)
    -- DFHack's planned-building placement rejects fluid over depth one. The
    -- suspension is synchronous and scoped to the exact footprint. Restore the
    -- original depth before native completion.
    local depth = designation.flow_size
    local was_hidden = item.flags.hidden
    designation.flow_size = 0
    item.flags.in_job = false
    item.flags.hidden = false
    local ok, building, failure = pcall(dfhack.buildings.constructBuilding, {
        pos=pos,
        type=df.building_type.Construction,
        subtype=df.construction_type.Wall,
        items={item},
    })
    designation.flow_size = depth
    if not ok or not building then
        if not has_job_reference(item) then
            item.flags.in_job = true
            item.flags.hidden = was_hidden
        end
        return nil, tostring(ok and failure or building)
    end
    return building
end

function M.place(pos, id, token, platform_z, magma_safe)
    local clear, reason = M.checkLift(pos, platform_z, magma_safe)
    if not clear then return nil, reason end
    local item = M.resolve(id, token)
    if not item then return nil, 'The reserved block is unavailable' end
    local block = dfhack.maps.ensureTileBlock(pos)
    if not block then return nil, 'The wall tile is unavailable' end
    local designation = block.designation[pos.x % 16][pos.y % 16]
    local building, failure = create_wall_job(pos, item, designation)
    if not building then return nil, 'Could not start native wall construction. ' .. failure end

    -- TEMP is required for a native construction. DF converts the placed
    -- item into a construction record and handles subsequent deconstruction.
    local job = building.jobs[0]
    if not dfhack.job.removeJob(job) or not dfhack.items.moveToBuilding(item, building, df.building_item_role_type.TEMP) then
        dfhack.buildings.deconstruct(building)
        return nil, 'Could not deliver the reserved block to native wall construction'
    end
    building:setBuildStage(building:getMaxBuildStage())
    dfhack.buildings.completeBuild(building)
    if not M.isWall(pos) then return nil, 'Dwarf Fortress did not complete the wall' end

    -- Solid masonry displaces liquid in its own square.
    designation.flow_size = 0
    designation.flow_forbid = false
    dfhack.maps.enableBlockUpdates(block, true, true)
    df.global.world.reindex_pathfinding = true
    return true
end

for name, fn in pairs(M) do _ENV[name] = fn end
return M
