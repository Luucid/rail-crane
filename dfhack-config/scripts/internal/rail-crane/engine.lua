--@ module = true

local rail = reqscript('internal/rail-crane/rail')
local walls = reqscript('internal/rail-crane/walls')
local workers = reqscript('internal/rail-crane/workers')
local native = reqscript('internal/rail-crane/native')
local retrieval = reqscript('internal/rail-crane/retrieval')

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
    if crane.pickup_reservation then
        retrieval.release(crane.pickup_reservation)
        crane.pickup_reservation = nil
        persist()
    end
    running[crane.id] = retry and {retry=now() + RETRY_TICKS} or nil
    crane.status = status
end

local function hasWork(crane)
    return #crane.queue > 0 or (crane.pickups and #crane.pickups > 0)
end

local function standbyStatus(crane)
    if crane.dismantling then return 'Waiting for a dwarf to dismantle the crane' end
    if not state.enabled then return 'Paused' end
    if crane.track_conflict then return SHARED_TRACK_STATUS end
    return hasWork(crane) and 'Queued' or 'Ready'
end

local function platformsOverlap(tiles, deck, ceiling, other)
    if other.rail[1].z > ceiling or deck > rail.buildLevel(other) + 1 then return false end
    for key in pairs(rail.footprint(other)) do
        if tiles[key] then return true end
    end
    return false
end

local function footprintConflict(candidate, owner, pending)
    local newSite = rail.footprint(candidate)
    local deck = candidate.rail[1].z
    local ceiling = rail.buildLevel(candidate) + 1
    for _, other in ipairs(state.cranes) do
        if other ~= owner and platformsOverlap(newSite, deck, ceiling, other) then
            return 'The crane platforms would overlap.'
        end
        for _, column in ipairs(other.queue) do
            if column.next_z <= ceiling and deck <= column.z and newSite[rail.xykey(column)] then
                return 'The crane would cross a queued wall column.'
            end
        end
    end
    for _, other in ipairs(pending or {}) do
        if platformsOverlap(newSite, deck, ceiling, other) then
            return 'The crane would overlap a pending crane order.'
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

local function trackClaimed(network, dockId, docks)
    if not network then return false end
    local function onTrack(tile)
        return tile.z == network.z and network.members[rail.xykey(tile)] ~= nil
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

local function planDock(pos, dockId, docks, height, pending)
    local network = rail.trackNetwork(pos)
    if trackClaimed(network, dockId, docks) then return nil, 'That track already has a crane.' end
    return rail.discover(pos, dockId, height, function(crane)
        return footprintConflict(crane, nil, pending)
    end, network)
end

local function remapRun(crane, route, run)
    local _, oldRear = rail.stations(crane, crane.index)
    local _, newRear = rail.stations(route, route.index)
    if not rail.samePosition(oldRear, newRear) then return false end

    local stop = route.indices[rail.xykey(crane.rail[run.stop])]
    if not stop then return false end
    if stop ~= route.index then
        local oldNext = crane.rail[rail.nextIndex(crane, crane.index, run.step)]
        local forward = rail.nextIndex(route, route.index, 1)
        local backward = rail.nextIndex(route, route.index, -1)
        if rail.samePosition(oldNext, route.rail[forward]) then
            run.step, run.next_index = 1, forward
        elseif rail.samePosition(oldNext, route.rail[backward]) then
            run.step, run.next_index = -1, backward
        else
            return false
        end
        if not route.closed and (stop - route.index) * run.step < 0 then return false end
    end
    run.stop = stop
    return true
end

local function syncTrack(crane, route, pending)
    if not route or footprintConflict(route, crane, pending) then return false end
    local run = running[crane.id]
    if run and not run.retry and not remapRun(crane, route, run) then
        if run.placed then
            reset(crane, standbyStatus(crane))
        else
            reset(crane, 'Waiting for a clear track and boom path', true)
        end
    end
    crane.rail, crane.index, crane.rear, crane.closed = route.rail, route.index, route.rear, route.closed
    return true
end

local function syncTracks(pending)
    local updates, users = {}, {}
    for i, crane in ipairs(state.cranes) do
        local route, track = rail.updatedRun(crane)
        updates[i] = {route=route, track=track}
        if track then users[track] = (users[track] or 0) + 1 end
    end
    local changed = false
    for i, crane in ipairs(state.cranes) do
        if not crane.dismantling then
            local update = updates[i]
            local shared = update.track ~= nil and users[update.track] > 1
            if (crane.track_conflict == true) ~= shared then
                crane.track_conflict = shared or nil
                reset(crane, standbyStatus(crane))
                changed = true
            end
            if not shared and syncTrack(crane, update.route, pending) then changed = true end
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
    local pending = {}
    for _, building in ipairs(buildings) do
        local id = building.id
        if not active[id] and not dfhack.buildings.markedForRemoval(building) then
            local crane, reason = planDock(docks[id], id, docks, native.towerHeight(building), pending)
            if crane and native.usable(building) then
                crane.id = state.next_id
                state.next_id = state.next_id + 1
                state.cranes[#state.cranes + 1] = crane
                crane.status = standbyStatus(crane)
                changed = true
            elseif crane then
                pending[#pending + 1] = crane
            elseif not crane and building:getBuildStage() == 0 then
                dfhack.buildings.deconstruct(building)
                docks[id] = nil
                dfhack.gui.showAnnouncement('Crane order canceled. ' .. reason, COLOR_YELLOW, true)
            end
        end
    end
    if syncTracks(pending) or changed then persist() end
end

local function removeEntry(queue, entry)
    for i, queued in ipairs(queue) do
        if queued == entry then
            table.remove(queue, i)
            return
        end
    end
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
    run.try_at = nil
end

local function waitForWorker(crane, run, pos, preferred, nextPhase, duration, description)
    if run.worker and not workers.active(run.worker, pos) then releaseWorker(run) end
    run.worker = run.worker or workers.acquire(pos, preferred)
    if run.worker and workers.arrived(run.worker, pos) then
        phase(run, nextPhase, duration)
        return
    end
    crane.status = description
    if not run.lifted and now() - run.start > 480 then reset(crane, description, true) end
end

local function retrievalOperatorReady(crane, run, station, boarding)
    local ready = boarding and workers.board or workers.arrived
    local tick = now()
    if run.worker and ready(run.worker, station) then
        if run.operator_wait then
            run.start = run.start + tick - run.operator_wait
            run.operator_wait = nil
        end
        return true
    end
    if run.worker and not workers.active(run.worker, station) then releaseWorker(run) end
    run.operator_wait = run.operator_wait or tick
    if not run.worker and tick >= (run.next_operator_check or 0) then
        run.worker = workers.acquire(station, crane.last_worker)
        run.next_operator_check = tick + RETRY_TICKS
    end
    if run.lifted then
        crane.status = 'Holding the item until a dwarf returns'
    elseif boarding then
        crane.status = 'Waiting for a dwarf to board the crane'
    else
        crane.status = 'Waiting for a dwarf to resume the lift'
    end
    return false
end

local function retrievalStop(crane, pos, magma_safe, drop)
    local ok, reason = retrieval.access(pos, rail.buildLevel(crane), magma_safe, drop)
    if not ok then return nil, nil, reason end
    local key = rail.xykey(pos)
    for _, other in ipairs(state.cranes) do
        if pos.z >= other.rail[1].z and pos.z <= rail.buildLevel(other) and rail.footprint(other)[key] then
            return nil, nil, 'A crane platform occupies this tile.'
        end
        if drop then
            for _, column in ipairs(other.queue) do
                if pos.z >= column.next_z and pos.z <= column.z and rail.xykey(column) == key then
                    return nil, nil, 'A wall is queued on this tile.'
                end
            end
        end
    end
    local stop, step = rail.stopFor(crane, pos)
    if not stop then return nil, nil, 'Out of reach or the boom path is blocked.' end
    return stop, step
end

local function dropFor(crane, zone, magma_safe, setting)
    if not zone then return end
    local pivot = crane.rail[crane.index]
    local best, bestStop, bestStep, bestCount, bestDistance
    for _, pos in ipairs(rail.reachable(crane, zone.z)) do
        if retrieval.inArea(pos, zone) then
            local _, occ = dfhack.maps.getTileFlags(pos)
            if setting or (occ and not occ.unit and not occ.unit_grounded) then
                local count = retrieval.countGround(pos)
                local distance = (pos.x-pivot.x)^2 + (pos.y-pivot.y)^2
                if not best or count < bestCount or (count == bestCount and distance < bestDistance) then
                    local stop, step = retrievalStop(crane, pos, magma_safe, true)
                    if stop then
                        if setting then return pos end
                        best, bestStop, bestStep, bestCount, bestDistance = pos, stop, step, count, distance
                    end
                end
            end
        end
    end
    return best, bestStop, bestStep
end

local function startRun(crane, run)
    running[crane.id] = run
    phase(run, 'park', 0)
    persist()
end

local function nextRetrieval(crane, magma_safe)
    local pickups = crane.pickups
    if not pickups or #pickups == 0 then return end
    local drop = dropFor(crane, crane.drop_zone, magma_safe)
    local waiting
    local i = 1
    while i <= #pickups do
        local pickup = pickups[i]
        local item = retrieval.atSource(pickup)
        if not item then
            table.remove(pickups, i)
            persist()
        else
            if not drop then
                waiting = 'Waiting for a clear drop area'
            else
                local stop, step, reason = retrievalStop(crane, pickup.pos, magma_safe)
                if stop and retrieval.reserve(item) then
                    crane.pickup_reservation = pickup.item_id
                    local kind = item:getType()
                    startRun(crane, {pickup=pickup, target=drop, stop=stop, step=step, magma_safe=magma_safe,
                        corpse=kind == df.item_type.CORPSE or kind == df.item_type.CORPSEPIECE})
                    return true
                end
                waiting = waiting or reason or 'Waiting for the item to become available'
            end
            i = i + 1
        end
    end
    return false, waiting
end

local function nextWork(crane)
    local magma_safe = native.hasMagmaSafeChain(crane.building_id)
    local started, waiting = nextRetrieval(crane, magma_safe)
    if started then return end
    local empty = {}
    local i = 1
    local platform_z = rail.buildLevel(crane)
    while i <= #crane.queue do
        local column = crane.queue[i]
        local next_z = column.next_z
        if walls.isWall({x=column.x, y=column.y, z=next_z}) then
            while next_z <= column.z and walls.isWall({x=column.x, y=column.y, z=next_z}) do
                next_z = next_z + 1
            end
            column.next_z = next_z
            if next_z > column.z then table.remove(crane.queue, i) end
            persist()
        else
            local stop, step = rail.stopFor(crane, column)
            local target = {x=column.x, y=column.y, z=next_z}
            local ok, reason = walls.checkLift(target, platform_z, magma_safe)
            if not stop then
                waiting = waiting or 'Waiting for a clear crane and boom path'
            elseif not ok then
                waiting = waiting or reason
            elseif not empty[column.material] then
                local _, rear = rail.stations(crane, stop)
                local item_id = walls.reserve(column.material, rear)
                if item_id then
                    crane.reservation = item_id
                    startRun(crane, {column=column, target=target, stop=stop, step=step, magma_safe=magma_safe})
                    return
                end
                empty[column.material] = true
                waiting = 'Waiting for matching blocks (' .. column.material .. ')'
            end
            i = i + 1
        end
    end
    reset(crane, waiting or 'Ready', hasWork(crane))
end

local function finishHoist(crane, run)
    if not run.pickup then
        phase(run, 'swing_target', 18 * BLOCK_WORK_MULTIPLIER)
        return
    end
    local drop, stop, step = dropFor(crane, crane.drop_zone, run.magma_safe)
    if not drop then
        crane.status = 'Holding the item until the drop area clears'
        run.try_at = now() + RETRY_TICKS
        return
    end
    run.target, run.stop, run.step = drop, stop, step
    if stop == crane.index then
        phase(run, 'swing_target', 18 * BLOCK_WORK_MULTIPLIER)
    else
        phase(run, 'stow', 18)
    end
end

local function updateCrane(crane)
    local run = running[crane.id]
    if not run or run.retry then
        if not hasWork(crane) then return end
        if not run or now() >= run.retry then nextWork(crane) end
        return
    end

    local currentPhase = run.phase
    local done = (run.operator_wait or now()) >= run.start + run.duration
    local operator, rear = rail.stations(crane, crane.index)
    local boom = rail.boomPosition(crane, crane.index)
    local source = run.pickup and run.pickup.pos or rear
    if not rail.stopValid(crane, crane.index) then
        reset(crane, 'Waiting for the crane base and rear platform to clear', true)
        return
    end
    if not run.placed then
        if run.pickup then
            if not retrieval.resolve(run.pickup) then
                reset(crane, 'The pickup item became unavailable', true)
                return
            end
        elseif not walls.resolve(crane.reservation, run.column.material) then
            reset(crane, 'Reserved block became unavailable', true)
            return
        end
    end
    local lowering = (currentPhase == 'swing_target' and done) or currentPhase == 'lower' or currentPhase == 'release'
    local picking = run.pickup and ((currentPhase == 'swing_rear' and done) or currentPhase == 'lower_rear'
        or currentPhase == 'pickup' or currentPhase == 'hoist')
    if (lowering or picking) and not run.magma_safe then
        local ok, reason = walls.checkMagma(picking and source or run.target, boom.z)
        if not ok then
            reset(crane, reason, true)
            return
        end
    end

    if run.try_at and now() < run.try_at then return end
    local waiting = currentPhase == 'wait_prep' or currentPhase == 'wait_operator'
        or currentPhase == 'wait_driver' or currentPhase == 'wait_drop'
    if not run.placed and not waiting then
        if run.pickup and (run.worker or run.operator_wait) then
            local boarding = currentPhase == 'travel' or (currentPhase == 'park' and crane.index ~= run.stop)
            if not retrievalOperatorReady(crane, run, operator, boarding) then return end
        elseif run.worker and not workers.arrived(run.worker, currentPhase == 'prep' and rear or operator) then
            reset(crane, 'Worker left the station', hasWork(crane))
            return
        end
    end

    if currentPhase == 'park' then
        if crane.index == run.stop then
            if run.pickup then
                phase(run, run.lifted and 'wait_drop' or 'wait_operator', 0)
            else
                if run.worker then
                    crane.last_worker = run.worker
                    releaseWorker(run)
                end
                phase(run, 'wait_prep', 0)
            end
            return
        end
        if not run.worker then
            phase(run, 'wait_driver', 0)
            return
        end
        if not run.pickup and not workers.board(run.worker, operator) then
            reset(crane, 'Waiting for a dwarf to board the crane', true)
            return
        end
        run.next_index = rail.nextIndex(crane, crane.index, run.step)
        if not rail.stepValid(crane, crane.index, run.next_index) then
            reset(crane, 'Waiting for the track ahead to clear', true)
            return
        end
        phase(run, 'travel', 9)
        if run.pickup then
            crane.status = run.lifted and 'Rolling to the drop area' or 'Rolling to the pickup'
        else
            crane.status = 'Rolling to column ' .. rail.coordinates(run.column)
        end
    elseif currentPhase == 'wait_driver' then
        waitForWorker(crane, run, operator, crane.last_worker, 'park', 0, 'Waiting for a dwarf to board the crane')
    elseif currentPhase == 'travel' and done then
        if not rail.stepValid(crane, crane.index, run.next_index) then
            reset(crane, 'Waiting for the track ahead to clear', true)
            return
        end
        local ok, reason = workers.ride(run.worker, crane.rail[run.next_index], crane.building_id)
        if not ok then
            local status = reason or 'Waiting for the track ahead to clear'
            if run.pickup and run.lifted then
                phase(run, 'park', 0)
                run.try_at = now() + RETRY_TICKS
                crane.status = status
            else
                reset(crane, status, true)
            end
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
        waitForWorker(crane, run, operator, run.preparer or crane.last_worker, 'swing_rear', 12 * BLOCK_WORK_MULTIPLIER,
            'Waiting for a dwarf at the controls')
    elseif currentPhase == 'wait_drop' then
        waitForWorker(crane, run, operator, crane.last_worker, 'swing_target', 18 * BLOCK_WORK_MULTIPLIER,
            'Waiting for a dwarf to unload')
    elseif currentPhase == 'swing_rear' then
        crane.status = run.pickup and 'Swinging to the pickup tile' or 'Swinging to the rear platform'
        if done then
            if run.pickup and not rail.boomClear(boom, source) then
                reset(crane, 'Waiting for a clear path to the pickup', true)
                return
            end
            if boom.z > source.z then
                phase(run, 'lower_rear', cableTicks(boom, source))
            else
                phase(run, 'pickup', 9 * BLOCK_WORK_MULTIPLIER)
            end
        end
    elseif currentPhase == 'lower_rear' then
        crane.status = run.pickup and 'Lowering the hook' or 'Lowering the hook to the rear platform'
        if done then phase(run, 'pickup', 9 * BLOCK_WORK_MULTIPLIER) end
    elseif currentPhase == 'pickup' then
        crane.status = run.pickup and 'Picking up the item' or 'Picking up the block'
        if not run.lifted then
            local ok, reason
            if run.pickup then
                ok, reason = retrieval.lift(run.pickup, boom.z, run.magma_safe)
            else
                ok, reason = walls.lift(crane.reservation, run.column.material)
            end
            if not ok then
                reset(crane, reason or 'Could not pick up the reserved load', true)
                return
            end
            run.lifted = true
        end
        if done then
            if boom.z > source.z then
                phase(run, 'hoist', cableTicks(boom, source))
            else
                finishHoist(crane, run)
            end
        end
    elseif currentPhase == 'hoist' then
        crane.status = run.pickup and 'Hoisting the item' or 'Hoisting the block'
        if done then finishHoist(crane, run) end
    elseif currentPhase == 'stow' then
        crane.status = 'Bringing the load in for travel'
        if done then
            run.stowed = true
            phase(run, 'park', 0)
        end
    elseif currentPhase == 'swing_target' then
        crane.status = run.pickup and 'Swinging to the drop area' or 'Swinging to the column'
        if done then phase(run, 'lower', cableTicks(boom, run.target)) end
    elseif currentPhase == 'lower' then
        crane.status = run.pickup and 'Lowering the item' or 'Lowering the block'
        if done then phase(run, 'release', 6 * BLOCK_WORK_MULTIPLIER) end
    elseif currentPhase == 'release' then
        crane.status = run.pickup and 'Putting the item down' or 'Setting the wall block'
        if not done then return end
        if not rail.boomClear(boom, run.target) then
            reset(crane, 'Waiting for the overhead path to clear', true)
            return
        end
        local magma_safe = native.hasMagmaSafeChain(crane.building_id)
        local ok, reason, wait
        if run.pickup then
            ok, reason, wait = retrieval.place(run.pickup, run.target, boom.z, magma_safe)
        else
            ok, reason = walls.place(run.target, crane.reservation, run.column.material, boom.z, magma_safe)
        end
        if not ok then
            if wait then
                crane.status = reason
                run.try_at = now() + RETRY_TICKS
            else
                reset(crane, reason or 'The load could not be put down', true)
            end
            return
        end
        if run.pickup then
            crane.pickup_reservation = nil
            removeEntry(crane.pickups, run.pickup)
        else
            crane.reservation = nil
            run.column.next_z = run.target.z + 1
            if run.column.next_z > run.column.z then removeEntry(crane.queue, run.column) end
        end
        crane.last_worker = run.worker
        crane.boom_angle = bearing(operator, run.target)
        run.placed = true
        persist()
        crane.status = 'Rewinding'
        phase(run, 'rewind', cableTicks(boom, run.target))
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
                        dfhack.printerr(('Crane %d: %s'):format(crane.id, err))
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
    native.prepareDefinition()
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

function api.checkPlacement(pos, height)
    restore()
    if not state then return nil, 'Load a fortress first.' end
    local buildings = native.list()
    local docks = dockPositions(buildings)
    local active, pending = {}, {}
    for _, crane in ipairs(state.cranes) do
        if crane.building_id then active[crane.building_id] = true end
    end
    for _, building in ipairs(buildings) do
        local id = building.id
        if not active[id] and not dfhack.buildings.markedForRemoval(building) then
            local draft = planDock(docks[id], id, docks, native.towerHeight(building), pending)
            if draft then pending[#pending + 1] = draft end
        end
    end
    local crane, reason = planDock(pos, nil, docks, height, pending)
    if not crane then return nil, reason end
    return true, nil, crane
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
    crane.pickups = nil
    reset(crane, standbyStatus(crane))
    persist()
    return true
end

local function queuedItems()
    local queued = {}
    for _, crane in ipairs(state.cranes) do
        for _, pickup in ipairs(crane.pickups or {}) do queued[pickup.item_id] = true end
    end
    return queued
end

function api.inspectPickup(crane, pos, queued)
    if crane.dismantling then return nil, 'The crane is marked for dismantling.' end
    if crane.track_conflict then return nil, SHARED_TRACK_STATUS end
    if retrieval.inArea(pos, crane.drop_zone) then return nil, 'Choose a pickup outside the drop area.' end
    local stop, _, reason = retrievalStop(crane, pos, native.hasMagmaSafeChain(crane.building_id))
    if not stop then return nil, reason end
    queued = queued or queuedItems()
    local ids = {}
    for _, id in ipairs(retrieval.itemsAt(pos)) do
        if not queued[id] then ids[#ids + 1] = id end
    end
    if #ids == 0 then return nil, 'No loose items are available on this tile.' end
    return true, nil, ids
end

function api.setDropZone(id, a, b)
    restore()
    local crane = find(id)
    if not crane or crane.dismantling then return nil, 'Crane is unavailable.' end
    if crane.track_conflict then return nil, SHARED_TRACK_STATUS end
    if a.z ~= b.z then return nil, 'Choose both corners on the same z-level.' end
    if not (dfhack.maps.isValidTilePos(a) and dfhack.maps.isValidTilePos(b)) then
        return nil, 'Choose a drop area within the map.'
    end
    local zone = retrieval.area(a, b)
    if not dropFor(crane, zone, native.hasMagmaSafeChain(crane.building_id), true) then
        return nil, 'Choose a drop area with a reachable, clear, dry floor.'
    end
    for _, pickup in ipairs(crane.pickups or {}) do
        if retrieval.inArea(pickup.pos, zone) then return nil, 'A queued pickup is inside this drop area.' end
    end
    local run = running[crane.id]
    crane.drop_zone = zone
    if run and (run.retry or (run.pickup and not run.placed)) then reset(crane, standbyStatus(crane)) end
    persist()
    return true
end

function api.designatePickups(id, positions)
    restore()
    local crane = find(id)
    if not crane or crane.dismantling then return 0, {'Crane is unavailable.'} end
    if crane.track_conflict then return 0, {SHARED_TRACK_STATUS} end
    if not crane.drop_zone then return 0, {'Set a drop tile or area first.'} end
    local queued = queuedItems()
    local added, errors = 0, {}
    crane.pickups = crane.pickups or {}
    for _, pos in ipairs(positions) do
        local ok, reason, ids = api.inspectPickup(crane, pos, queued)
        if ok then
            for _, id in ipairs(ids) do
                crane.pickups[#crane.pickups + 1] = {pos={x=pos.x, y=pos.y, z=pos.z}, item_id=id}
                queued[id] = true
                added = added + 1
            end
        else
            errors[#errors + 1] = rail.coordinates(pos) .. ' ' .. reason
        end
    end
    if added > 0 then
        local run = running[crane.id]
        if not run or run.retry then reset(crane, standbyStatus(crane)) end
        persist()
    end
    return added, errors
end

function api.inspect(crane, pos)
    if crane.track_conflict then return nil, SHARED_TRACK_STATUS end
    if not dfhack.maps.isValidTilePos(pos) then return nil, 'Tile is outside the map.' end
    local platform_z = rail.buildLevel(crane)
    if pos.z > platform_z then return nil, 'Above the crane boom.' end
    local key = rail.xykey(pos)
    for _, other in ipairs(state.cranes) do
        if rail.footprint(other)[key] then return nil, 'A crane or its work platform occupies this column.' end
        for _, column in ipairs(other.queue) do
            if key == rail.xykey(column) then return nil, 'This column is already marked for a crane.' end
        end
    end
    if not rail.stopFor(crane, pos) then return nil, 'Out of reach or the boom path is blocked.' end
    local next_z, reason = walls.inspect(pos, platform_z, native.hasMagmaSafeChain(crane.building_id))
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

local function drawCable(pose, run, z)
    pose.cable = {
        x=pose.operator.x + math.cos(pose.angle) * pose.extension,
        y=pose.operator.y + math.sin(pose.angle) * pose.extension,
        z=z,
    }
    if run.lifted and not run.placed then
        pose.load = {x=pose.cable.x, y=pose.cable.y, z=z, token=run.column and run.column.material,
            cargo=run.pickup ~= nil, corpse=run.corpse}
    end
end

function api.pose(crane)
    local operator, rear = rail.stations(crane, crane.index)
    local boom = rail.boomPosition(crane, crane.index)
    local north_south = operator.x == rear.x
    local angle = crane.boom_angle or (north_south and math.pi or math.pi / 2)
    local pose = {origin=boom, rear=rear, operator=operator, angle=angle, extension=1, north_south=north_south}
    local run = running[crane.id]
    if not run or run.retry then return pose end
    local name = run.phase
    local elapsed = (run.operator_wait or now()) - run.start
    local t = run.duration > 0 and math.min(1, elapsed / run.duration) or 0
    pose.phase, pose.progress = name, t
    if run.staged and not run.lifted then
        pose.prepared = {x=rear.x, y=rear.y, z=rear.z, token=run.column.material}
    end
    if name == 'travel' then
        local nextOperator, nextRear = rail.stations(crane, run.next_index)
        local x, y = interpolate(operator.x, nextOperator.x, t), interpolate(operator.y, nextOperator.y, t)
        pose.origin = {x=x, y=y, z=boom.z}
        pose.rear = {x=interpolate(rear.x, nextRear.x, t), y=interpolate(rear.y, nextRear.y, t), z=rear.z}
        pose.operator = {x=x, y=y, z=operator.z}
        if t >= 0.5 then pose.north_south = nextOperator.x == nextRear.x end
        if run.stowed then
            pose.angle, pose.extension = bearing(pose.operator, pose.rear)
            drawCable(pose, run, boom.z)
        end
        return pose
    end

    local source = run.pickup and run.pickup.pos or rear
    local sourceAngle, sourceReach = bearing(operator, source)
    local rearAngle, rearReach = bearing(operator, rear)
    local targetAngle, reach = bearing(operator, run.target)
    local cableZ = boom.z
    if name == 'swing_rear' then
        pose.angle = turn(angle, sourceAngle, t)
        pose.extension = interpolate(1, sourceReach, t)
    elseif name == 'lower_rear' or name == 'pickup' or name == 'hoist' then
        pose.angle, pose.extension = sourceAngle, sourceReach
        if name == 'lower_rear' then
            cableZ = interpolate(boom.z, source.z, t)
        elseif name == 'hoist' then
            cableZ = interpolate(source.z, boom.z, t)
        else
            cableZ = source.z
        end
    elseif name == 'stow' then
        pose.angle = turn(sourceAngle, rearAngle, t)
        pose.extension = interpolate(sourceReach, rearReach, t)
    elseif name == 'swing_target' then
        pose.angle = turn(run.stowed and rearAngle or sourceAngle, targetAngle, t)
        pose.extension = interpolate(run.stowed and rearReach or sourceReach, reach, t)
    elseif name == 'lower' or name == 'release' then
        pose.angle, pose.extension = targetAngle, reach
        local depth = name == 'lower' and t or 1
        cableZ = interpolate(boom.z, run.target.z, depth)
    elseif name == 'rewind' then
        pose.angle = targetAngle
        local wound = math.min(1, t * 1.5)
        local folded = math.max(0, t * 3 - 2)
        cableZ = interpolate(run.target.z, boom.z, wound)
        pose.extension = interpolate(reach, 1, folded)
    elseif run.stowed then
        pose.angle, pose.extension = rearAngle, rearReach
    else
        return pose
    end
    drawCable(pose, run, cableZ)
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


