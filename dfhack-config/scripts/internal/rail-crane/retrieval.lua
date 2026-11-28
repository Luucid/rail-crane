--@ module = true

local walls = reqscript('internal/rail-crane/walls')
local maps = dfhack.maps
local items = dfhack.items

local function onGround(item, pos)
    if not item then return false end
    local flags = item.flags
    if not flags.on_ground or flags.removed or flags.garbage_collect or flags.in_inventory
        or flags.in_building or flags.construction or flags.encased then return false end
    local x, y, z = items.getPosition(item)
    return x == pos.x and y == pos.y and z == pos.z
end

local function hasJob(item)
    return items.getSpecificRef(item, df.specific_ref_type.JOB) ~= nil
end

local function available(item)
    local flags = item.flags
    return not (flags.in_job or flags.hidden or flags.trader or flags.spider_web
        or item.flags2.has_rider or hasJob(item))
end

function atSource(pickup)
    local item = df.item.find(pickup.item_id)
    if onGround(item, pickup.pos) then return item end
end

function itemsAt(pos)
    local found = {}
    local block = maps.getTileBlock(pos)
    if not block then return found end
    for _, id in ipairs(block.items) do
        local item = df.item.find(id)
        if onGround(item, pos) and available(item) then found[#found + 1] = id end
    end
    return found
end

function countGround(pos)
    local count = 0
    local block = maps.getTileBlock(pos)
    if not block then return 0 end
    for _, id in ipairs(block.items) do
        if onGround(df.item.find(id), pos) then count = count + 1 end
    end
    return count
end

function access(pos, platform_z, magma_safe, drop)
    if not maps.isValidTilePos(pos) then return nil, 'Tile is outside the map.' end
    local tile = maps.getTileType(pos)
    local des, occ = maps.getTileFlags(pos)
    if not tile or not des or des.hidden then return nil, 'Choose a revealed tile.' end
    local shape = df.tiletype_shape.attrs[df.tiletype.attrs[tile].shape]
    if not shape.passable_high or occ.vehicle then return nil, 'The hook cannot reach this tile.' end
    local building = dfhack.buildings.findAtTile(pos)
    if building and building:getType() ~= df.building_type.Stockpile then
        return nil, 'A building blocks the hook.'
    end
    if drop and (shape.basic_shape ~= df.tiletype_shape_basic.Floor or des.flow_size > 0) then
        return nil, 'Choose a dry floor for the drop area.'
    end
    if not magma_safe then
        local ok, reason = walls.checkMagma(pos, pos.z)
        if not ok then return nil, reason end
    end
    return walls.clearance(pos, platform_z, magma_safe)
end

function area(a, b)
    return {x1=math.min(a.x,b.x), x2=math.max(a.x,b.x),
        y1=math.min(a.y,b.y), y2=math.max(a.y,b.y), z=a.z}
end

function inArea(pos, zone)
    return zone and pos.z == zone.z and zone.x1 <= pos.x and pos.x <= zone.x2
        and zone.y1 <= pos.y and pos.y <= zone.y2
end

function reserve(item)
    if not available(item) then return false end
    item.flags.in_job = true
    return true
end

function resolve(pickup)
    local item = atSource(pickup)
    if item and item.flags.in_job and not hasJob(item) then return item end
end

function lift(pickup, platform_z, magma_safe)
    local ok, reason = access(pickup.pos, platform_z, magma_safe)
    if not ok then return nil, reason end
    local item = resolve(pickup)
    if not item then return nil, 'The pickup item became unavailable' end
    -- Keep the reserved item at its source until the drop succeeds. A retry or
    -- reload only needs to clear the reservation to put the item back in play.
    item.flags.hidden = true
    return true
end

function release(id)
    local item = df.item.find(id)
    if item and not item.flags.removed and not item.flags.garbage_collect and not hasJob(item) then
        item.flags.in_job, item.flags.hidden = false, false
    end
end

function place(pickup, target, platform_z, magma_safe)
    local ok, reason = access(target, platform_z, magma_safe, true)
    if not ok then return nil, reason end
    local _, occ = maps.getTileFlags(target)
    if occ.unit or occ.unit_grounded then return nil, 'Holding the item until the drop tile clears', true end
    local item = resolve(pickup)
    if not item then return nil, 'The item is no longer at the pickup tile' end
    local forbidden = item.flags.forbid
    if not items.moveToGround(item, target) then return nil, 'Could not put the item down' end
    item.flags.in_job, item.flags.hidden, item.flags.forbid = false, false, forbidden
    return true
end
