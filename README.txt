RAIL CRANE 1.4.2
Dwarf Fortress Steam 53.17 with DFHack 53.17-r1

INSTALL
Close Dwarf Fortress. In Steam, open Dwarf Fortress > Manage > Browse local
files. Extract the ZIP into that folder. Let Windows merge its mods and
dfhack-config folders and replace the Rail Crane scripts. Launch the
game with DFHack. For a new installation, open Mods on the Create New
World screen and add Rail Crane before generating.

To update, close the game, extract over the existing installation,
and reopen the same save. Built cranes and queued columns persist.

The mod list reads the display version from info.txt. If it still shows an
older version after extraction, close the game and copy mods/rail_crane/info.txt into
the existing rail_crane (2) folder under data/installed_mods. Steam may
keep that folder under %APPDATA%/Bay 12 Games/Dwarf Fortress instead of
the game directory.

BUILD A CRANE
1. Build or carve a level, straight minecart track at least two tiles long
   on dry land or on a pier or tower. Use north-south or east-west tracks
   with connected ends. Leave a dry floor tile at one end for the
   carriage's rear platform. Keep the track and rear deck clear
   one z-level above.
2. Open Build > Machines/Fluids > Rail Crane and click one of the track tiles.
   Choose two blocks and one mechanism in the usual material picker.
   Unpause so a dwarf can build the workshop.
3. The completed workshop stays in place as the crane's dock. The carriage
   detects the connected track and starts from the dock. It lines up
   alongside a target when possible and uses the shortest available
   reach when the end of the track or an obstruction prevents alignment.
   Extend the connected straight track in either direction to increase
   coverage. Join the new rails to the existing end and leave room for the
   rear deck. The crane updates its coverage as the game runs.

You can run one crane per connected straight stretch of track, including
cranes still under construction. Cranes on separate tracks can work at
the same time. If you join tracks that both have a crane, both cranes
pause and keep their queues until you split the tracks or remove one crane.

BUILD WALL COLUMNS
Click the crane's cab, rear deck, or dock and select Build. Move the map and
change z-levels with your normal controls. Highlighting shows the horizontal
reach along the track. Click individual column tops, or switch to Outline,
click corners on one level, and use Close outline to mark the perimeter.

Choose blocks after marking opens a searchable picker with the number of
blocks needed, stock counts, and distances from the crane. Finished blocks
in a workshop, loose blocks, and blocks in available bins can all be used.
Use closest blocks chooses the nearest available material for the batch.
Reuse last material keeps the previous choice while supplies replenish.
Select Keep marking after placement to start another batch right away.

Unpause to start. Each queued marker stays at the requested top level
until the last wall goes in. Use the regular construction removal
designation to remove a finished wall.

Block preparation, lifting, and setting take four times the previous
amount of in-game work time. The boom rewinds and retracts along its last
working angle. It holds that angle until the crew starts the next lift.

The selected z-level is included, up to the crane's deck. Columns start at
solid ground, seabed, or existing masonry. Leave open space for the cable.
The crane can lower into water. A wall below the surface stays under water.
The wall displaces water in the volume it occupies. Piers and towers need
walkable access for the crew.

The crane waits for an available adult civilian dwarf to board before it
rolls. The operator rides to the next stop. The same dwarf can prepare
blocks and operate the boom there. A dedicated worker can use a burrow
that includes the crane's full track and rear platform path.

DISMANTLE
Use Dismantle crane in its controls to give a dwarf a normal building
removal job at the dock. The boom stops while the job is pending.

Built walls are part of the fortress. Crane positions, boom angles, block
choices and queued progress are saved with the site. On reload an interrupted
lift starts again from block preparation.

If the workshop is built but the crane controls do not appear, check that
DFHack is running and the Rail Crane overlays are enabled in its control
panel.
