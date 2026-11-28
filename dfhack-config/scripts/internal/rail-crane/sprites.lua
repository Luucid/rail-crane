--@ module = true

-- Original 32 px sprites, composited in DF's interface layer above the map.
local SIZE = 32
local CENTER = SIZE // 2

local function rgba(r, g, b, a)
    return r | (g << 8) | (b << 16) | ((a or 255) << 24)
end

local ink = rgba(36, 28, 24)
local shadow = rgba(15, 13, 11, 110)
local metal_dark = rgba(45, 49, 49)
local metal = rgba(76, 85, 84)
local metal_light = rgba(125, 135, 129)
local pin = rgba(177, 174, 151)
local wood_dark = rgba(75, 50, 35)
local wood = rgba(127, 86, 53)
local wood_face = rgba(147, 104, 66)
local wood_light = rgba(181, 131, 82)
local hemp_dark = rgba(110, 84, 53)
local hemp = rgba(168, 137, 84)
local hemp_light = rgba(203, 174, 116)
local stone_dark = rgba(67, 66, 62)
local stone = rgba(107, 105, 94)
local stone_light = rgba(143, 140, 124)

local function pixel(pixels, x, y, color)
    if x >= 0 and y >= 0 and x < SIZE and y < SIZE then
        pixels[y * SIZE + x + 1] = color
    end
end

local function rect(pixels, x1, y1, x2, y2, color)
    for y = y1, y2 do
        for x = x1, x2 do
            pixel(pixels, x, y, color)
        end
    end
end

local function disc(pixels, x, y, radius, color)
    for dy = -radius, radius do
        for dx = -radius, radius do
            if dx^2 + dy^2 <= radius^2 then
                pixel(pixels, x + dx, y + dy, color)
            end
        end
    end
end

local function line(pixels, x1, y1, x2, y2, radius, color)
    local dx, dy = x2 - x1, y2 - y1
    local length = math.max(math.abs(dx), math.abs(dy), 1)
    for i = 0, length do
        local x = math.floor(x1 + dx * i / length + 0.5)
        local y = math.floor(y1 + dy * i / length + 0.5)
        disc(pixels, x, y, radius, color)
    end
end

local function transpose(pixels)
    local turned = {}
    for y = 0, SIZE - 1 do
        for x = 0, SIZE - 1 do
            turned[x * SIZE + y + 1] = pixels[y * SIZE + x + 1]
        end
    end
    return turned
end

local function chassis(pixels, north_south, moving)
    rect(pixels, 2, 7, 31, 29, shadow)
    for _, x in ipairs{7, 24} do
        rect(pixels, x - 1, 5, x + 1, 26, metal_dark)
        for _, y in ipairs{6, 25} do
            disc(pixels, x, y, 4, ink)
            disc(pixels, x, y, 3, metal)
            disc(pixels, x, y, 2, wood_dark)
            if moving then
                line(pixels, x - 1, y - 1, x + 1, y + 1, 0, metal_light)
            else
                line(pixels, x - 2, y, x + 2, y, 0, metal_light)
            end
            pixel(pixels, x, y - 3, metal_light)
        end
    end
    rect(pixels, 1, 8, 30, 23, ink)
    rect(pixels, 2, 9, 29, 22, wood_dark)
    rect(pixels, 3, 11, 28, 20, wood)
    line(pixels, 4, 11, 27, 20, 2, wood_dark)
    line(pixels, 4, 20, 27, 11, 2, wood_dark)
    line(pixels, 4, 10, 27, 19, 0, wood_light)
    line(pixels, 4, 19, 27, 10, 0, wood_light)
    for _, y in ipairs{8, 20} do
        rect(pixels, 1, y, 30, y + 3, ink)
        rect(pixels, 2, y, 29, y + 2, wood_face)
        rect(pixels, 3, y, 28, y, wood_light)
        rect(pixels, 8, y + 1, 13, y + 1, wood)
        rect(pixels, 18, y + 2, 25, y + 2, wood_dark)
        for _, x in ipairs{4, 23} do
            rect(pixels, x, y, x + 3, y + 3, metal_dark)
            rect(pixels, x + 1, y, x + 2, y + 2, metal)
            pixel(pixels, x + 1, y + 1, pin)
        end
    end
    return north_south and transpose(pixels) or pixels
end

local function foundation(pixels, north_south)
    rect(pixels, 1, 8, 31, 27, shadow)
    for _, x in ipairs{3, 22} do
        rect(pixels, x, 6, x+7, 25, ink)
        rect(pixels, x+1, 7, x+6, 24, stone_dark)
        rect(pixels, x+1, 7, x+3, 22, stone)
        pixel(pixels, x+2, 8, stone_light)
    end
    rect(pixels, 1, 10, 30, 22, ink)
    rect(pixels, 2, 11, 29, 21, wood_dark)
    for y = 11, 19, 4 do
        rect(pixels, 3, y, 28, y+2, wood)
        rect(pixels, 3, y, 28, y, wood_light)
    end
    return north_south and transpose(pixels) or pixels
end

local function mast(pixels)
    rect(pixels, 9, 7, 25, 27, shadow)
    line(pixels, 10, 9, 22, 24, 2, wood_dark)
    line(pixels, 10, 24, 22, 9, 2, wood_dark)
    line(pixels, 10, 9, 22, 24, 0, wood_face)
    line(pixels, 10, 24, 22, 9, 0, wood_face)
    for _, x in ipairs{7, 21} do
        rect(pixels, x, 6, x+4, 25, ink)
        rect(pixels, x+1, 7, x+3, 24, wood)
        rect(pixels, x+1, 8, x+1, 23, wood_light)
    end
    for _, y in ipairs{6, 23} do
        rect(pixels, 7, y, 25, y+2, ink)
        rect(pixels, 8, y, 24, y, metal)
        pixel(pixels, 9, y+1, pin)
        pixel(pixels, 23, y+1, pin)
    end
    return pixels
end

local function prep_deck(pixels, north_south)
    rect(pixels, 2, 8, 31, 27, shadow)
    rect(pixels, 0, 8, 31, 23, ink)
    rect(pixels, 1, 9, 30, 22, wood_dark)
    for y = 9, 21, 4 do
        rect(pixels, 1, y, 30, y + 2, wood)
        rect(pixels, 2, y, 29, y, wood_face)
        rect(pixels, 3 + y % 5, y + 1, 11 + y % 5, y + 1, wood_light)
        rect(pixels, 17 + y % 6, y + 2, 26 + y % 5, y + 2, wood_dark)
    end
    for _, x in ipairs{3, 27} do
        rect(pixels, x, 7, x + 2, 24, ink)
        rect(pixels, x, 8, x + 1, 23, metal)
        pixel(pixels, x, 9, pin)
        pixel(pixels, x, 21, pin)
    end
    rect(pixels, 8, 10, 23, 20, ink)
    rect(pixels, 9, 11, 22, 19, wood_face)
    rect(pixels, 9, 11, 22, 12, wood_light)
    rect(pixels, 9, 18, 22, 19, wood_dark)
    line(pixels, 19, 11, 22, 15, 0, metal)
    pixel(pixels, 19, 11, metal_light)
    return north_south and transpose(pixels) or pixels
end

local function dock(pixels, north_south)
    for _, y in ipairs{7, 23} do
        rect(pixels, 7, y, 24, y + 3, ink)
        rect(pixels, 8, y + 1, 23, y + 2, metal_dark)
        pixel(pixels, 10, y + 1, metal_light)
        pixel(pixels, 21, y + 1, metal_light)
    end
    return north_south and transpose(pixels) or pixels
end

local function hub(pixels)
    rect(pixels, 10, 10, 24, 24, shadow)
    rect(pixels, 9, 9, 22, 22, ink)
    rect(pixels, 10, 10, 21, 21, wood_dark)
    rect(pixels, 10, 10, 21, 13, wood_face)
    rect(pixels, 10, 10, 20, 10, wood_light)
    for _, x in ipairs{11, 20} do
        rect(pixels, x, 9, x + 1, 22, metal)
        pixel(pixels, x, 10, pin)
        pixel(pixels, x, 20, pin)
    end
    disc(pixels, CENTER, CENTER, 5, ink)
    disc(pixels, CENTER, CENTER, 4, metal)
    disc(pixels, CENTER, CENTER, 3, hemp_dark)
    rect(pixels, 14, 14, 18, 14, hemp)
    rect(pixels, 14, 16, 18, 16, hemp_light)
    rect(pixels, 14, 18, 18, 18, hemp)
    return pixels
end

local function menu_crane(pixels)
    -- Timber frame and treadle platform.
    rect(pixels, 2, 24, 19, 28, ink)
    rect(pixels, 3, 24, 18, 26, wood_face)
    rect(pixels, 3, 24, 18, 24, wood_light)
    rect(pixels, 4, 27, 17, 27, metal)
    line(pixels, 10, 12, 5, 23, 1, ink)
    line(pixels, 10, 12, 5, 23, 0, wood_face)
    line(pixels, 11, 18, 19, 9, 1, ink)
    line(pixels, 11, 18, 19, 9, 0, wood_light)
    rect(pixels, 8, 11, 12, 24, ink)
    rect(pixels, 9, 12, 11, 23, wood)
    rect(pixels, 9, 14, 9, 23, wood_light)
    rect(pixels, 9, 21, 11, 22, metal_dark)

    -- Rope and stone hanging from the lifting end.
    rect(pixels, 25, 6, 26, 20, hemp_dark)
    rect(pixels, 25, 6, 25, 20, hemp_light)
    rect(pixels, 21, 20, 30, 26, ink)
    rect(pixels, 22, 21, 29, 24, stone)
    rect(pixels, 22, 20, 29, 21, stone_light)
    rect(pixels, 27, 22, 29, 25, stone_dark)
    rect(pixels, 25, 20, 25, 24, hemp)

    line(pixels, 5, 14, 26, 5, 2, ink)
    line(pixels, 5, 14, 26, 5, 1, wood)
    line(pixels, 5, 13, 26, 4, 0, wood_light)
    rect(pixels, 3, 13, 7, 17, ink)
    rect(pixels, 4, 14, 6, 16, stone)
    pixel(pixels, 4, 14, stone_light)
    disc(pixels, 10, 12, 2, metal_dark)
    pixel(pixels, 10, 12, pin)
    disc(pixels, 26, 5, 2, ink)
    disc(pixels, 26, 5, 1, metal_light)
    return pixels
end

local function rope(pixels, is_end, depth, at_sheave)
    local start = at_sheave and CENTER or 0
    local base = is_end and math.max(start + 1, 10 + depth * 4) or SIZE - 1
    rect(pixels, 14, start, 16, base, ink)
    rect(pixels, 15, start, 16, base, hemp_dark)
    for y = start, base do
        pixel(pixels, y % 3 == 1 and 16 or 15, y, y % 3 == 0 and hemp_light or hemp)
    end
    if is_end then
        line(pixels, 15, base, 15, base + 4, 1, ink)
        line(pixels, 15, base + 4, 18, base + 4, 1, ink)
        line(pixels, 18, base + 4, 19, base + 1, 1, ink)
        line(pixels, 15, base, 15, base + 4, 0, metal_light)
        line(pixels, 15, base + 4, 18, base + 4, 0, metal)
        line(pixels, 18, base + 4, 19, base + 1, 0, metal_light)
    end
    return pixels
end

local function block(pixels, color, depth)
    local r = (color >> 16) & 255
    local g = (color >> 8) & 255
    local b = color & 255
    local function shade(factor)
        return rgba(math.min(255, math.floor(r * factor)), math.min(255, math.floor(g * factor)),
            math.min(255, math.floor(b * factor)))
    end
    local y = 13 + depth * 4
    rect(pixels, 10, y, 22, y + 10, ink)
    rect(pixels, 11, y + 1, 21, y + 8, shade(0.70))
    rect(pixels, 11, y + 1, 20, y + 5, shade(1.08))
    rect(pixels, 11, y + 1, 20, y + 1, shade(1.35))
    rect(pixels, 20, y + 2, 21, y + 8, shade(0.54))
    pixel(pixels, 13, y + 4, shade(0.92))
    pixel(pixels, 17, y + 3, shade(0.92))
    pixel(pixels, 18, y + 7, shade(0.58))
    return pixels
end

local function brackets(pixels, color, size)
    for _, corner in ipairs{{1, 1, 1, 1}, {30, 1, -1, 1}, {1, 30, 1, -1}, {30, 30, -1, -1}} do
        local x, y, dx, dy = table.unpack(corner)
        for i = 0, size do
            pixel(pixels, x + i * dx, y, color)
            pixel(pixels, x, y + i * dy, color)
        end
    end
    return pixels
end

local function waypoint(pixels, color)
    brackets(pixels, color, 8)
    disc(pixels, CENTER, CENTER, 4, ink)
    disc(pixels, CENTER, CENTER, 3, color)
    return pixels
end

local artists = {
    chassis=chassis, foundation=foundation, mast=mast, prep=prep_deck, dock=dock, hub=hub, rope=rope, block=block,
    menu_crane=menu_crane,
    reach=function(pixels) return brackets(pixels, rgba(81, 183, 168, 130), 4) end,
    queued=function(pixels) return waypoint(pixels, rgba(233, 175, 71)) end,
    marked=function(pixels) return waypoint(pixels, rgba(128, 234, 116)) end,
    hovered=function(pixels) return brackets(pixels, rgba(219, 250, 171), 12) end,
    invalid=function(pixels) return brackets(pixels, rgba(255, 106, 93), 12) end,
    track=function(pixels) return waypoint(pixels, rgba(136, 214, 235)) end,
}

local fallback = {
    chassis={'#', COLOR_BROWN}, prep={'=', COLOR_BROWN}, dock={'=', COLOR_GREY}, hub={'O', COLOR_GREY},
    menu_crane={'C', COLOR_BROWN},
    foundation={'#', COLOR_BROWN}, mast={'H', COLOR_BROWN},
    boom={'-', COLOR_BROWN},
    rope={'|', COLOR_BROWN}, block={254, COLOR_WHITE}, reach={250, COLOR_CYAN},
    queued={'x', COLOR_YELLOW}, marked={'X', COLOR_LIGHTGREEN},
    hovered={'+', COLOR_WHITE}, invalid={'!', COLOR_LIGHTRED}, track={'+', COLOR_LIGHTCYAN},
}

-- DFHack 53.17-r1 can crash when deleting a registered SDL surface. Keep
-- the handles alive and reserve room for single layers when composites fill up.
local TEXTURE_LIMIT = 8192
local SINGLE_LAYER_RESERVE = 2048
local sprites, textures = {}, {}
local texture_count = 0

function layer(name, ...)
    local args = table.pack(...)
    local key = name
    for i = 1, args.n do key = key .. ':' .. tostring(args[i]) end
    if not sprites[key] then
        sprites[key] = {key=key, pixels=artists[name]({}, ...), fallback=fallback[name]}
    end
    return sprites[key]
end

-- Cut one multi-tile drawing into the map buffer's individual 32 px sprites.
local function plot(canvas, x, y, color)
    local tile_x, tile_y = x // SIZE, y // SIZE
    local coords = ('%d,%d'):format(tile_x, tile_y)
    local piece = canvas.tiles[coords]
    if not piece then
        piece = {x=tile_x, y=tile_y, sprite={key=canvas.key .. ':' .. coords, pixels={},
                 fallback=canvas.fallback}}
        canvas.tiles[coords] = piece
        canvas.pieces[#canvas.pieces + 1] = piece
    end
    pixel(piece.sprite.pixels, x % SIZE, y % SIZE, color)
end

local offsets = {}

function shift(sprite, x, y)
    if x == 0 and y == 0 then return {{x=0,y=0,sprite=sprite}} end
    local key = ('%s:%d,%d'):format(sprite.key, x, y)
    if not offsets[key] then
        local canvas = {key=key, tiles={}, pieces={}, fallback=sprite.fallback}
        for i, color in pairs(sprite.pixels) do
            plot(canvas, (i - 1) % SIZE + x, (i - 1) // SIZE + y, color)
        end
        offsets[key] = canvas.pieces
    end
    return offsets[key]
end

local function counterweight(forward, side)
    local width = math.abs(side)
    local edge = math.min(9, forward + 43, -12 - forward)
    if forward < -40 or forward > -17 or width > edge then return end
    if width > edge - 1.1 or forward < -39 or forward > -18 then return ink end
    if math.abs(forward + 33) < 1.25 or math.abs(forward + 22) < 1.25 then
        if side < -4.8 then return metal_light end
        return side > 4.5 and metal_dark or metal
    end
    if side < -4.5 then return stone_light end
    if side > 4 then return stone_dark end
    if math.abs(forward + 27 + side * 0.35) < 0.6 then return stone_dark end
    if (forward + side * 2.95) % 9 < 1 then return stone_light end
    return stone
end

local function armColor(forward, side, length)
    local width = math.abs(side)
    if forward <= -17 then return counterweight(forward, side) end
    local tip = (forward - length)^2 + side^2
    if tip < 14.5 then
        if tip < 1.7 then return hemp end
        if tip > 8.5 then return ink end
        return side < 0 and metal_light or metal
    end
    if forward > length then return end

    local edge = 6.8 - 3.1 * math.max(forward, 0) / length
    local inner_edge = edge - 3.3
    if width > edge then return end
    if width > edge - 0.95 then return ink end
    if width > inner_edge then
        local joint = (forward + 2) % 16
        if joint < 2.5 then
            return joint > 0.7 and width < edge - 1.7 and metal_light or metal_dark
        end
        if side < 0 and width > edge - 1.95 then return wood_light end
        if width < inner_edge + 0.9 then return wood_dark end
        if joint > 8 and joint < 12 and width > edge - 2.55 then return wood end
        return wood_face
    end

    local bay = (forward + 2) % 16
    local brace = (bay / 8 - 1) * inner_edge
    if math.floor((forward + 2) / 16) % 2 == 1 then brace = -brace end
    local distance = math.abs(side - brace)
    if distance < 0.8 then return wood_face end
    if distance < 1.65 then return wood_dark end
end

local arms, arm_count = {}, 0
local angle_step = math.pi / 32

local function armGeometry(angle, extension)
    local direction = math.floor(angle / angle_step + 0.5) % 64
    local length = 2 * math.floor(extension * SIZE / 2 + 0.5)
    return direction, length
end

function sheavePosition(angle, extension, offset_x, offset_y)
    local direction, length = armGeometry(angle, extension)
    local snapped_angle = direction * angle_step
    local x = offset_x + math.floor(length * math.cos(snapped_angle) + 0.5)
    local y = offset_y + math.floor(length * math.sin(snapped_angle) + 0.5)
    local tile_x, tile_y = (x + CENTER) // SIZE, (y + CENTER) // SIZE
    return tile_x, tile_y, x - tile_x * SIZE, y - tile_y * SIZE
end

function arm(angle, extension, offset_x, offset_y)
    local direction, length = armGeometry(angle, extension)
    local key = ('arm:%d:%d:%d,%d'):format(direction, length, offset_x, offset_y)
    if arms[key] then return arms[key] end
    local canvas = {key=key, tiles={}, pieces={}, fallback=fallback.boom}
    local dx, dy = math.cos(direction * angle_step), math.sin(direction * angle_step)
    local cx, cy = CENTER + offset_x, CENTER + offset_y
    local x1, x2 = math.min(-40 * dx, length * dx), math.max(-40 * dx, length * dx)
    local y1, y2 = math.min(-40 * dy, length * dy), math.max(-40 * dy, length * dy)
    for y = math.floor(y1) - 10, math.ceil(y2) + 12 do
        for x = math.floor(x1) - 10, math.ceil(x2) + 12 do
            local forward, side = x * dx + y * dy, y * dx - x * dy
            local color = armColor(forward, side, length)
            if not color and armColor(forward - dx - 2 * dy, side + dy - 2 * dx, length) then
                color = shadow
            end
            if color then plot(canvas, cx + x, cy + y, color) end
        end
    end
    if arm_count >= 192 then arms, arm_count = {}, 0 end
    arms[key], arm_count = canvas.pieces, arm_count + 1
    return arms[key]
end

local function textureFor(layers)
    local composite = #layers > 1
    local key = layers[1].key
    if composite then
        local keys = {}
        for i, sprite in ipairs(layers) do keys[i] = sprite.key end
        key = table.concat(keys, '/')
    end

    if textures[key] then return textures[key] end
    local limit = composite and TEXTURE_LIMIT - SINGLE_LAYER_RESERVE or TEXTURE_LIMIT
    if texture_count >= limit then return end

    local pixels = {}
    for i = 1, SIZE * SIZE do pixels[i] = 0 end
    for _, sprite in ipairs(layers) do
        for i, color in pairs(sprite.pixels) do pixels[i] = color end
    end
    local handle = dfhack.textures.createTile(pixels, SIZE, SIZE)
    if not handle or handle == 0 then return end
    textures[key], texture_count = handle, texture_count + 1
    return handle
end

function pen(layers)
    local top = layers[#layers]
    local glyph = top.fallback
    local map_pen = {ch=glyph[1], fg=glyph[2], keep_lower=true}
    if not dfhack.screen.inGraphicsMode() then return map_pen end
    local handle = textureFor(layers)
    if not handle and #layers > 1 then handle = textureFor({top}) end
    local texpos = handle and dfhack.textures.getTexposByHandle(handle)
    if texpos and texpos > 0 then map_pen.tile = texpos end
    return map_pen
end

local material_colors = {
    [0]=0x69646a, 0x525b87, 0x678257, 0x579193, 0xa45749, 0x9b6594,
    0xb88856, 0xa8aaa2, 0x777879, 0x7487bf, 0x89aa65, 0x80b1be,
    0xb97365, 0xbd87b1, 0xd4b563, 0xd5d1bd,
}

local color_by_token = {}

function blockColor(token)
    if not token then return material_colors[7] end
    local cached = color_by_token[token]
    if cached then return cached end
    local info = dfhack.matinfo.find(token)
    local color = material_colors[7]
    if info then
        local index = info.material.build_color[0] + (info.material.build_color[2] ~= 0 and 8 or 0)
        color = material_colors[index] or color
    end
    color_by_token[token] = color
    return color
end
