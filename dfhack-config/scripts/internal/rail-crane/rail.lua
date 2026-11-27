--@ module = true

local maps = dfhack.maps
local directions = {
    {out='N', back='S', x=0, y=-1},
    {out='E', back='W', x=1, y=0},
    {out='S', back='N', x=0, y=1},
    {out='W', back='E', x=-1, y=0},
}
local sides = {-1, 1}

function xykey(pos)
    return ('%d,%d'):format(pos.x, pos.y)
end

function coordinates(pos)
    return ('(%d,%d,%d)'):format(pos.x, pos.y, pos.z)
end

function samePosition(a, b)
    return a and b and a.x == b.x and a.y == b.y and a.z == b.z
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

local function shaftClear(pos, height)
    for z = pos.z + 1, pos.z + height + 1 do
        if not openAbove(pos.x, pos.y, z) then return false end
    end
    return true
end

function buildLevel(crane)
    return crane.rail[1].z + (crane.height or 0)
end

function boomPosition(crane, index)
    local pivot = crane.rail[index]
    return {x=pivot.x, y=pivot.y, z=buildLevel(crane)}
end

function nextIndex(crane, index, step)
    local nextIndex = index + step
    if crane.closed then return (nextIndex - 1) % #crane.rail + 1 end
    if crane.rail[nextIndex] then return nextIndex end
end

function stations(crane, index)
    local pivot = crane.rail[index]
    local rear = crane.rail[nextIndex(crane, index, crane.rear)]
    if rear then return pivot, rear end
    local front = crane.rail[nextIndex(crane, index, -crane.rear)]
    local dx = front and pivot.x - front.x or crane.dx * crane.rear
    local dy = front and pivot.y - front.y or crane.dy * crane.rear
    return pivot, {x=pivot.x + dx, y=pivot.y + dy, z=pivot.z}
end

local function trackDirections(pos)
    local attr, name = attrs(pos)
    if not attr or attr.shape ~= df.tiletype_shape.FLOOR or attr.special ~= df.tiletype_special.TRACK then return end
    return name and name:match('Track([NSEW]+)$')
end

local function follows(pos, adjacent, direction)
    local exits = trackDirections(pos)
    local incoming = exits and exits:find(direction.out, 1, true) and trackDirections(adjacent)
    return incoming and incoming:find(direction.back, 1, true) ~= nil
end

local function connections(pos, exits)
    local neighbors = {}
    for _, direction in ipairs(directions) do
        if exits:find(direction.out, 1, true) then
            local adjacent = {x=pos.x + direction.x, y=pos.y + direction.y, z=pos.z}
            local incoming = trackDirections(adjacent)
            if incoming and incoming:find(direction.back, 1, true) then neighbors[#neighbors + 1] = adjacent end
        end
    end
    return neighbors
end

local function before(a, b)
    return not b or a.y < b.y or (a.y == b.y and a.x < b.x)
end

function trackNetwork(start)
    if not trackDirections(start) then return end
    local network = {z=start.z, members={}}
    local tiles, seen = {start}, {[xykey(start)]=true}
    local first, endpoint
    local i = 1
    while i <= #tiles do
        local pos = tiles[i]
        local neighbors = connections(pos, trackDirections(pos))
        network.members[xykey(pos)] = neighbors
        if before(pos, first) then first = pos end
        if #neighbors < 2 and before(pos, endpoint) then endpoint = pos end
        if #neighbors > 2 then network.branched = true end
        for _, adjacent in ipairs(neighbors) do
            local key = xykey(adjacent)
            if not seen[key] then
                seen[key] = true
                tiles[#tiles + 1] = adjacent
            end
        end
        i = i + 1
    end
    network.key = coordinates(first)
    if network.branched then return network end

    -- Order an open route from one end, or a loop from a stable tile.
    local route, indices = {}, {}
    local pos = endpoint or first
    while pos do
        local key = xykey(pos)
        route[#route + 1] = pos
        indices[key] = #route
        pos = nil
        for _, adjacent in ipairs(network.members[key]) do
            if not indices[xykey(adjacent)] then
                pos = adjacent
                break
            end
        end
    end
    network.rail, network.indices, network.closed = route, indices, not endpoint
    return network
end

function stopValid(crane, index)
    if not index or not crane.rail[index] then return false, 'The track ends here' end
    local operator, rear = stations(crane, index)
    if crane.stationary then
        if not dryFloor(operator, crane.building_id) then
            return false, 'Requires a dry crane base at ' .. coordinates(operator)
        end
    else
        local exits = trackDirections(operator)
        if not exits or not dryFloor(operator, crane.building_id) then
            return false, 'Requires dry, level track at ' .. coordinates(operator)
        end
        if #exits > 2 and #connections(operator, exits) > 2 then
            return false, 'The crane cannot pass a rail junction at ' .. coordinates(operator)
        end
    end
    if not dryFloor(rear, crane.building_id) then
        return false, 'Requires a dry rear platform floor at ' .. coordinates(rear)
    end
    local height = crane.height or 0
    if not shaftClear(operator, height) or not shaftClear(rear, height) then
        return false, 'Keep open air above the crane and rear platform at ' .. coordinates(operator)
    end
    return true
end

function stepValid(crane, from, to)
    if not stopValid(crane, to) then return false end
    local pos, adjacent = crane.rail[from], crane.rail[to]
    for _, direction in ipairs(directions) do
        if direction.x == adjacent.x - pos.x and direction.y == adjacent.y - pos.y then
            return follows(pos, adjacent, direction)
        end
    end
    return false
end

local function visitStops(crane, visit)
    if not stopValid(crane, crane.index) then return end
    if visit(crane.index) then return end
    -- Walk both directions in distance order, visiting each stop once.
    local seen = {[crane.index]=true}
    local cursors = {crane.index, crane.index}
    while cursors[1] or cursors[2] do
        for i, side in ipairs(sides) do
            local from = cursors[i]
            local to = from and nextIndex(crane, from, side)
            cursors[i] = nil
            if to and not seen[to] and stepValid(crane, from, to) then
                seen[to], cursors[i] = true, to
                if visit(to, side) then return end
            end
        end
    end
end

function discover(start, dockId, height, conflict, network)
    height = math.tointeger(height or 0)
    if not height or height < 0 then return nil, 'Choose a nonnegative boom height.' end
    if not dryFloor(start, dockId) then return nil, 'Choose an available dry floor or level track.' end
    if not shaftClear(start, height) then return nil, 'Keep open air through and above the mast.' end

    local dock = {x=start.x, y=start.y, z=start.z}
    local reason
    local function candidate(positions, index, dx, dy, rear, stationary, closed)
        local crane = {
            rail=positions, index=index, dx=dx, dy=dy, rear=rear, height=height,
            stationary=stationary, closed=closed, reach=3, queue={}, building_id=dockId, dock=dock,
        }
        local valid, blocked = stopValid(crane, crane.index)
        if valid then blocked = conflict and conflict(crane) end
        if valid and not blocked then return crane end
        reason = blocked
    end

    if not network then
        local attr = attrs(start)
        if attr.special == df.tiletype_special.TRACK then
            return nil, 'Choose a level track or a dry floor for the crane.'
        end
        for _, axis in ipairs({{1,0}, {0,1}}) do
            for _, rear in ipairs(sides) do
                local crane = candidate({dock}, 1, axis[1], axis[2], rear, true)
                if crane then return crane end
            end
        end
        return nil, reason
    end

    if network.branched then return nil, 'Choose a rail route without junctions.' end
    local index = network.indices[xykey(start)]
    local adjacent = network.rail[index + 1] or network.rail[index - 1]
    local horizontal
    if adjacent then
        horizontal = adjacent.x ~= start.x
    else
        horizontal = trackDirections(start):find('[EW]') ~= nil
    end
    local dx, dy = horizontal and 1 or 0, horizontal and 0 or 1
    local best, bestCount = nil, 0
    for _, rear in ipairs(sides) do
        local crane = candidate(network.rail, index, dx, dy, rear, false, network.closed)
        if crane then
            local count = 0
            visitStops(crane, function() count = count + 1 end)
            if count > bestCount then best, bestCount = crane, count end
        end
    end
    if best then return best end
    return nil, reason or 'The crane needs a dry rear platform and clear mast space.'
end

function updatedRun(crane)
    if crane.stationary then return end
    -- Start at the occupied tile so removing a rail never moves the carriage.
    local pivot, oldRear = stations(crane, crane.index)
    local network = trackNetwork(pivot)
    if not network then return end
    if network.branched then return nil, network.key end
    local unchanged = network.closed == (crane.closed == true) and #network.rail == #crane.rail
    if unchanged then
        for i, pos in ipairs(network.rail) do
            if not samePosition(pos, crane.rail[i]) then
                unchanged = false
                break
            end
        end
    end
    if unchanged then return nil, network.key end
    local route = {
        rail=network.rail, indices=network.indices, index=network.indices[xykey(pivot)],
        rear=crane.rear, closed=network.closed, dx=crane.dx, dy=crane.dy, height=crane.height,
        building_id=crane.building_id,
    }
    local _, sameSide = stations(route, route.index)
    if not samePosition(oldRear, sameSide) then
        route.rear = -route.rear
        local _, otherSide = stations(route, route.index)
        if not samePosition(oldRear, otherSide) then route.rear = crane.rear end
    end
    return route, network.key
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
    return target.z <= buildLevel(crane) and dx * dx + dy * dy <= crane.reach * crane.reach
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
    if target.z > buildLevel(crane) then return nil end
    local best, bestStep, bestDistance, bestAligned
    visitStops(crane, function(i, step)
        local pivot = boomPosition(crane, i)
        local dx, dy = target.x - pivot.x, target.y - pivot.y
        local distance = dx * dx + dy * dy
        local aligned = dx == 0 or dy == 0
        if distance > crane.reach ^ 2 then return end
        if best then
            if bestAligned and not aligned then return end
            if bestAligned == aligned and distance >= bestDistance then return end
        end
        if not boomClear(pivot, target) then return end
        best, bestStep, bestDistance, bestAligned = i, step, distance, aligned
        return distance <= 1 and aligned
    end)
    return best, bestStep
end

function reachable(crane, z)
    local tiles, seen = {}, footprint(crane)
    if z > buildLevel(crane) then return tiles end
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
