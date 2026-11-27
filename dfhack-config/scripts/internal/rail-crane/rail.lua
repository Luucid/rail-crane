--@ module = true

local maps = dfhack.maps

function xykey(pos)
    return ('%d,%d'):format(pos.x, pos.y)
end

function coordinates(pos)
    return ('(%d,%d,%d)'):format(pos.x, pos.y, pos.z)
end

local function attrs(pos)
    local tile = maps.getTileType(pos)
    return tile and df.tiletype.attrs[tile], tile and df.tiletype[tile]
end

local function dryFloor(pos, dockId)
    local attr = attrs(pos)
    if not attr or df.tiletype_shape.attrs[attr.shape].basic_shape ~= df.tiletype_shape_basic.Floor then
        return false
    end
    local des, occ = maps.getTileFlags(pos)
    if not des or des.hidden or des.flow_size > 0 or occ.vehicle then return false end
    if occ.building == df.tile_building_occ.None then return true end
    local building = dockId and dfhack.buildings.findAtTile(pos)
    return building and building.id == dockId
end

local function openAbove(x, y, z, allowWallTop)
    local pos = {x=x, y=y, z=z}
    if not maps.isValidTilePos(pos) then return false end
    local attr = attrs(pos)
    if not attr then return true end
    local des, occ = maps.getTileFlags(pos)
    if not des or des.hidden or des.flow_size > 0 or occ.building ~= df.tile_building_occ.None then
        return false
    end
    if attr.shape == df.tiletype_shape.EMPTY or attr.shape == df.tiletype_shape.RAMP_TOP then
        return true
    end
    if allowWallTop and attr.material == df.tiletype_material.CONSTRUCTION then
        local construction = dfhack.constructions.findAtTile(pos)
        return construction and construction.flags.top_of_wall
    end
    return false
end

function stations(crane, index)
    local pivot = crane.rail[index]
    return pivot, {
        x=pivot.x + crane.dx * crane.rear,
        y=pivot.y + crane.dy * crane.rear,
        z=pivot.z,
    }
end

local function trackDirections(pos, dockId, topologyOnly)
    local attr, name = attrs(pos)
    if not attr or attr.shape ~= df.tiletype_shape.FLOOR or attr.special ~= df.tiletype_special.TRACK
        or (not topologyOnly and not dryFloor(pos, dockId)) then
        return nil
    end
    return name and name:match('Track([NSEW]+)$')
end

local function trackAxis(pos, dockId, topologyOnly)
    local directions = pos and trackDirections(pos, dockId, topologyOnly)
    if not directions then return end
    if not directions:find('[NS]') then return 1, 0 end
    if not directions:find('[EW]') then return 0, 1 end
end

local function trackValid(crane, index)
    local directions = trackDirections(crane.rail[index], crane.building_id)
    if not directions then return false end
    local backward, forward = 'N', 'S'
    if crane.dx == 1 then backward, forward = 'W', 'E' end
    return not directions:find('[^' .. backward .. forward .. ']')
        and (index == 1 or directions:find(backward, 1, true))
        and (index == #crane.rail or directions:find(forward, 1, true))
end

function stopValid(crane, index)
    local operator, rear = stations(crane, index)
    if not trackValid(crane, index) then
        return false, 'Requires connected, level, straight tracks at ' .. coordinates(operator)
    end
    if not dryFloor(rear, crane.building_id) then
        return false, 'Requires a dry rear platform floor at ' .. coordinates(rear)
    end
    if not openAbove(operator.x, operator.y, operator.z + 1) or not openAbove(rear.x, rear.y, rear.z + 1) then
        return false, 'The carriage needs open air above the operator and rear platform at ' .. coordinates(operator)
    end
    return true
end

local function segment(start, dockId, dx, dy, topologyOnly)
    local directions = trackDirections(start, dockId, topologyOnly)
    local backward, forward = dx == 1 and 'W' or 'N', dx == 1 and 'E' or 'S'
    local offAxis = '[^' .. backward .. forward .. ']'
    if not directions or directions:find(offAxis) then return end
    local function at(offset)
        return {x=start.x + offset * dx, y=start.y + offset * dy, z=start.z}
    end
    local function endpoint(step, out, back)
        local offset, connections = 0, directions
        while connections:find(out, 1, true) do
            local adjacent = at(offset + step)
            local nextDirections = trackDirections(adjacent, dockId, topologyOnly)
            if not nextDirections or nextDirections:find(offAxis)
                or not nextDirections:find(back, 1, true)
                or (not topologyOnly and not openAbove(adjacent.x, adjacent.y, adjacent.z + 1)) then
                break
            end
            offset, connections = offset + step, nextDirections
        end
        return offset
    end
    return at, endpoint(-1, backward, forward), endpoint(1, forward, backward)
end

function trackSpan(pos)
    local dx, dy = trackAxis(pos, nil, true)
    if not dx then return end
    local at, first, last = segment(pos, nil, dx, dy, true)
    return at(first), at(last)
end

local function fitRear(at, low, high, rear, dockId)
    local margin = at((rear == -1 and low or high) + rear)
    if not dryFloor(margin, dockId) or not openAbove(margin.x, margin.y, margin.z + 1) then
        if rear == -1 then low = low + 1 else high = high - 1 end
    end
    return low, high
end

local function makePositions(at, low, high)
    local positions = {}
    for offset = low, high do positions[#positions + 1] = at(offset) end
    return positions
end

function discover(start, dockId)
    local dx, dy = trackAxis(start, dockId)
    if not dx then
        return nil, 'Choose a straight, level minecart track tile.'
    end
    local at, first, last = segment(start, dockId, dx, dy, false)
    if first == last then return nil, 'Connect at least two straight, level track tiles.' end
    local best
    for _, rear in ipairs({-1, 1}) do
        local low, high = fitRear(at, first, last, rear, dockId)
        if low <= 0 and high >= 0 and low < high and (not best or high - low + 1 > #best.rail) then
            local crane = {
                rail=makePositions(at, low, high), dx=dx, dy=dy, reach=3, rear=rear, index=1-low, queue={},
                building_id=dockId, dock={x=start.x,y=start.y,z=start.z},
            }
            local valid = stopValid(crane, crane.index)
            if valid then best = crane end
        end
    end
    if not best then return nil, 'The crane needs a dry rear deck and open space above the track.' end
    return best
end

function updatedRun(crane)
    -- Start at the occupied tile so removing a rail never moves the carriage.
    local pivot = crane.rail[crane.index]
    local at, low, high = segment(pivot, crane.building_id, crane.dx, crane.dy, true)
    if not at then return end
    local trackStart = at(low)
    low, high = fitRear(at, low, high, crane.rear, crane.building_id)
    if low > 0 or high < 0 or (1 - low == crane.index and high - low + 1 == #crane.rail) then
        return nil, nil, trackStart
    end
    return makePositions(at, low, high), 1 - low, trackStart
end

function footprint(crane)
    local tiles = {}
    for i = 1, #crane.rail do
        local pivot, rear = stations(crane, i)
        tiles[xykey(pivot)], tiles[xykey(rear)] = true, true
    end
    return tiles
end

function inRange(crane, pivot, target)
    local dx, dy = target.x - pivot.x, target.y - pivot.y
    return target.z <= pivot.z and dx * dx + dy * dy <= crane.reach * crane.reach
end

function boomClear(pivot, target)
    local x, y = pivot.x, pivot.y
    local dx, dy = math.abs(target.x - x), -math.abs(target.y - y)
    local sx, sy = x < target.x and 1 or -1, y < target.y and 1 or -1
    local err = dx + dy
    while true do
        if not openAbove(x, y, pivot.z + 1, true) then return false end
        if x == target.x and y == target.y then return true end
        local step = 2 * err
        if step >= dy then err, x = err + dy, x + sx end
        if step <= dx then err, y = err + dx, y + sy end
    end
end

function stopFor(crane, target)
    local index = crane.index
    local first = crane.rail[1]
    if target.z > first.z then return nil end

    local x, y = target.x - first.x, target.y - first.y
    local projection = 1 + x * crane.dx + y * crane.dy
    local lateral = x * crane.dy - y * crane.dx
    local reachAlongTrack = crane.reach ^ 2 - lateral ^ 2
    if reachAlongTrack < 0 or not stopValid(crane, index) then return nil end
    local span = math.floor(math.sqrt(reachAlongTrack))

    local best, bestOffset, bestTravel
    local function consider(i)
        local offset, travel = math.abs(i - projection), math.abs(i - index)
        if offset > span or (best and (offset > bestOffset or (offset == bestOffset and travel >= bestTravel))) then
            return false
        end
        if not boomClear(crane.rail[i], target) then return false end
        best, bestOffset, bestTravel = i, offset, travel
        return offset == 0
    end
    if consider(index) then return index end
    local last = math.min(#crane.rail, projection + span)
    for i = index + 1, last do
        if not stopValid(crane, i) then break end
        if consider(i) then return i end
    end
    local earliest = math.max(1, projection - span)
    for i = index - 1, earliest, -1 do
        if not stopValid(crane, i) then break end
        if consider(i) then return i end
    end
    return best
end

function reachable(crane, z)
    local tiles, seen = {}, footprint(crane)
    if z > crane.rail[1].z then return tiles end
    for _, pivot in ipairs(crane.rail) do
        for y = pivot.y - crane.reach, pivot.y + crane.reach do
            for x = pivot.x - crane.reach, pivot.x + crane.reach do
                local pos = {x=x, y=y, z=z}
                local key = xykey(pos)
                if not seen[key] and inRange(crane, pivot, pos) and maps.isValidTilePos(pos) then
                    seen[key] = true
                    tiles[#tiles + 1] = pos
                end
            end
        end
    end
    return tiles
end
