--@ module = true

local gui = require('gui')
local widgets = require('gui.widgets')
local sprites = reqscript('internal/rail-crane/sprites')

local COUNT_WIDTH = 10
local DISTANCE_WIDTH = 10
local COLUMN_GAP = 2
local ICON_WIDTH = 2
local blockIcons = {}

local function icon(token)
    local color = sprites.blockColor(token)
    if not blockIcons[color] then
        local source = sprites.layer('block', color, 0)
        local pixels = {}
        -- Enlarge the loaded block's silhouette for the smaller interface grid.
        for y = 0, 31 do
            for x = 0, 31 do
                local value = source.pixels[(11 + y // 2) * 32 + 9 + x // 2]
                if value then pixels[y * 32 + x + 1] = value end
            end
        end
        blockIcons[color] = {key='picker-block:' .. color, pixels=pixels, fallback=source.fallback}
    end
    return sprites.pen({blockIcons[color]})
end

local MaterialPicker = defclass(nil, gui.ZScreenModal)
MaterialPicker.ATTRS{
    focus_path='rail-crane-material',
    needed=DEFAULT_NIL,
    choices=DEFAULT_NIL,
    on_select=DEFAULT_NIL,
}

function MaterialPicker:labelWidth()
    local list = self.subviews.materials
    local width = list and list.frame_body and list.frame_body.width or 68
    return math.max(8, width - ICON_WIDTH - COUNT_WIDTH - DISTANCE_WIDTH - 2 * COLUMN_GAP - 1)
end

function MaterialPicker:makeChoices()
    local choices = {}
    for _, row in ipairs(self.choices) do
        local material = row.label .. ' blocks'
        choices[#choices + 1] = {
            token=row.token,
            search_key=material,
            icon=function() return icon(row.token) end,
            text={
                {text=material, width=function() return self:labelWidth() end},
                {text=dfhack.formatInt(row.count), gap=COLUMN_GAP, width=COUNT_WIDTH, rjustify=true,
                    pen=row.count >= self.needed and COLOR_LIGHTGREEN or COLOR_YELLOW},
                {text=row.distance and (dfhack.formatInt(row.distance) .. ' t') or '-',
                    gap=COLUMN_GAP, width=DISTANCE_WIDTH, rjustify=true, pen=COLOR_GREY},
            },
        }
    end
    return choices
end

function MaterialPicker:init()
    local list = widgets.FilteredList{
        view_id='materials',
        frame={l=0,r=0,t=4,b=2},
        choices=self:makeChoices(),
        icon_width=ICON_WIDTH,
        row_height=2,
        edit_pen=COLOR_WHITE,
        text_pen=COLOR_WHITE,
        cursor_pen={fg=COLOR_LIGHTCYAN,bg=COLOR_BLACK},
        not_found_label=#self.choices > 0 and 'No matching materials.' or 'No construction blocks available.',
        on_submit=function(_, choice)
            self:dismiss()
            self.on_select(choice.token)
        end,
    }
    list.edit.frame.l, list.edit.frame.r = 1, 1
    list.list.frame.t = 4
    list.not_found.frame.t = 4

    self:addviews{widgets.Window{
        frame={l=2,t=4,w=72,b=3},
        frame_style=gui.FRAME_MEDIUM,
        frame_title='Wall materials',
        frame_background={ch=' ',fg=COLOR_WHITE,bg=COLOR_BLACK},
        resizable=false,
        draggable=false,
        subviews={
            widgets.Label{
                frame={l=0,r=0,t=0},
                text={
                    {text='Amount needed  ', pen=COLOR_GREY},
                    {text=dfhack.formatInt(self.needed), pen=COLOR_YELLOW},
                },
            },
            widgets.Label{
                frame={l=0,r=0,t=2},
                text='Search blocks',
                text_pen=COLOR_LIGHTCYAN,
            },
            widgets.Panel{
                frame={l=0,r=0,t=3,h=3},
                frame_style=gui.FRAME_INTERIOR,
            },
            widgets.Label{
                frame={l=ICON_WIDTH,r=0,t=7},
                text={
                    {text='Material', width=function() return self:labelWidth() end},
                    {text='In stock', gap=COLUMN_GAP, width=COUNT_WIDTH, rjustify=true},
                    {text='Distance', gap=COLUMN_GAP, width=DISTANCE_WIDTH, rjustify=true},
                },
                text_pen=COLOR_GREY,
            },
            list,
            widgets.HotkeyLabel{
                frame={l=0,b=0},
                key='LEAVESCREEN',
                label='Back',
                on_activate=self:callback('dismiss'),
            },
        },
    }}
end

function show(options)
    return MaterialPicker(options):show()
end
