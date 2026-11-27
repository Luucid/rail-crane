--@ module = true

local BUILDING_CODE = 'RAIL_CRANE'
local BASE_LOGS = 2

local function matchesDefinition(id)
    local raw = df.building_def.find(id)
    return raw ~= nil and raw.code == BUILDING_CODE
end

local function matches(building)
    return building ~= nil
        and building:getType() == df.building_type.Workshop
        and building:getSubtype() == df.workshop_type.Custom
        and matchesDefinition(building:getCustomType())
end

function getBuilding(id)
    if not dfhack.isMapLoaded() or type(id) ~= 'number' then return end
    local building = df.building.find(id)
    if matches(building) then return building end
end

function list()
    local buildings = {}
    if not dfhack.isMapLoaded() then return buildings end
    for _, building in ipairs(df.global.world.buildings.other.WORKSHOP_CUSTOM) do
        if matches(building) then buildings[#buildings + 1] = building end
    end
    table.sort(buildings, function(a, b) return a.id < b.id end)
    return buildings
end

function usable(building)
    return matches(building)
        and building:getBuildStage() >= building:getMaxBuildStage()
        and not dfhack.buildings.markedForRemoval(building)
end

function isSelection()
    if not dfhack.isMapLoaded() then return end
    local building = dfhack.gui.getSelectedBuilding(true)
    if matches(building) then return building end
end

function isPlacement()
    if not dfhack.isMapLoaded() then return false end
    local request = df.global.buildreq
    return request.building_type == df.building_type.Workshop
        and request.building_subtype == df.workshop_type.Custom
        and matchesDefinition(request.custom_type)
end

local function permittedDefinition()
    local civ = df.historical_entity.find(df.global.plotinfo.civ_id)
    if not civ or not civ.entity_raw then return end
    for _, id in ipairs(civ.entity_raw.workshops.permitted_building_id) do
        local raw = df.building_def.find(id)
        if raw and raw.code == BUILDING_CODE then return raw end
    end
end

function logCost(height)
    return BASE_LOGS + height
end

local function ensureIngredient(raw, itemType, quantity)
    for _, entry in ipairs(raw.build_items) do
        if entry.item_type == itemType then
            entry.quantity = quantity
            return
        end
    end
    local entry = df.building_def_item:new()
    entry.item_type, entry.quantity = itemType, quantity
    entry.item_subtype, entry.mat_type, entry.mat_index = -1, -1, -1
    entry.metal_ore, entry.min_dimension, entry.has_tool_use = -1, -1, -1
    raw.build_items:insert('#', entry)
end

function prepareMaterials()
    local raw = permittedDefinition()
    if not raw then return end
    -- Saved worlds can still carry the original two building filters.
    ensureIngredient(raw, df.item_type.CHAIN, 1)
    ensureIngredient(raw, df.item_type.WOOD, BASE_LOGS)
end

function isChoosingSite()
    return isPlacement() and df.global.buildreq.stage == 1
end

function setPlacementHeight(height)
    if not isChoosingSite() then return false end
    local logs, hasRope
    for _, requirement in ipairs(df.global.buildreq.requirements) do
        if requirement.filter.item_type == df.item_type.WOOD then logs = requirement end
        if requirement.filter.item_type == df.item_type.CHAIN then hasRope = true end
    end
    if not logs or not hasRope then return false end
    logs.count_required = logCost(height)
    return true
end

function towerHeight(building)
    -- The native order carries its height in the quantity of logs it paid for.
    -- Items move from the construction job to the workshop as they are hauled.
    local count, seen = 0, {}
    local function countLogs(item)
        if item and item:getType() == df.item_type.WOOD and not seen[item.id] then
            seen[item.id] = true
            count = count + item:getStackSize()
        end
    end
    for _, entry in ipairs(building.contained_items) do countLogs(entry.item) end
    for _, job in ipairs(building.jobs) do
        if job.job_type == df.job_type.ConstructBuilding then
            for _, ref in ipairs(job.items) do countLogs(ref.item) end
            for _, filter in ipairs(job.job_items.elements) do
                if filter.item_type == df.item_type.WOOD then count = count + math.max(0, filter.quantity) end
            end
        end
    end
    return math.max(0, count - BASE_LOGS)
end

local blankDockTexture

function hideCompletedMount()
    if not dfhack.screen.inGraphicsMode() then return end
    local raw = permittedDefinition()
    if not raw or raw.dim_x ~= 1 or raw.dim_y ~= 1 or raw.build_stages ~= 3 then return end

    -- Completed docks are painted at track level by the overlay. Replace the
    -- older native mount tile even when an existing save still uses that atlas.
    if not blankDockTexture then
        local pixels = {}
        for i = 1, 32 * 32 do pixels[i] = 0 end
        blankDockTexture = dfhack.textures.createTile(pixels, 32, 32)
    end
    local texpos = blankDockTexture and dfhack.textures.getTexposByHandle(blankDockTexture)
    if texpos and texpos > 0 then raw.graphics_normal[3][0][0] = texpos end
end

local function findCraneButton(page, rawId)
    if not page then return end
    for index, button in ipairs(page.bb_button) do
        if button.type == df.building_type.Workshop and button.subtype == df.workshop_type.Custom
                and button.custom_building_id == rawId then
            return index, button
        end
    end
end

local function craneButton(raw)
    local button = df.bb_buttonst:new()
    button.category = df.construction_category_type.NONE
    button.type = df.building_type.Workshop
    button.subtype = df.workshop_type.Custom
    button.custom_building_id = raw.id
    button.number = 0
    button.grid_height = 3
    button.texpos = raw.list_icon_texpos
    button.str = raw.name
    button.hotkey = raw.build_key
    return button
end

function reparentBuildMenu()
    if not dfhack.isMapLoaded() then return end
    local interface = df.global.game.main_interface
    if interface.bottom_mode_selected ~= df.main_bottom_mode_type.BUILDING then return end
    local workshops, machines
    for _, page in ipairs(interface.construction.page) do
        if page.category == df.construction_category_type.WORKSHOPS then workshops = page end
        if page.category == df.construction_category_type.MACHINES_FLUIDS then machines = page end
    end
    if not workshops and not machines then return end
    local raw = permittedDefinition()
    if not raw then return end

    local index, original = findCraneButton(workshops, raw.id)
    if original then
        if workshops.selected_button == original then workshops.selected_button = nil end
        workshops.bb_button:erase(index)
    end
    if machines and not findCraneButton(machines, raw.id) then
        machines.bb_button:insert('#', original or craneButton(raw))
    elseif original then
        original:delete()
    end

    -- The game sizes this page before the crane is added. Keep its native
    -- columns and the combined Build menu width in sync with the extra row.
    if machines and machines.column_height > 0 and machines.number_of_columns > 0 then
        local columns = math.ceil(#machines.bb_button / machines.column_height)
        if columns > machines.number_of_columns then
            local addedWidth = (columns - machines.number_of_columns) * machines.column_width
            interface.construction.total_width = interface.construction.total_width + addedWidth
            machines.number_of_columns = columns
        end
    end
end

function buildMenuOverlay()
    local overlay = require('plugins.overlay')
    local Menu = defclass(nil, overlay.OverlayWidget)
    Menu.ATTRS{
        desc='Lists Rail Crane under Machines/Fluids in the native Build menu.',
        default_enabled=true,
        fullscreen=true,
        viewscreens='dwarfmode/Building',
    }
    function Menu:render()
        reparentBuildMenu()
    end
    return Menu
end
