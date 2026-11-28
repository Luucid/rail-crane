--@ module = true

local gui = require('gui')
local dialogs = require('gui.dialogs')
local guidm = require('gui.dwarfmode')
local widgets = require('gui.widgets')
local overlays = require('plugins.overlay')
local native = reqscript('internal/rail-crane/native')
local picker = reqscript('internal/rail-crane/picker')
local rail = reqscript('internal/rail-crane/rail')
local retrieval = reqscript('internal/rail-crane/retrieval')
local sprites = reqscript('internal/rail-crane/sprites')

local function xykey(p)
    return ('%d,%d'):format(p.x, p.y)
end

local function equal(a, b)
    return a and b and a.x == b.x and a.y == b.y and a.z == b.z
end

local function mapMouse()
    local p = dfhack.gui.getMousePos()
    if p then return {x=p.x, y=p.y, z=p.z} end
end

local function round(value)
    return math.floor(value + 0.5)
end

local function snap(p)
    return {x=round(p.x), y=round(p.y), z=round(p.z)}
end

local function lineTiles(a, b)
    local tiles = {}
    local x, y = a.x, a.y
    local dx, dy = math.abs(b.x - x), -math.abs(b.y - y)
    local sx, sy = b.x >= x and 1 or -1, b.y >= y and 1 or -1
    local err = dx + dy
    while true do
        tiles[#tiles + 1] = {x=x, y=y, z=a.z}
        if x == b.x and y == b.y then return tiles end
        local step = 2 * err
        if step >= dy then err, x = err + dy, x + sx end
        if step <= dx then err, y = err + dx, y + sy end
    end
end

local function lookup(cranes, id)
    for _, crane in ipairs(cranes) do
        if id == nil or crane.id == id then return crane end
    end
end

local function locateCrane(api, pos)
    for _, crane in ipairs(api.list()) do
        local pose = api.pose(crane)
        local origin = snap(pose.origin)
        local operator = snap(pose.operator or pose.origin)
        local onMast = pos.x == origin.x and pos.y == origin.y and operator.z <= pos.z and pos.z <= origin.z
        if onMast or equal(pos, snap(pose.rear)) or equal(pos, crane.dock) then
            return crane
        end
    end
end

local function drawPieces(putLayer, origin, pieces)
    for _, piece in ipairs(pieces) do
        putLayer({x=origin.x + piece.x, y=origin.y + piece.y, z=origin.z}, piece.sprite)
    end
end

local function offsets(p, snapped)
    return 4 * round((p.x - snapped.x) * 8), 4 * round((p.y - snapped.y) * 8)
end

local function drawBlock(putLayer, block, z)
    local load = snap(block)
    if load.z ~= z then return end
    local depth = math.min(2, math.floor((load.z + 0.5 - block.z) * 3))
    local x, y = offsets(block, load)
    local sprite = sprites.layer('block', sprites.blockColor(block.token), depth)
    drawPieces(putLayer, load, sprites.shift(sprite, x, y))
end

local function ropeVisible(pos, dock)
    if not dfhack.maps.isValidTilePos(pos) then return false end
    local designation, occupancy = dfhack.maps.getTileFlags(pos)
    if designation and (designation.hidden or occupancy.unit or occupancy.unit_grounded
        or (occupancy.building ~= df.tile_building_occ.None and not equal(pos, dock))) then
        return false
    end
    local tile = dfhack.maps.getTileType(pos)
    if not tile then return true end
    local shape = df.tiletype.attrs[tile].shape
    return df.tiletype_shape.attrs[shape].passable_high
end

local function drawHoist(putLayer, pose, crane, origin, offset_x, offset_y, z)
    if not pose.cable or z > origin.z then return end
    local bottom = snap(pose.cable)
    if z < bottom.z then return end
    local at_end = z == bottom.z
    local at_sheave = z == origin.z
    local depth = math.min(2, math.floor((bottom.z + 0.5 - pose.cable.z) * 3))
    local x, y = offsets(pose.cable, bottom)
    local anchor = {x=bottom.x, y=bottom.y, z=z}
    if at_sheave then
        local tx, ty
        tx, ty, x, y = sprites.sheavePosition(pose.angle, pose.extension, offset_x, offset_y)
        anchor = {x=origin.x + tx, y=origin.y + ty, z=z}
    end
    local function putRope(pos, sprite)
        if ropeVisible(pos, crane.dock) then putLayer(pos, sprite, true) end
    end
    drawPieces(putRope, anchor, sprites.shift(sprites.layer('rope', at_end, depth, at_sheave), x, y))
    if at_end and pose.load then
        local load
        if pose.load.cargo then
            load = sprites.layer('cargo', pose.load.corpse, depth)
        else
            load = sprites.layer('block', sprites.blockColor(pose.load.token), depth)
        end
        drawPieces(putLayer, anchor, sprites.shift(load, x, y))
    end
end

local function craneLayers(put, putLayer, api, crane, z)
    for _, target in ipairs(crane.queue) do
        put(target, 'queued')
    end
    local marked = {}
    for _, pickup in ipairs(crane.pickups or {}) do
        local pos = pickup.pos
        local key = xykey(pos)
        if pos.z == z and not marked[key] then
            put(pos, 'pickup')
            marked[key] = true
        end
    end

    local pose = api.pose(crane)
    local origin = snap(pose.origin)
    local base = pose.operator or pose.origin
    local north_south = pose.north_south
    local wheel = math.floor((pose.origin.x + pose.origin.y) * 4) % 2 == 1
    local offset_x, offset_y = offsets(pose.origin, origin)
    local function putMoving(pos, name, ...)
        local tile = snap(pos)
        local x, y = offsets(pos, tile)
        drawPieces(putLayer, tile, sprites.shift(sprites.layer(name, ...), x, y))
    end
    if z == base.z then
        if crane.dock then
            local tile = dfhack.maps.getTileType(crane.dock)
            if tile and (crane.stationary or df.tiletype.attrs[tile].special == df.tiletype_special.TRACK) then
                put(crane.dock, 'dock', crane.dy == 1)
            end
        end
        if crane.stationary then
            putMoving(base, 'foundation', north_south)
        else
            putMoving(base, 'chassis', north_south, wheel)
        end
        putMoving(pose.rear, 'prep', north_south)
        if base.z < origin.z then putMoving(base, 'hub') end
        if pose.prepared then drawBlock(putLayer, pose.prepared, z) end
    elseif base.z < z and z <= origin.z then
        putMoving({x=pose.origin.x, y=pose.origin.y, z=z}, 'mast')
    end
    if z == origin.z then
        drawPieces(putLayer, origin, sprites.arm(pose.angle, pose.extension, offset_x, offset_y))
        putMoving(pose.origin, 'hub')
    end
    drawHoist(putLayer, pose, crane, origin, offset_x, offset_y, z)
end

local function drawMap(api, screen)
    if not dfhack.isMapLoaded() then return end
    local viewport = guidm.Viewport.get()
    local scene = {}
    local function putLayer(pos, sprite, rope)
        if not viewport:isVisible(pos) then return end
        local key = xykey(pos)
        local tile = scene[key]
        if not tile then
            tile = {x=pos.x - viewport.x1, y=pos.y - viewport.y1, rope={}, layers={}}
            scene[key] = tile
        end
        local layers = rope and tile.rope or tile.layers
        layers[#layers + 1] = sprite
    end
    local function put(pos, name, ...)
        if viewport:isVisible(pos) then putLayer(pos, sprites.layer(name, ...)) end
    end
    if screen then screen:drawPreview(put, viewport.z) end
    for _, crane in ipairs(api.list()) do
        craneLayers(put, putLayer, api, crane, viewport.z)
    end
    for _, tile in pairs(scene) do
        local layers = tile.rope
        for _, sprite in ipairs(tile.layers) do layers[#layers + 1] = sprite end
        dfhack.screen.paintTile(sprites.pen(layers), tile.x, tile.y, nil, nil, true)
    end
end

local CraneScreen = defclass(nil, gui.ZScreen)
CraneScreen.ATTRS{
    focus_path='rail-crane',
    initial_pause=false,
    defocusable=false,
    pass_movement_keys=true,
    pass_mouse_clicks=false,
    api=DEFAULT_NIL,
    crane_id=DEFAULT_NIL,
    mode='control',
}

local active_screen

function CraneScreen:crane()
    return self.crane_id and lookup(self.api.list(), self.crane_id)
end

function CraneScreen:setNotice(text)
    self.notice = text
    self.subviews.control_notice:updateLayout()
    self.subviews.build_notice:updateLayout()
    self.subviews.retrieve_notice:updateLayout()
end

local function action(frame, label, key, fn, opts)
    opts = opts or {}
    frame.h = 1
    return widgets.Label{
        frame=frame, auto_height=false, visible=opts.visible, enabled=opts.enabled,
        on_click=fn,
        text_pen=function()
            if opts.selected and opts.selected() then
                return {fg=COLOR_LIGHTGREEN,bg=COLOR_DARKGREY}
            end
            return opts.pen or COLOR_GREY
        end,
        text_dpen=COLOR_DARKGREY,
        text_hpen={fg=COLOR_WHITE,bg=COLOR_BLUE},
        text={{
            key=key, key_sep='()', width=opts.width, pad_char=' ',
            text=function()
                local name = type(label) == 'function' and label() or label
                return (opts.selected and (opts.selected() and '> ' or '  ') or '') .. name
            end,
            on_activate=fn,
        }},
    }
end

function CraneScreen:init()
    self.marked = {}
    self.vertices = {}
    self.mark_mode = 'Tiles'
    self.material_mode = 'choose'
    self.keep_building = false
    self.pickup_marks = {}
    self.notice = ''
    local function control() return self.mode == 'control' end
    local function building() return self.mode == 'build' end
    local function retrieving() return self.mode == 'retrieve' end
    local function ready()
        local crane = self:crane()
        return crane and not crane.dismantling
    end
    local function notice(id, top)
        return widgets.WrappedLabel{
            view_id=id, frame={l=0,r=0,t=top,h=2}, auto_height=false,
            text_to_wrap=function() return self.notice end,
            text_pen=COLOR_LIGHTRED,
        }
    end
    local function markChoice(left, key, name)
        return action({l=left,t=2,w=20}, name, key,
            function() self:setMarkMode(name) end,
            {selected=function() return self.mark_mode == name end, width=11})
    end
    local function materialChoice(top, key, name, mode, enabled)
        return action({l=0,r=0,t=top}, name, key,
            function() self.material_mode = mode end,
            {selected=function() return self.material_mode == mode end, width=33, enabled=enabled})
    end
    local function pickupChoice(top, key, name, mode)
        return action({l=0,r=0,t=top}, name, key,
            function() self:setPickupMode(mode) end,
            {selected=function() return self.pick_mode == mode end, width=15})
    end
    self:addviews{
        widgets.Window{
            view_id='control_panel',
            frame={l=2,t=4,w=44,h=12},
            frame_style=gui.FRAME_MEDIUM,
            frame_inset={x=1,y=0},
            frame_title='Crane',
            draggable=false,
            visible=control,
            subviews={
                widgets.Label{
                    frame={l=0,r=0,t=0},
                    text={{text=function() return self:headline() end}},
                    text_pen=COLOR_YELLOW,
                },
                widgets.WrappedLabel{
                    view_id='control_status',
                    frame={l=0,r=0,t=1,h=2}, auto_height=false,
                    text_to_wrap=function() return self:instruction() end,
                },
                action({l=0,t=4,w=22}, 'Build walls', 'CUSTOM_CTRL_B',
                    function() self:beginBuild() end, {enabled=ready, pen=COLOR_LIGHTGREEN}),
                action({l=23,t=4,w=17}, 'Center', 'CUSTOM_CTRL_J',
                    function() self:centerCrane() end),
                action({l=0,t=5,w=26}, 'Retrieve items', 'CUSTOM_CTRL_E',
                    function() self:beginRetrieve() end, {enabled=ready, pen=COLOR_LIGHTGREEN}),
                action({l=0,t=6,w=26}, 'Dismantle crane', 'CUSTOM_CTRL_D',
                    function() self:dismantle() end, {enabled=ready}),
                notice('control_notice', 7),
            },
        },
        widgets.Window{
            view_id='build_panel',
            frame={l=2,t=4,w=44,h=16},
            frame_style=gui.FRAME_MEDIUM,
            frame_inset={x=1,y=0},
            frame_title='Place wall columns',
            draggable=false,
            visible=building,
            subviews={
                widgets.Label{
                    frame={l=0,r=0,t=0},
                    text={{text=function() return self:instruction() end}},
                    text_pen=COLOR_WHITE,
                },
                widgets.Label{
                    frame={l=0,r=0,t=1},
                    text={{text=function() return self:selectionSummary() end}},
                    text_pen=COLOR_YELLOW,
                },
                markChoice(0, 'CUSTOM_CTRL_T', 'Tiles'),
                markChoice(20, 'CUSTOM_CTRL_L', 'Outline'),
                materialChoice(4, 'CUSTOM_CTRL_M', 'Choose blocks after marking', 'choose'),
                materialChoice(5, 'CUSTOM_CTRL_N', 'Use closest blocks', 'closest'),
                materialChoice(6, 'CUSTOM_CTRL_R', 'Reuse last material', 'reuse',
                    function() local c = self:crane(); return c and c.material ~= nil end),
                action({l=0,r=0,t=8}, function()
                    return (self.keep_building and '[x] ' or '[ ] ') .. 'Keep marking after placing'
                end, 'CUSTOM_CTRL_K', function() self.keep_building = not self.keep_building end),
                action({l=0,t=10,w=26}, 'Close outline', 'CUSTOM_CTRL_O',
                    function() self:closeOutline() end,
                    {visible=function() return #self.vertices > 0 end, enabled=function() return #self.vertices >= 3 end,
                        pen=COLOR_LIGHTGREEN}),
                action({l=0,t=10,w=26}, function()
                    return self.material_mode == 'choose' and 'Choose blocks' or 'Place columns'
                end, 'SELECT', function() self:queueColumns() end,
                    {visible=function() return #self.vertices == 0 end,
                        enabled=function() return ready() and next(self.marked) ~= nil end,
                        pen=COLOR_LIGHTGREEN}),
                action({l=26,t=10,w=14}, 'Clear', 'CUSTOM_CTRL_U',
                    function() self:clearDraft() end,
                    {enabled=function() return next(self.marked) ~= nil or #self.vertices > 0 end}),
                notice('build_notice', 11),
            },
        },
        widgets.Window{
            view_id='retrieve_panel',
            frame={l=2,t=4,w=44,h=16},
            frame_style=gui.FRAME_MEDIUM,
            frame_inset={x=1,y=0},
            frame_title='Retrieve items',
            draggable=false,
            visible=retrieving,
            subviews={
                widgets.Label{
                    frame={l=0,r=0,t=0},
                    text={{text=function() return self:pickupInstruction() end}},
                    text_pen=COLOR_WHITE,
                },
                widgets.Label{
                    frame={l=0,r=0,t=1},
                    text={{text=function() return self:pickupSummary() end}},
                    text_pen=COLOR_YELLOW,
                },
                pickupChoice(3, 'CUSTOM_CTRL_P', 'Pickups', 'pickup'),
                pickupChoice(4, 'CUSTOM_CTRL_T', 'Drop tile', 'drop_tile'),
                pickupChoice(5, 'CUSTOM_CTRL_L', 'Drop area', 'drop_area'),
                widgets.Label{
                    frame={l=0,r=0,t=7},
                    text={{text=function() return self:dropSummary() end}},
                    text_pen=COLOR_LIGHTGREEN,
                },
                action({l=0,t=9,w=26}, 'Queue retrieval', 'SELECT',
                    function() self:queuePickups() end,
                    {enabled=function() return ready() and self:canQueuePickups() end, pen=COLOR_LIGHTGREEN}),
                action({l=26,t=9,w=14}, 'Clear', 'CUSTOM_CTRL_U',
                    function() self.pickup_marks = {}; self:setNotice('') end,
                    {enabled=function() return next(self.pickup_marks) ~= nil end}),
                notice('retrieve_notice', 11),
            },
        },
    }
end

function CraneScreen:headline()
    local crane = self:crane()
    if not crane then return 'The crane is unavailable.' end
    return ('Boom z %d  |  %d columns  |  %d items'):format(rail.buildLevel(crane), #crane.queue,
        #(crane.pickups or {}))
end

function CraneScreen:selectionSize()
    local columns, blocks = 0, 0
    for _, mark in pairs(self.marked) do
        columns, blocks = columns + 1, blocks + mark.blocks
    end
    return columns, blocks
end

function CraneScreen:selectionSummary()
    local columns, blocks = self:selectionSize()
    return ('%d column%s  /  %d block%s'):format(columns, columns == 1 and '' or 's',
        blocks, blocks == 1 and '' or 's')
end

function CraneScreen:instruction()
    if self.mode == 'build' then
        if self.mark_mode == 'Tiles' then return 'Click a tile to mark a column top.' end
        return 'Click an outline corner at this level.'
    end
    local crane = self:crane()
    return crane and tostring(crane.status or 'Idle') or ''
end

function CraneScreen:centerCrane()
    local crane = self:crane()
    if crane then dfhack.gui.revealInDwarfmodeMap(snap(self.api.pose(crane).origin)) end
end

function CraneScreen:beginBuild()
    local crane = self:crane()
    if self.material_mode == 'reuse' and not (crane and crane.material) then
        self.material_mode = 'choose'
    end
    self.mode = 'build'
    self:clearDraft()
end

function CraneScreen:beginRetrieve()
    self.mode = 'retrieve'
    self.pickup_marks = {}
    self:setPickupMode('pickup')
end

function CraneScreen:setPickupMode(mode)
    self.pick_mode = mode
    self.drop_corner = nil
    self.hover_checked = nil
    self:setNotice('')
end

function CraneScreen:pickupInstruction()
    if self.pick_mode == 'drop_tile' then return 'Click a dry floor to set the drop tile.' end
    if self.pick_mode == 'drop_area' then
        return self.drop_corner and 'Click the opposite drop area corner.' or 'Click the first drop area corner.'
    end
    return 'Click tiles to mark loose items.'
end

function CraneScreen:pickupSummary()
    local tiles, items = 0, 0
    for _, mark in pairs(self.pickup_marks) do
        tiles, items = tiles + 1, items + mark.count
    end
    return ('%d marked item%s on %d tile%s'):format(items, items == 1 and '' or 's', tiles, tiles == 1 and '' or 's')
end

function CraneScreen:dropSummary()
    local crane = self:crane()
    local zone = crane and crane.drop_zone
    if not zone then return 'Choose a drop tile or area.' end
    local w, h = zone.x2 - zone.x1 + 1, zone.y2 - zone.y1 + 1
    if w == 1 and h == 1 then return 'Drop tile ' .. rail.coordinates({x=zone.x1, y=zone.y1, z=zone.z}) end
    return ('Drop area %d x %d  |  z %d'):format(w, h, zone.z)
end

function CraneScreen:markRetrieval(pos)
    local crane = self:crane()
    if not crane then return end
    if self.pick_mode == 'pickup' then
        local key = rail.coordinates(pos)
        if self.pickup_marks[key] then
            self.pickup_marks[key] = nil
        else
            local ok, reason, ids = self.api.inspectPickup(crane, pos)
            if not ok then self:setNotice(reason); return end
            self.pickup_marks[key] = {pos=pos, count=#ids}
        end
        self:setNotice('')
        return
    end
    if self.pick_mode == 'drop_area' and not self.drop_corner then
        self.drop_corner = pos
        self:setNotice('')
        return
    end
    local first = self.drop_corner or pos
    if first.z == pos.z then
        local zone = retrieval.area(first, pos)
        for _, mark in pairs(self.pickup_marks) do
            if retrieval.inArea(mark.pos, zone) then
                self:setNotice('Keep marked pickups outside the drop area.')
                return
            end
        end
    end
    local ok, reason = self.api.setDropZone(crane.id, first, pos)
    if not ok then self:setNotice(reason); return end
    self:setPickupMode('pickup')
end

function CraneScreen:canQueuePickups()
    local crane = self:crane()
    return self.pick_mode == 'pickup' and next(self.pickup_marks) ~= nil and crane and crane.drop_zone
end

function CraneScreen:queuePickups()
    if not self:canQueuePickups() then return end
    local positions = {}
    for _, mark in pairs(self.pickup_marks) do positions[#positions + 1] = mark.pos end
    table.sort(positions, function(a, b)
        if a.z ~= b.z then return a.z < b.z end
        if a.y ~= b.y then return a.y < b.y end
        return a.x < b.x
    end)
    local added, errors = self.api.designatePickups(self.crane_id, positions)
    for _, pickup in ipairs(self:crane().pickups or {}) do self.pickup_marks[rail.coordinates(pickup.pos)] = nil end
    if #errors > 0 then
        self:setNotice(errors[1])
    elseif added > 0 then
        self.mode = 'control'
        self:setNotice('')
    end
end

function CraneScreen:dismantle()
    local crane = self:crane()
    if not crane then return end
    dialogs.showYesNoPrompt('Dismantle crane',
        'Order a dwarf to dismantle this crane and clear its pending work?', COLOR_YELLOW,
        function()
            local ok, reason = self.api.dismantle(crane.id)
            if ok then
                self:dismiss()
            else
                self:setNotice(reason or 'The crane could not be marked for removal.')
            end
        end)
end

function CraneScreen:clearDraft()
    self.marked = {}
    self.vertices = {}
    self:setNotice('')
end

function CraneScreen:setMarkMode(mode)
    if self.mark_mode == mode then return end
    self.mark_mode = mode
    self.vertices = {}
    self:setNotice('')
end

function CraneScreen:reachable(z)
    local crane = self:crane()
    if not crane then return {}, {} end
    if self.reach_crane == crane and self.reach_rail == crane.rail and self.reach_z == z then
        return self.reach_tiles, self.reach_keys
    end
    self.reach_crane, self.reach_rail, self.reach_z = crane, crane.rail, z
    self.hover_checked = nil
    self.reach_tiles, self.reach_keys = self.api.reachable(crane, z), {}
    for _, p in ipairs(self.reach_tiles) do self.reach_keys[xykey(p)] = true end
    return self.reach_tiles, self.reach_keys
end

function CraneScreen:inspect(pos)
    local crane = self:crane()
    if not crane then return false, 'The crane is unavailable.' end
    if pos.z > rail.buildLevel(crane) then return false, 'The crane cannot build above its boom.' end
    local _, reachable = self:reachable(pos.z)
    if not reachable[xykey(pos)] then
        return false, 'The target is outside reach or on the crane footprint.'
    end
    return self.api.inspect(crane, pos)
end

function CraneScreen:markTile(pos)
    local key = xykey(pos)
    local mark = self.marked[key]
    if mark and equal(mark.pos, pos) then
        self.marked[key] = nil
        self:setNotice('')
        return
    end
    local ok, reason, first_z = self:inspect(pos)
    if not ok then self:setNotice(reason or 'This tile cannot be built.'); return end
    self.marked[key] = {pos=pos, blocks=pos.z - (first_z or pos.z) + 1}
    self:setNotice('')
end

function CraneScreen:markVertex(pos)
    local first, last = self.vertices[1], self.vertices[#self.vertices]
    if last and last.z ~= pos.z then
        self:setNotice('Return to the first corner\'s z-level to finish the outline.')
        return
    end
    if equal(first, pos) and #self.vertices >= 3 then self:closeOutline(); return end
    if equal(last, pos) then return end
    local ok, reason = self:inspect(pos)
    if not ok then self:setNotice(reason or 'This tile cannot be built.'); return end
    self.vertices[#self.vertices + 1] = pos
    self:setNotice('')
end

function CraneScreen:closeOutline()
    if #self.vertices < 3 then self:setNotice('Mark at least three corners first.'); return end
    local unique = {}
    for i, a in ipairs(self.vertices) do
        local b = self.vertices[i + 1] or self.vertices[1]
        for _, p in ipairs(lineTiles(a, b)) do
            unique[xykey(p)] = p
        end
    end
    for key, p in pairs(unique) do
        local ok, reason, first_z = self:inspect(p)
        if not ok then self:setNotice(reason or 'Part of the outline cannot be built.'); return end
        unique[key] = {pos=p, blocks=p.z - (first_z or p.z) + 1}
    end
    for key, p in pairs(unique) do self.marked[key] = p end
    self.vertices = {}
    self:setNotice('')
end

function CraneScreen:readyToSubmit()
    if #self.vertices > 0 then self:setNotice('Close the outline before choosing blocks.'); return false end
    if next(self.marked) == nil then self:setNotice('Mark at least one column.'); return false end
    return true
end

function CraneScreen:queueColumns()
    if not self:readyToSubmit() then return end
    local crane = self:crane()
    if not crane then return end
    local origin = snap(self.api.pose(crane).rear)
    if self.material_mode == 'closest' then
        local token = self.api.closest(origin)
        if token then self:submit(token)
        else self:setNotice('No unreserved blocks are available.') end
    elseif self.material_mode == 'reuse' then
        if crane.material then self:submit(crane.material)
        else self:setNotice('Choose a block material for this crane first.') end
    else
        for _, mark in pairs(self.marked) do
            local pos = mark.pos
            local ok, reason, first_z = self:inspect(pos)
            if not ok then
                self:setNotice(reason or 'Check the marked column.')
                return
            end
            mark.blocks = pos.z - (first_z or pos.z) + 1
        end
        local _, blocks = self:selectionSize()
        picker.show{
            needed=blocks,
            choices=self.api.materials(origin),
            on_select=function(token) self:submit(token) end,
        }
    end
end

function CraneScreen:submit(material)
    if not self:readyToSubmit() then return end
    local positions = {}
    for _, mark in pairs(self.marked) do positions[#positions + 1] = mark.pos end
    table.sort(positions, function(a, b) return a.y == b.y and a.x < b.x or a.y < b.y end)
    local added, errors = self.api.designate(self.crane_id, positions, material)
    local crane = self:crane()
    if crane then
        for _, column in ipairs(crane.queue) do
            local key = xykey(column)
            local mark = self.marked[key]
            if mark and equal(mark.pos, column) then self.marked[key] = nil end
        end
    end
    if errors and #errors > 0 then
        local message = errors[1]
        if #errors > 1 then message = ('%s (%d more)'):format(message, #errors - 1) end
        self:setNotice(message)
        return
    end
    if added and added > 0 then
        self.mode = self.keep_building and 'build' or 'control'
        self:clearDraft()
    end
end

function CraneScreen:drawPickupPreview(put, z, mouse)
    local crane = self:crane()
    if not crane then return end
    local zone = crane.drop_zone
    if self.drop_corner and mouse and self.drop_corner.z == mouse.z then
        zone = retrieval.area(self.drop_corner, mouse)
    end
    for _, p in ipairs(self:reachable(z)) do
        put(p, retrieval.inArea(p, zone) and 'drop' or 'reach')
    end
    for _, mark in pairs(self.pickup_marks) do put(mark.pos, 'marked') end
    if self.drop_corner then put(self.drop_corner, 'drop') end
    if not mouse then return end
    if self.pick_mode == 'pickup' then
        local timestamp = dfhack.getTickCount()
        if not equal(mouse, self.hover_pos) or not self.hover_checked or timestamp - self.hover_checked >= 160 then
            self.hover_valid = self.pickup_marks[rail.coordinates(mouse)] or self.api.inspectPickup(crane, mouse)
            self.hover_pos, self.hover_checked = mouse, timestamp
        end
        put(mouse, self.hover_valid and 'hovered' or 'invalid')
    else
        put(mouse, 'drop')
    end
end

function CraneScreen:drawPreview(put, z)
    if self.mode == 'control' then return end
    local mouse = not self:isMouseOver() and mapMouse() or nil
    if self.mode == 'retrieve' then
        self:drawPickupPreview(put, z, mouse)
        return
    end
    for _, p in ipairs(self:reachable(z)) do put(p, 'reach') end
    for _, mark in pairs(self.marked) do put(mark.pos, 'marked') end
    for i, p in ipairs(self.vertices) do
        local following = self.vertices[i + 1] or (mouse and mouse.z == p.z and mouse) or p
        for _, segment in ipairs(lineTiles(p, following)) do put(segment, 'marked') end
    end
    if mouse then
        local timestamp = dfhack.getTickCount()
        if not equal(mouse, self.hover_pos) or not self.hover_checked or timestamp - self.hover_checked >= 160 then
            self.hover_valid = self:inspect(mouse)
            self.hover_pos, self.hover_checked = mouse, timestamp
        end
        put(mouse, self.hover_valid and 'hovered' or 'invalid')
    end
end

function CraneScreen:onRenderFrame()
    if self.mode == 'control' then
        local status = self:instruction()
        if status ~= self.status then
            self.status = status
            self.subviews.control_status:updateLayout()
        end
    end
    drawMap(self.api, self)
end

function CraneScreen:onInput(keys)
    if keys.LEAVESCREEN or keys._MOUSE_R then
        if self.mode == 'build' and #self.vertices > 0 then
            table.remove(self.vertices)
            self:setNotice('')
            return true
        end
        if self.mode == 'build' then
            self.mode = 'control'
            self:clearDraft()
            return true
        end
        if self.mode == 'retrieve' then
            if self.drop_corner then
                self.drop_corner = nil
            else
                self.mode = 'control'
                self.pickup_marks = {}
            end
            self:setNotice('')
            return true
        end
    end
    if keys.SELECT and self.mode == 'build' and #self.vertices > 0 then
        self:closeOutline()
        return true
    end
    if keys._MOUSE_L and not self:isMouseOver() then
        local pos = mapMouse()
        if pos then
            if self.mode == 'build' then
                if self.mark_mode == 'Tiles' then self:markTile(pos) else self:markVertex(pos) end
            elseif self.mode == 'retrieve' then
                self:markRetrieval(pos)
            else
                local crane = locateCrane(self.api, pos)
                if crane then self.crane_id = crane.id end
            end
            return true
        end
    end
    if keys.CONTEXT_SCROLL_UP or keys.CONTEXT_SCROLL_DOWN then
        if not self:isMouseOver() then self:sendInputToParent(keys); return true end
    end
    return CraneScreen.super.onInput(self, keys)
end

function CraneScreen:onDismiss()
    active_screen = nil
end

function show(api, crane_id)
    local crane = lookup(api.list(), crane_id)
    if not crane then
        local message = crane_id and 'No crane with that ID.'
            or 'Build a crane from Machines/Fluids.'
        dialogs.showMessage('Crane', message, COLOR_LIGHTRED)
        return
    end
    if active_screen and not active_screen:isDismissed() then
        if active_screen.crane_id ~= crane.id then
            active_screen.crane_id, active_screen.mode = crane.id, 'control'
            active_screen:clearDraft()
        end
        return active_screen:raise()
    end
    active_screen = CraneScreen{api=api, crane_id=crane.id}:show()
    return active_screen
end

local function placementMenu()
    local interface = gui.get_interface_rect()
    local x1, y1 = interface.x1 + 4, 4
    local state = overlays.get_state()
    local planner = state.db['buildingplan.planner']
    local config = state.config['buildingplan.planner']
    if planner and config and config.enabled and not planner.widget:is_minimized() then
        local errors = planner.widget.subviews.errors
        local rect, parent = errors.frame_rect, errors.frame_parent_rect
        if rect and parent then
            return {x1=parent.x1+rect.x1, x2=parent.x1+rect.x2, y1=y1, y2=parent.y1+rect.y2}
        end
    end

    -- The native placement menu uses a nine-slice frame. Match its edge
    -- tiles to locate the lower border even when placement errors add rows.
    local read = dfhack.screen.readTile
    local function tile(x, y)
        local pen = read(x, y)
        return pen and pen.tile
    end
    local corner, top, side = tile(x1, y1), tile(x1+1, y1), tile(x1, y1+1)
    if corner and top and side and corner ~= top and corner ~= side then
        local x2, y2 = x1+2, y1+2
        while x2 < interface.x2 and tile(x2, y1) == top do x2 = x2+1 end
        while y2 < interface.y2 and tile(x1, y2) == side do y2 = y2+1 end
        if tile(x1, y2) == side + (side-corner) and tile(x2, y2) then
            return {
                x1=x1, x2=x2, y1=y1, y2=y2, background=read(x1+1,y1+1),
                left=read(x1,y1+1), right=read(x2,y1+1),
                bottom_left=read(x1,y2), bottom=read(x1+1,y2), bottom_right=read(x2,y2),
            }
        end
    end

    local request = df.global.buildreq
    return {x1=x1, x2=math.min(x1+55,interface.x2), y1=y1,
        y2=18+math.max(1,#request.errors+#request.warnings)}
end

function overlay(api)
    local CraneOverlay = defclass(nil, overlays.OverlayWidget)
    CraneOverlay.ATTRS{
        desc='Displays the crane and opens its controls when clicked.',
        default_enabled=true,
        fullscreen=true,
        viewscreens={'dwarfmode'},
    }

    function CraneOverlay:render()
        if not active_screen or active_screen:isDismissed() then drawMap(api) end
    end

    function CraneOverlay:onInput(keys)
        if not keys._MOUSE_L or not dfhack.isMapLoaded() then return false end
        if not dfhack.gui.matchFocusString('dwarfmode/Default', dfhack.gui.getDFViewscreen(true)) then
            return false
        end
        local pos = mapMouse()
        if not pos then return false end
        local crane = locateCrane(api, pos)
        if not crane then return false end
        show(api, crane.id)
        return true
    end

    local PlacementOverlay = defclass(nil, overlays.OverlayWidget)
    PlacementOverlay.ATTRS{
        desc='Sets the crane height and checks its base and mast clearance.',
        default_enabled=true,
        fullscreen=true,
        default_pos={x=1,y=1},
        viewscreens='dwarfmode/Building/Placement',
        visible=native.isChoosingSite,
    }

    function PlacementOverlay:computeFrame(parent)
        return gui.mkdims_wh(0,0,parent.width,parent.height)
    end

    function PlacementOverlay:init()
        self.height = 0
        self.message = ''
        local pen = {fg=COLOR_WHITE,bg=COLOR_BLACK,keep_lower=true}
        self:addviews{widgets.Panel{
            view_id='placement_settings', frame={l=0,t=0,w=50,h=5},
            visible=function() return self.footer ~= nil end,
            subviews={
                action({l=0,t=0,w=4}, '[-]', nil, function() self:changeHeight(-1) end,
                    {enabled=function() return self.height > 0 end, pen=pen}),
                widgets.Label{
                    frame={l=5,t=0,w=20},
                    text={{text=function() return ('Boom height +%d z'):format(self.height) end}},
                    text_pen=pen,
                },
                action({l=25,t=0,w=4}, '[+]', nil, function() self:changeHeight(1) end, {pen=pen}),
                widgets.WrappedLabel{
                    view_id='placement_cost', frame={l=0,r=0,t=2,h=1}, auto_height=false,
                    text_to_wrap=function()
                        return ('2 blocks, 1 mechanism, 1 rope or chain, %d logs'):format(native.logCost(self.height))
                    end,
                    text_pen=pen,
                },
                widgets.WrappedLabel{
                    view_id='placement_hint', frame={l=0,r=0,t=3,h=2}, auto_height=false,
                    text_to_wrap=function() return self.message end,
                    text_pen=pen,
                },
            },
        }}
    end

    function PlacementOverlay:paintFooter(dc, menu)
        local x1, x2 = menu.x1, menu.x2
        local top = menu.background and menu.y2 or menu.y2+1
        local settings = self.subviews.placement_settings
        local frame = settings.frame
        local bottom = top+frame.h+1
        self.footer = {x1=x1, y1=top, x2=x2, y2=bottom}
        if frame.l ~= x1+2 or frame.t ~= top+1 or frame.w ~= x2-x1-3 then
            frame.l, frame.t, frame.w = x1+2, top+1, x2-x1-3
            settings:updateLayout(self.frame_body)
        end
        local screen = dfhack.screen
        if menu.background then
            screen.fillRect(menu.background,x1+1,top,x2-1,bottom-1)
            screen.fillRect(menu.left,x1,top,x1,bottom-1)
            screen.fillRect(menu.right,x2,top,x2,bottom-1)
            screen.paintTile(menu.bottom_left,x1,bottom)
            screen.fillRect(menu.bottom,x1+1,bottom,x2-1,bottom)
            screen.paintTile(menu.bottom_right,x2,bottom)
        else
            screen.fillRect(gui.CLEAR_PEN,x1+1,top+1,x2-1,bottom-1)
            gui.paint_frame(dc, gui.mkdims_wh(x1,top,x2-x1+1,bottom-top+1), gui.FRAME_INTERIOR_MEDIUM)
        end
    end

    function PlacementOverlay:changeHeight(delta)
        local _, _, levels = dfhack.maps.getSize()
        self.height = math.max(0, math.min(levels - 2, self.height + delta))
        self.checked_at = nil
        self.subviews.placement_cost:updateLayout()
        native.setPlacementHeight(self.height)
    end

    function PlacementOverlay:render(dc)
        native.setPlacementHeight(self.height)
        local menu = placementMenu()
        self.menu = menu
        self:paintFooter(dc, menu)
        local mx, my = dfhack.screen.getMousePos()
        local over = gui.is_in_rect(menu,mx,my) or gui.is_in_rect(self.footer,mx,my)
        local pos = not over and mapMouse() or nil
        local timestamp = dfhack.getTickCount()
        if not equal(pos, self.pos) or not self.checked_at or timestamp - self.checked_at >= 160 then
            self.pos, self.checked_at = pos, timestamp
            self.invalid, self.reason, self.plan = nil, nil, nil
            if pos then
                local ok, reason, plan = api.checkPlacement(pos, self.height)
                self.invalid, self.reason, self.plan = not ok, reason, plan
            end
        end
        local message = 'Choose dry ground or a level track.'
        if self.invalid then
            message = self.reason or message
        elseif self.plan then
            message = ('%s crane  |  Boom z %d'):format(self.plan.stationary and 'Stationary' or 'Rolling',
                rail.buildLevel(self.plan))
        end
        if message ~= self.message then
            self.message = message
            self.subviews.placement_hint:updateLayout()
        end
        PlacementOverlay.super.render(self, dc)
        if pos and self.invalid then
            local viewport = guidm.Viewport.get()
            if viewport:isVisible(pos) then
                local pen = sprites.pen({sprites.layer('invalid')})
                dfhack.screen.paintTile(pen, pos.x - viewport.x1, pos.y - viewport.y1, nil, nil, true)
            end
        end
    end

    function PlacementOverlay:onInput(keys)
        if PlacementOverlay.super.onInput(self, keys) then return true end
        local pos
        if keys._MOUSE_L then
            local x,y = dfhack.screen.getMousePos()
            if self.footer and gui.is_in_rect(self.footer,x,y) then return true end
            if self.menu and gui.is_in_rect(self.menu,x,y) then return false end
            pos = mapMouse()
        elseif keys.SELECT then
            local cursor = df.global.buildreq.pos
            if cursor:isValid() then pos = cursor end
        end
        if not pos then return false end
        if not native.setPlacementHeight(self.height) then
            dfhack.gui.showAnnouncement('Reopen the crane placement to load its materials.', COLOR_YELLOW, true)
            return true
        end
        return not api.checkPlacement(pos, self.height)
    end

    return {crane=CraneOverlay,placement=PlacementOverlay}
end
