--@ module = true

local rail = reqscript('internal/rail-crane/rail')
local walls = reqscript('internal/rail-crane/walls')
local workers = reqscript('internal/rail-crane/workers')
local native = reqscript('internal/rail-crane/native')

local SITE_KEY = 'rail-crane/v1'
local UPDATE_TICKS = 3
local RETRY_TICKS = 45
local BLOCK_WORK_MULTIPLIER = 4
local SHARED_TRACK_STATUS = 'Split the shared track or dismantle a crane'
local state
local running = {}
local timer
local nextWorkshopScan = 0

local function available()
    return dfhack.isMapLoaded() and dfhack.world.isFortressMode()
        and dfhack.world.getCurrentSite() ~= nil
end

local function persist()
    dfhack.persistent.saveSiteData(SITE_KEY, state)
end

local function now()
    return df.global.world.frame_counter
end

local function find(id)
    for _, crane in ipairs(state and state.cranes or {}) do
        if crane.id == tonumber(id) then return crane end
    end
end

local function releaseWorker(run)
    if run and run.worker then
        workers.release(run.worker)
        run.worker = nil
    end
end

local function reset(crane, status, retry)
    releaseWorker(running[crane.id])
    if crane.reservation then
        walls.release(crane.reservation)
        crane.reservation = nil
        persist()
    end
    running[crane.id] = retry and {retry=now() + RETRY_TICKS} or nil
    crane.status = status
end

local function standbyStatus(crane)
    if crane.dismantling then return 'Waiting for a dwarf to dismantle the crane' end
    if not state.enabled then return 'Paused' end
    if crane.track_conflict then return SHARED_TRACK_STATUS end
    return #crane.queue > 0 and 'Queued' or 'Ready'
end

local function footprintConflict(candidate, owner)
    local newSite = rail.footprint(candidate)
    local deck = candidate.rail[1].z
    for _, other in ipairs(state.cranes) do
        if other ~= owner and other.rail[1].z == deck then
            for key in pairs(rail.footprint(other)) do
                if newSite[key] then return 'The crane platforms would overlap.' end
            end
        end
        for _, column in ipairs(other.queue) do
            if column.next_z <= deck and deck <= column.z and newSite[rail.xykey(column)] then
                return 'That track crosses a queued wall column.'
            end
        end
    end
end

local function dockPositions(buildings)
    local docks = {}
    for _, building in ipairs(buildings) do
        docks[building.id] = {x=building.centerx, y=building.centery, z=building.z}
    end
    return docks
end

local function trackClaimed(pos, dockId, docks)
    local first, last = rail.trackSpan(pos)
    if not first then return false end
    local function onTrack(tile)
        return tile.z == first.z and first.x <= tile.x and tile.x <= last.x
            and first.y <= tile.y and tile.y <= last.y
    end
    for _, crane in ipairs(state.cranes) do
        if (not dockId or crane.building_id ~= dockId) and onTrack(crane.rail[crane.index]) then
            return true
        end
    end
    for id, tile in pairs(docks) do
        -- Reserve the track as soon as a dock is ordered. If two orders
        -- arrive before a scan, the first order owns the track.
        if (not dockId or id < dockId) and onTrack(tile) then return true end
    end
    return false
end

local function planDock(pos, dockId, docks)
    if trackClaimed(pos, dockId, docks) then return nil, 'That track already has a Rail Crane.' end
    local crane, reason = rail.discover(pos, dockId)
    if not crane then return nil, reason end
    local conflict = footprintConflict(crane)
    if conflict then return nil, conflict end
    return crane
end

local function syncTrack(crane, positions, index)
    if not positions then return false end
    local candidate = {rail=positions, dx=crane.dx, dy=crane.dy, rear=crane.rear}
    if footprintConflict(candidate, crane) then return false end

    local shift = index - crane.index
    crane.rail, crane.index = positions, index
    local run = running[crane.id]
    if run and not run.retry then
        run.stop = run.stop + shift
        if run.next_index then run.next_index = run.next_index + shift end
        if not run.placed and (not positions[run.stop] or (run.phase == 'travel' and not positions[run.next_index])) then
            reset(crane, 'Waiting for a clear track and boom path', true)
        end
    end
    return true
end

local function syncTracks()
    local updates, users = {}, {}
    for i, crane in ipairs(state.cranes) do
        local positions, index, first = rail.updatedRun(crane)
        local track = first and rail.coordinates(first)
        updates[i] = {positions=positions, index=index, track=track}
        if track then users[track] = (users[track] or 0) + 1 end
    end
    local changed = false
    for i, crane in ipairs(state.cranes) do
        if not crane.dismantling then
            local run = updates[i]
            local shared = run.track ~= nil and users[run.track] > 1
            if (crane.track_conflict == true) ~= shared then
                crane.track_conflict = shared or nil
                reset(crane, standbyStatus(crane))
                changed = true
            end
            if not shared and syncTrack(crane, run.positions, run.index) then changed = true end
        end
    end
    return changed
end

local function syncWorkshops()
    local active, changed = {}, false
    for i = #state.cranes, 1, -1 do
        local crane = state.cranes[i]
        if crane.building_id then
            local building = native.getBuilding(crane.building_id)
            if not building then
                reset(crane, 'Dismantled')
                table.remove(state.cranes, i)
                changed = true
            else
                active[building.id] = true
                if dfhack.buildings.markedForRemoval(building) then
                    crane.dismantling = true
                    reset(crane, 'Waiting for a dwarf to dismantle the crane')
                elseif crane.dismantling then
                    crane.dismantling = nil
                    crane.status = standbyStatus(crane)
                end
            end
        end
    end
    local buildings = native.list()
    local docks = dockPositions(buildings)
    for _, building in ipairs(buildings) do
        local id = building.id
        if not active[id] and not dfhack.buildings.markedForRemoval(building) then
            local crane, reason = planDock(docks[id], id, docks)
            if crane and native.usable(building) then
                crane.id = state.next_id
                state.next_id = state.next_id + 1
                state.cranes[#state.cranes + 1] = crane
                crane.status = standbyStatus(crane)
                changed = true
            elseif not crane and building:getBuildStage() == 0 then
                dfhack.buildings.deconstruct(building)
                docks[id] = nil
                dfhack.gui.showAnnouncement('Rail Crane order canceled. ' .. reason, COLOR_YELLOW, true)
            end
        end
    end
    if syncTracks() or changed then persist() end
end

local function removeColumn(crane, column)
    for i, queued in ipairs(crane.queue) do
        if queued == column then
            table.remove(crane.queue, i)
            return
        end
    end
end

local function homeAngle(crane)
    return math.atan(crane.dx, -crane.dy)
end

local function bearing(from, to)
    local dx, dy = to.x - from.x, to.y - from.y
    return math.atan(dy, dx), math.sqrt(dx * dx + dy * dy)
end

local function cableTicks(operator, target)
    return (9 + 6 * (operator.z - target.z)) * BLOCK_WORK_MULTIPLIER
end

local function interpolate(a, b, t)
    return a + (b - a) * t
end

local function turn(a, b, t)
    local delta = (b - a + math.pi) % (2 * math.pi) - math.pi
    return a + delta * t
end

local function phase(run, name, duration)
    run.phase = name
    run.start = now()
    run.duration = duration
end

local function waitForWorker(crane, run, pos, preferred, nextPhase, duration, description)
    if run.worker and not workers.active(run.worker, pos) then releaseWorker(run) end
    run.worker = run.worker or workers.acquire(pos, preferred)
    if run.worker and workers.arrived(run.worker, pos) then
        phase(run, nextPhase, duration)
        return
    end
    crane.status = description
    if now() - run.start > 480 then reset(crane, description, true) end
end

local function nextWork(crane)
    local waiting
    local empty = {}
    local i = 1
    while i <= #crane.queue do
        local column = crane.queue[i]
        local platform_z = crane.rail[1].z
        local next_z = column.next_z
        if walls.isWall({x=column.x, y=column.y, z=next_z}) then
            while next_z <= column.z and walls.isWall({x=column.x, y=column.y, z=next_z}) do
                next_z = next_z + 1
            end
            column.next_z = next_z
            if next_z > column.z then table.remove(crane.queue, i) end
            persist()
        else
            local stop = rail.stopFor(crane, column)
            local target = {x=column.x, y=column.y, z=next_z}
            local ok, reason = walls.checkLift(target, platform_z)
            if not stop then
                waiting = waiting or 'Waiting for a clear track and boom path'
            elseif not ok then
                waiting = waiting or reason
            elseif not empty[column.material] then
                local _, rear = rail.stations(crane, stop)
                local item_id = walls.reserve(column.material, rear)
                if item_id then
                    crane.reservation = item_id
                    local run = {column=column, target=target, stop=stop}
                    running[crane.id] = run
                    phase(run, 'park', 0)
                    persist()
                    return
                end
                empty[column.material] = true
                waiting = 'Waiting for matching blocks (' .. column.material .. ')'
            end
            i = i + 1
        end
    end
    reset(crane, waiting or 'Ready', #crane.queue > 0)
end

local function updateCrane(crane)
    local run = running[crane.id]
    if not run or run.retry then
        if #crane.queue == 0 then return end
        if not run or now() >= run.retry then nextWork(crane) end
        return
    end

    local currentPhase = run.phase
    local done = now() >= run.start + run.duration
    local operator, rear = rail.stations(crane, crane.index)
    if not rail.stopValid(crane, crane.index) then
        reset(crane, 'Waiting for the track and work platform to clear', true)
        return
    end
    if not run.placed and not walls.resolve(crane.reservation, run.column.material) then
        reset(crane, 'Reserved block became unavailable', true)
        return
    end
    if run.worker and not run.placed then
        local station = (currentPhase == 'prep' or currentPhase == 'wait_prep') and rear or operator
        if currentPhase ~= 'wait_prep' and currentPhase ~= 'wait_operator' and currentPhase ~= 'wait_driver'
            and (not workers.active(run.worker, station) or not workers.arrived(run.worker, station)) then
            reset(crane, 'Worker left the station', #crane.queue > 0)
            return
        end
    end

    if currentPhase == 'park' then
        if crane.index == run.stop then
            if run.worker then
                crane.last_worker = run.worker
                releaseWorker(run)
            end
            phase(run, 'wait_prep', 0)
            return
        end
        if not run.worker then
            phase(run, 'wait_driver', 0)
            return
        end
        if not workers.board(run.worker, operator) then
            reset(crane, 'Waiting for a dwarf to board the crane', true)
            return
        end
        run.next_index = crane.index + (run.stop > crane.index and 1 or -1)
        if not rail.stopValid(crane, run.next_index) then
            reset(crane, 'Waiting for the track ahead to clear', true)
            return
        end
        phase(run, 'travel', 9)
        crane.status = 'Rolling to column ' .. rail.coordinates(run.column)
    elseif currentPhase == 'wait_driver' then
        waitForWorker(crane, run, operator, crane.last_worker, 'park', 0, 'Waiting for a dwarf to board the crane')
    elseif currentPhase == 'travel' and done then
        if not rail.stopValid(crane, run.next_index) then
            reset(crane, 'Waiting for the track ahead to clear', true)
            return
        end
        local ok, reason = workers.ride(run.worker, crane.rail[run.next_index], crane.building_id)
        if not ok then
            reset(crane, reason or 'Waiting for the track ahead to clear', true)
            return
        end
        crane.index = run.next_index
        persist()
        phase(run, 'park', 0)
    elseif currentPhase == 'wait_prep' then
        waitForWorker(crane, run, rear, crane.last_worker, 'prep', 18 * BLOCK_WORK_MULTIPLIER,
            'Waiting for a dwarf at the rear platform')
    elseif currentPhase == 'prep' then
        crane.status = 'Preparing a block'
        if not run.staged then
            local ok, reason = walls.stage(crane.reservation, run.column.material, rear)
            if not ok then
                reset(crane, reason or 'Could not stage the reserved block', true)
                return
            end
            run.staged = true
        end
        if not done then return end
        run.preparer = run.worker
        releaseWorker(run)
        phase(run, 'wait_operator', 0)
        waitForWorker(crane, run, operator, run.preparer, 'swing_rear', 12 * BLOCK_WORK_MULTIPLIER,
            'Waiting for a dwarf at the controls')
    elseif currentPhase == 'wait_operator' then
        waitForWorker(crane, run, operator, run.preparer, 'swing_rear', 12 * BLOCK_WORK_MULTIPLIER,
            'Waiting for a dwarf at the controls')
    elseif currentPhase == 'swing_rear' then
        crane.status = 'Swinging to the rear platform'
        if done then phase(run, 'pickup', 9 * BLOCK_WORK_MULTIPLIER) end
    elseif currentPhase == 'pickup' then
        crane.status = 'Picking up the block'
        if not run.lifted then
            local ok, reason = walls.lift(crane.reservation, run.column.material)
            if not ok then
                reset(crane, reason or 'Could not pick up the reserved block', true)
                return
            end
            run.lifted = true
        end
        if done then phase(run, 'swing_target', 18 * BLOCK_WORK_MULTIPLIER) end
    elseif currentPhase == 'swing_target' then
        crane.status = 'Swinging to the column'
        if done then phase(run, 'lower', cableTicks(operator, run.target)) end
    elseif currentPhase == 'lower' then
        crane.status = 'Lowering the block'
        if done then phase(run, 'release', 6 * BLOCK_WORK_MULTIPLIER) end
    elseif currentPhase == 'release' then
        crane.status = 'Setting the wall block'
        if not done then return end
        if not rail.boomClear(operator, run.target) then
            reset(crane, 'Waiting for the overhead path to clear', true)
            return
        end
        local ok, reason = walls.place(run.target, crane.reservation, run.column.material, operator.z)
        if not ok then
            reset(crane, reason or 'Wall placement blocked', true)
            return
        end
        crane.reservation = nil
        crane.last_worker = run.worker
        crane.boom_angle = bearing(operator, run.target)
        run.placed = true
        run.column.next_z = run.target.z + 1
        if run.column.next_z > run.column.z then removeColumn(crane, run.column) end
        persist()
        crane.status = 'Rewinding'
        phase(run, 'rewind', cableTicks(operator, run.target))
    elseif currentPhase == 'rewind' and done then
        reset(crane, 'Ready')
    end
end

local function update()
    timer = nil
    if not state or not available() then return end
    if now() >= nextWorkshopScan then
        syncWorkshops()
        nextWorkshopScan = now() + 15
    end
    if state.enabled then
        for _, crane in ipairs(state.cranes) do
            if not crane.dismantling and not crane.track_conflict then
                local ok, err = xpcall(updateCrane, debug.traceback, crane)
                if not ok then
                    local message = tostring(err):match('^[^\n]+')
                    if crane.error ~= message then
                        dfhack.printerr(('Rail crane %d: %s'):format(crane.id, err))
                        crane.error = message
                    end
                    reset(crane, 'Crane error (see DFHack console)', true)
                end
            end
        end
    end
    timer = dfhack.timeout(UPDATE_TICKS, 'ticks', update)
end

local function restore()
    if state or not available() then return end
    state = dfhack.persistent.getSiteData(SITE_KEY, {cranes={}, next_id=1, enabled=true})
    native.hideCompletedMount()
    nextWorkshopScan = 0
    workers.clear()
    for _, crane in ipairs(state.cranes) do
        reset(crane, standbyStatus(crane))
    end
    update()
end

function isEnabled()
    restore()
    return state and state.enabled or false
end

function setEnabled(enable)
    restore()
    if not state then return false end
    state.enabled = enable
    if enable then
        for _, crane in ipairs(state.cranes) do crane.status = standbyStatus(crane) end
    else
        for _, crane in ipairs(state.cranes) do reset(crane, standbyStatus(crane)) end
    end
    persist()
    return true
end

local api = {}

function api.list()
    restore()
    return state and state.cranes or {}
end

function api.checkPlacement(pos)
    restore()
    if not state then return nil, 'Load a fortress first.' end
    local crane, reason = planDock(pos, nil, dockPositions(native.list()))
    if not crane then return nil, reason end
    return true
end

function api.dismantle(id)
    restore()
    local crane = find(id)
    if not crane then return false, 'The crane is no longer present.' end
    if crane.building_id then
        local building = native.getBuilding(crane.building_id)
        if not building then return false, 'The crane workshop is no longer present.' end
        dfhack.buildings.deconstruct(building)
        if not dfhack.buildings.markedForRemoval(building) then
            return false, 'Dwarf Fortress could not order removal.'
        end
        crane.dismantling = true
        reset(crane, 'Waiting for a dwarf to dismantle the crane')
        return true
    end

    -- Older saves can still contain already placed script-only cranes.
    reset(crane, 'Removed')
    for i, candidate in ipairs(state.cranes) do
        if candidate == crane then table.remove(state.cranes, i) break end
    end
    persist()
    return true
end

function api.cancel(id)
    restore()
    local crane = find(id)
    if not crane then return false end
    crane.queue = {}
    reset(crane, standbyStatus(crane))
    persist()
    return true
end

function api.inspect(crane, pos)
    if crane.track_conflict then return nil, SHARED_TRACK_STATUS end
    if not dfhack.maps.isValidTilePos(pos) then return nil, 'Tile is outside the map.' end
    if pos.z > crane.rail[1].z then return nil, 'Above the crane platform.' end
    local key = rail.xykey(pos)
    for _, other in ipairs(state.cranes) do
        if rail.footprint(other)[key] then return nil, 'A track or work platform occupies this column.' end
        for _, column in ipairs(other.queue) do
            if key == rail.xykey(column) then return nil, 'This column is already marked for a crane.' end
        end
    end
    if not rail.stopFor(crane, pos) then return nil, 'Out of reach from the connected track or overhead is blocked.' end
    local next_z, reason = walls.inspect(pos, crane.rail[1].z)
    if next_z == nil then return nil, reason end
    return true, nil, next_z
end

api.reachable = rail.reachable
api.materials = walls.materials
api.closest = walls.closest

function api.designate(id, positions, token)
    restore()
    local crane = find(id)
    if not crane then return 0, {'Crane is unavailable.'} end
    if crane.dismantling then return 0, {'The crane is marked for dismantling.'} end
    if crane.track_conflict then return 0, {SHARED_TRACK_STATUS} end
    local info = type(token) == 'string' and dfhack.matinfo.find(token)
    if not info then return 0, {'Select a valid block material.'} end
    token = info:getToken()
    local added, errors = 0, {}
    for _, pos in ipairs(positions) do
        local ok, reason, next_z = api.inspect(crane, pos)
        if ok then
            crane.queue[#crane.queue + 1] = {x=pos.x, y=pos.y, z=pos.z, next_z=next_z, material=token}
            added = added + 1
        else
            errors[#errors + 1] = rail.coordinates(pos) .. ' ' .. (reason or 'Cannot build here.')
        end
    end
    if added > 0 then
        crane.material = token
        if not running[crane.id] or running[crane.id].retry then
            running[crane.id] = nil
            crane.status = standbyStatus(crane)
        end
        persist()
    end
    return added, errors
end

function api.pose(crane)
    local operator, rear = rail.stations(crane, crane.index)
    local angle = crane.boom_angle or homeAngle(crane)
    local pose = {origin=operator, rear=rear, operator=operator, angle=angle, extension=1}
    local run = running[crane.id]
    if not run or run.retry then return pose end
    local name = run.phase
    local t = run.duration > 0 and math.min(1, (now() - run.start) / run.duration) or 0
    pose.phase, pose.progress = name, t
    if run.staged and not run.lifted then
        pose.prepared = {x=rear.x, y=rear.y, z=rear.z, token=run.column.material}
    end
    if name == 'travel' then
        local nextOperator, nextRear = rail.stations(crane, run.next_index)
        pose.origin = {x=interpolate(operator.x, nextOperator.x, t), y=interpolate(operator.y, nextOperator.y, t), z=operator.z}
        pose.rear = {x=interpolate(rear.x, nextRear.x, t), y=interpolate(rear.y, nextRear.y, t), z=rear.z}
        pose.operator = pose.origin
        return pose
    end

    local rearAngle = bearing(operator, rear)
    local targetAngle, reach = bearing(operator, run.target)
    local cableZ = operator.z
    if name == 'swing_rear' then
        pose.angle = turn(angle, rearAngle, t)
    elseif name == 'pickup' then
        pose.angle = rearAngle
    elseif name == 'swing_target' then
        pose.angle = turn(rearAngle, targetAngle, t)
        pose.extension = interpolate(1, reach, t)
    elseif name == 'lower' or name == 'release' then
        pose.angle, pose.extension = targetAngle, reach
        local depth = name == 'lower' and t or 1
        cableZ = interpolate(operator.z, run.target.z, depth)
    elseif name == 'rewind' then
        pose.angle = targetAngle
        local wound = math.min(1, t * 1.5)
        local folded = math.max(0, t * 3 - 2)
        cableZ = interpolate(run.target.z, operator.z, wound)
        pose.extension = interpolate(reach, 1, folded)
    else
        return pose
    end
    pose.cable = {
        x=operator.x + math.cos(pose.angle) * pose.extension,
        y=operator.y + math.sin(pose.angle) * pose.extension,
        z=cableZ,
    }
    if run.lifted and not run.placed then
        pose.load = {x=pose.cable.x, y=pose.cable.y, z=pose.cable.z, token=run.column.material}
    end
    return pose
end

getAPI = function() return api end
isAvailable = available

dfhack.onStateChange['rail-crane'] = function(code)
    if code == SC_MAP_LOADED then
        restore()
    elseif code == SC_MAP_UNLOADED then
        if timer then dfhack.timeout_active(timer, nil) end
        timer, state, running = nil, nil, {}
    end
end


