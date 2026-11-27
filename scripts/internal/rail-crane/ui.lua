--@ module = true

local gui = require('gui')
local dialogs = require('gui.dialogs')
local guidm = require('gui.dwarfmode')
local widgets = require('gui.widgets')
local overlays = require('plugins.overlay')
local native = reqscript('internal/rail-crane/native')
local picker = reqscript('internal/rail-crane/picker')
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
        if equal(pos, origin) or equal(pos, snap(pose.rear)) or equal(pos, crane.dock) then
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
        local block = sprites.layer('block', sprites.blockColor(pose.load.token), depth)
        drawPieces(putLayer, anchor, sprites.shift(block, x, y))
    end
end

local function craneLayers(put, putLayer, api, crane, z)
    for _, target in ipairs(crane.queue) do
        put(target, 'queued')
    end

    local pose = api.pose(crane)
    local origin, rear = snap(pose.origin), snap(pose.rear)
    local deck_z = origin.z
    local north_south = crane.rail[1].x == crane.rail[#crane.rail].x
    local wheel = math.floor((pose.origin.x + pose.origin.y) * 4) % 2 == 1
    local offset_x, offset_y = offsets(pose.origin, origin)
    local function putMoving(pos, name, ...)
        drawPieces(putLayer, pos, sprites.shift(sprites.layer(name, ...), offset_x, offset_y))
    end
    if z == deck_z then
        if crane.dock then
            local tile = dfhack.maps.getTileType(crane.dock)
            if tile and df.tiletype.attrs[tile].special == df.tiletype_special.TRACK then
                put(crane.dock, 'dock', north_south)
            end
        end
        putMoving(origin, 'chassis', north_south, wheel)
        putMoving(rear, 'prep', north_south)
        if pose.prepared then drawBlock(putLayer, pose.prepared, z) end
        drawPieces(putLayer, origin, sprites.arm(pose.angle, pose.extension, offset_x, offset_y))
        putMoving(origin, 'hub')
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
    self.notice = ''
    local function control() return self.mode == 'control' end
    local function building() return self.mode == 'build' end
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
    self:addviews{
        widgets.Window{
            view_id='control_panel',
            frame={l=2,t=4,w=44,h=11},
            frame_style=gui.FRAME_MEDIUM,
            frame_inset={x=1,y=0},
            frame_title='Rail crane',
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
                action({l=0,t=5,w=26}, 'Dismantle crane', 'CUSTOM_CTRL_D',
                    function() self:dismantle() end, {enabled=ready}),
                notice('control_notice', 6),
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
    }
end

function CraneScreen:headline()
    local crane = self:crane()
    if not crane then return 'The crane is unavailable.' end
    return ('%d queued column%s'):format(#crane.queue, #crane.queue == 1 and '' or 's')
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

function CraneScreen:dismantle()
    local crane = self:crane()
    if not crane then return end
    dialogs.showYesNoPrompt('Dismantle rail crane',
        'Order a dwarf to dismantle this crane and clear its pending columns?', COLOR_YELLOW,
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
    if pos.z > crane.rail[1].z then return false, 'The crane cannot build above its deck.' end
    local _, reachable = self:reachable(pos.z)
    if not reachable[xykey(pos)] then
        return false, 'The target is outside reach or on the carriage path.'
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

function CraneScreen:drawPreview(put, z)
    local mouse = not self:isMouseOver() and mapMouse() or nil
    if self.mode ~= 'build' then return end
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
            or 'Construct a Rail Crane on a minecart track from the Machines/Fluids build menu.'
        dialogs.showMessage('Rail crane', message, COLOR_LIGHTRED)
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

function overlay(api)
    local CraneOverlay = defclass(nil, overlays.OverlayWidget)
    CraneOverlay.ATTRS{
        desc='Displays the rail crane and opens its controls when clicked.',
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
        desc='Checks the track while placing a Rail Crane.',
        default_enabled=true,
        default_pos={x=-3,y=5},
        frame={w=48,h=3},
        viewscreens='dwarfmode/Building/Placement',
        visible=native.isPlacement,
    }

    function PlacementOverlay:init()
        self.message = ''
        self:addviews{widgets.WrappedLabel{
            view_id='placement_hint',
            frame={l=0,r=0,t=0,h=3},
            auto_height=false,
            text_to_wrap=function() return self.message end,
            text_pen={fg=COLOR_WHITE,bg=COLOR_BLACK},
        }}
    end

    function PlacementOverlay:render(dc)
        local pos = mapMouse()
        local timestamp = dfhack.getTickCount()
        if not equal(pos, self.pos) or not self.checked_at or timestamp - self.checked_at >= 160 then
            self.pos, self.checked_at = pos, timestamp
            self.invalid, self.reason = nil, nil
            if pos then
                local ok, reason = api.checkPlacement(pos)
                self.invalid, self.reason = not ok, reason
            end
        end
        local message = self.invalid and (self.reason or 'Choose a straight minecart track.')
            or 'Place the Rail Crane on a straight minecart track.'
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
        local pos
        if keys._MOUSE_L then
            pos = mapMouse()
        elseif keys.SELECT then
            local cursor = df.global.buildreq.pos
            if cursor:isValid() then pos = cursor end
        end
        if not pos then return false end
        return not api.checkPlacement(pos)
    end

    return {crane=CraneOverlay,placement=PlacementOverlay}
end
