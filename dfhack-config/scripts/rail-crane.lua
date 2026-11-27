-- Ground and rail cranes for block-wall columns
--@ module = true
--@ enable = true

--[====[
rail-crane
==========

Build a stationary crane on dry ground or a rolling crane on level
minecart track, including bends and loops. Raise the boom with extra logs
to build taller walls.
The crane uses fortress blocks to build ordinary walls bottom-up.

Order a Rail Crane from Build > Machines/Fluids and choose its boom height.
Once a dwarf has built it, click the crane base, mast, or dock, choose Build,
and mark the tops of the columns. The crane runs when unpaused.

Use `rail-crane list` to see each crane's position and status,
`rail-crane cancel ID` to discard its pending designations, and
`rail-crane remove ID` to order dismantling. Use `rail-crane pause`
and `rail-crane resume` to control all cranes at this fortress.
]====]

local rail = reqscript('internal/rail-crane/rail')
local engine = reqscript('internal/rail-crane/engine')
local native = reqscript('internal/rail-crane/native')
local ui = reqscript('internal/rail-crane/ui')
local api = engine.getAPI()

isEnabled = engine.isEnabled
setEnabled = engine.setEnabled
getAPI = engine.getAPI
OVERLAY_WIDGETS = ui.overlay(api)
OVERLAY_WIDGETS.build_menu = native.buildMenuOverlay()

if dfhack_flags.module then return end

local args = {...}
local command = args[1]
if not command or command == 'gui' then
    if not engine.isAvailable() then qerror('Load a fortress first.') end
    ui.show(api, tonumber(args[2]))
elseif command == 'place' then
    qerror('Place a Rail Crane from Build > Machines/Fluids on a dry floor or level track.')
elseif command == 'list' then
    for _, crane in ipairs(api.list()) do
        print(('#%d %s | %d columns | %s'):format(crane.id, rail.coordinates(crane.rail[crane.index]), #crane.queue, crane.status))
    end
elseif command == 'cancel' then
    if not api.cancel(args[2]) then qerror('No crane with that ID.') end
elseif command == 'remove' then
    local ok, reason = api.dismantle(args[2])
    if not ok then qerror(reason) end
elseif command == 'pause' or command == 'resume' then
    if not setEnabled(command == 'resume') then qerror('Load a fortress first.') end
elseif command == 'help' or command == '--help' then
    print('Build a Rail Crane from Build > Machines/Fluids.')
    print('rail-crane [gui [ID]] | list | cancel ID | remove ID | pause | resume')
else
    qerror('Unknown command. Run rail-crane help.')
end

