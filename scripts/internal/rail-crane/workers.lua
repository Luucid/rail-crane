--@module = true

local STORAGE_KEY = 'rail-crane/worker-stations'
local STUCK_TICKS = 360
local stations
local unavailable = {}

local function point(pos)
    return {x=pos.x, y=pos.y, z=pos.z}
end

local function same(a, b)
    return a and b and a.x == b.x and a.y == b.y and a.z == b.z
end

local function ledger()
    if not stations then
        stations = dfhack.persistent.getSiteData(STORAGE_KEY, {})
    end
    return stations
end

local function save()
    if next(ledger()) then
        dfhack.persistent.saveSiteData(STORAGE_KEY, stations)
    else
        dfhack.persistent.deleteSiteData(STORAGE_KEY)
    end
end

local function eligible(unit)
    return unit and dfhack.units.isActive(unit) and dfhack.units.isCitizen(unit)
        and dfhack.units.isDwarf(unit) and dfhack.units.isAdult(unit)
        and unit.military.squad_id < 0 and not unit.following
        and not unit.flags1.caged and not unit.flags1.chained and not unit.flags1.rider
        and not unit.flags1.has_mood and not unit.job.current_job
        and unit.counters.unconscious == 0 and unit.counters.stunned == 0
        and unit.counters.webbed == 0 and unit.counters.suffocation == 0
        and unit.counters.soldier_mood == df.soldier_mood_type.None
end

local function reachable(unit, pos)
    local designation = dfhack.maps.getTileFlags(pos)
    if not designation or designation.hidden or designation.flow_size > 3
        or (designation.liquid_type and designation.flow_size > 0)
        or not dfhack.maps.canWalkBetween(unit.pos, pos) then
        return false
    end
    if #unit.burrows == 0 then return true end
    for _, id in ipairs(unit.burrows) do
        local burrow = df.burrow.find(id)
        if burrow and dfhack.burrows.isAssignedTile(burrow, pos) then return true end
    end
    return false
end

local function hasStation(unit, assignment)
    return unit.idle_area_type == df.unit_station_type.Commander
        and unit.idle_area_threshold == 0 and unit.follow_distance == 50
        and same(unit.idle_area, assignment.pos)
end

local function restore(unit, assignment)
    if not unit then return end
    -- Clear the station and path only while their destination still belongs to us.
    if hasStation(unit, assignment) then
        unit.idle_area:assign(assignment.old_station)
        unit.idle_area_type = assignment.old_station_type
        unit.idle_area_threshold = assignment.old_threshold
        unit.follow_distance = assignment.old_follow_distance
    end
    if not unit.job.current_job and unit.path.goal == df.unit_path_goal.SeekStation
        and same(unit.path.dest, assignment.pos) then
        dfhack.units.setPathGoal(unit, assignment.old_destination, assignment.old_goal)
    end
end

function release(unit_id)
    if not unit_id then return end
    local key = tostring(unit_id)
    local assignment = ledger()[key]
    if not assignment then return end
    restore(df.unit.find(unit_id), assignment)
    stations[key] = nil
    save()
end

function clear()
    stations = nil
    unavailable = {}
    if not dfhack.isMapLoaded() or not dfhack.world.isFortressMode() then return end
    for key, assignment in pairs(ledger()) do
        restore(df.unit.find(tonumber(key)), assignment)
        stations[key] = nil
    end
    save()
end

local function start(unit, pos)
    local assignment = {
        pos=point(pos), last_pos=point(unit.pos), last_tick=df.global.world.frame_counter,
        old_station=point(unit.idle_area), old_station_type=unit.idle_area_type,
        old_threshold=unit.idle_area_threshold, old_follow_distance=unit.follow_distance,
        old_destination=point(unit.path.dest), old_goal=unit.path.goal,
    }
    ledger()[tostring(unit.id)] = assignment
    save()
    -- The native SeekStation goal calculates and walks the unit's route.
    unit.idle_area:assign(pos)
    unit.idle_area_type = df.unit_station_type.Commander
    unit.idle_area_threshold = 0
    unit.follow_distance = 50
    dfhack.units.setPathGoal(unit, pos, df.unit_path_goal.SeekStation)
    return unit.id
end

local function canTakeStation(unit, pos, assignments)
    if not eligible(unit) or assignments[tostring(unit.id)] then return false end
    local blocked = unavailable[unit.id]
    return (not blocked or not same(pos, blocked.pos)
        or df.global.world.frame_counter >= blocked.retry_tick)
end

function acquire(pos, preferred_id)
    local assignments = ledger()
    local preferred = preferred_id and df.unit.find(preferred_id)
    if canTakeStation(preferred, pos, assignments) and reachable(preferred, pos) then
        return start(preferred, pos)
    end

    local best, best_distance
    for _, unit in ipairs(dfhack.units.getCitizens(true)) do
        if canTakeStation(unit, pos, assignments) then
            local distance = math.abs(unit.pos.x - pos.x) + math.abs(unit.pos.y - pos.y)
                + 8 * math.abs(unit.pos.z - pos.z)
            if (not best_distance or distance < best_distance) and reachable(unit, pos) then
                best, best_distance = unit, distance
            end
        end
    end
    if best then return start(best, pos) end
end

function active(unit_id, pos)
    local assignment = unit_id and ledger()[tostring(unit_id)]
    if not assignment or not same(pos, assignment.pos) then return false end
    local unit = df.unit.find(unit_id)
    if not eligible(unit) or not hasStation(unit, assignment) then
        release(unit_id)
        return false
    end
    if same(unit.pos, pos) then return true end

    local time = df.global.world.frame_counter
    if not same(unit.pos, assignment.last_pos) then
        assignment.last_pos = point(unit.pos)
        assignment.last_tick = time
    end
    if time - assignment.last_tick >= STUCK_TICKS or not reachable(unit, pos) then
        unavailable[unit_id] = {pos=assignment.pos, retry_tick=time + STUCK_TICKS}
        release(unit_id)
        return false
    end
    if unit.path.goal == df.unit_path_goal.None then
        dfhack.units.setPathGoal(unit, pos, df.unit_path_goal.SeekStation)
    end
    return true
end

function arrived(unit_id, pos)
    return active(unit_id, pos) and same(df.unit.find(unit_id).pos, pos)
end

local function canRide(unit_id, pos)
    if not arrived(unit_id, pos) then return false end
    local unit = df.unit.find(unit_id)
    return not unit.flags1.on_ground and not unit.flags1.projectile
        and not unit.flags1.ridden and not unit.flags4.carrying_somebody
        and unit.relationship_ids[df.unit_relationship_type.Draggee] < 0
        and unit.relationship_ids[df.unit_relationship_type.Dragger] < 0
        and (unit.path.goal == df.unit_path_goal.None
            or (unit.path.goal == df.unit_path_goal.SeekStation and same(unit.path.dest, pos)))
end

function board(unit_id, pos)
    if not canRide(unit_id, pos) then return false end
    ledger()[tostring(unit_id)].aboard = true
    return true
end

function ride(unit_id, next_pos, dock_id)
    local assignment = unit_id and ledger()[tostring(unit_id)]
    if not assignment or not assignment.aboard or not canRide(unit_id, assignment.pos) then
        return false, 'Waiting for the operator to board the carriage'
    end
    local from = assignment.pos
    if not next_pos or from.z ~= next_pos.z
        or math.abs(from.x - next_pos.x) + math.abs(from.y - next_pos.y) ~= 1 then
        return false, 'The next carriage tile must be adjacent on the same level'
    end
    local designation, occupancy = dfhack.maps.getTileFlags(next_pos)
    local unit = df.unit.find(unit_id)
    if not designation or designation.flow_size ~= 0 or not occupancy
        or occupancy.unit or occupancy.unit_grounded or occupancy.vehicle
        or not reachable(unit, next_pos) then
        return false, 'Waiting for the next carriage tile to clear'
    end
    if occupancy.building ~= df.tile_building_occ.None then
        local dock = dock_id and dfhack.buildings.findAtTile(next_pos)
        if not dock or dock.id ~= dock_id then
            return false, 'Waiting for the next carriage tile to clear'
        end
    end

    -- A carriage step and its rider move in the same game tick. The native
    -- relocation updates both tiles' occupancy and keeps the unit's inventory.
    if not dfhack.units.teleport(unit, next_pos) then
        return false, 'Waiting for a safe carriage step'
    end
    assignment.pos = point(next_pos)
    assignment.last_pos = assignment.pos
    assignment.last_tick = df.global.world.frame_counter
    unit.idle_area:assign(next_pos)
    dfhack.units.setPathGoal(unit, next_pos, df.unit_path_goal.SeekStation)
    save()
    return true
end
