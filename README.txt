RAIL CRANE 1.5.2
Dwarf Fortress Steam 53.17 with DFHack 53.17-r1

INSTALL
Close Dwarf Fortress. In Steam, open Dwarf Fortress > Manage > Browse local
files to open the game folder.

Extract Rail-Crane-1.5.2.zip into the game folder. Let Windows merge the
dfhack-config and mods folders and replace the Rail Crane scripts.

If you use Code > Download ZIP on the main branch, open the folder inside
the archive. Copy its dfhack-config and mods folders into the game folder.

The game folder should now contain dfhack-config/scripts/rail-crane.lua
and mods/rail_crane/info.txt. Launch the game with DFHack. For a new
installation, open Mods on the Create New World screen and add Rail Crane
before generating.

To update, close the game, extract over the existing installation,
and reopen the same save. Built cranes and queued columns persist.

The mod list reads the display version from info.txt. If it still shows an
older version after extraction, close the game and copy mods/rail_crane/info.txt into
the existing rail_crane (2) folder under data/installed_mods. Steam may
keep that folder under %APPDATA%/Bay 12 Games/Dwarf Fortress instead of
the game directory.

BUILD A CRANE
1. Open Build > Machines/Fluids > Rail Crane. Use [-] and [+] in the
   placement panel to set the boom height. Height +0 works at the base level.
2. Click a dry floor for a stationary crane or a level track for a rolling
   crane. The route can turn or close into a loop. Use one continuous path
   without junctions. Leave an adjacent dry floor for the rear platform and
   open air through and above the mast and rear platform along the route.
3. Choose two blocks, one mechanism, one rope or chain, and at least two
   logs in the native material picker. Each extra z-level adds one log.
   Logs can be mixed from any wood. Unpause for a dwarf to build the crane.

The completed workshop is the dock. A rolling crane starts from the dock,
lines up with each target when possible, and stretches past a track end
when necessary. On a loop it takes the shortest clear route to its chosen
stop. Extend its track, add turns, or close the loop and it will detect
the change automatically.

You can run one crane per connected track, including
cranes still under construction. Cranes on separate tracks can work at
the same time. If you join tracks that both have a crane, both cranes
pause and keep their queues until you split the tracks or remove one crane.

BUILD WALL COLUMNS
Click the crane's base, mast, rear platform, or dock and select Build. Move
the map and change z-levels with your normal controls. Highlighting shows
the crane's horizontal reach. Click individual column tops, or switch to Outline,
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

The selected z-level is included, up to the crane's boom. Columns start at
solid ground, seabed, or existing masonry. Leave open space for the cable.
The crane can lower into water. A wall below the surface stays under water.
The wall displaces water in the volume it occupies. Piers and towers need
walkable access for the crew.

The crew works at the base, and a raised boom hoists each block from the
rear platform before swinging to the target. A rolling crane waits for an
adult civilian dwarf to board and ride to the next stop. The same dwarf can
prepare blocks and operate the boom. A dedicated worker can use a burrow
covering the base, rear platform, and any track it uses.

DISMANTLE
Use Dismantle crane in its controls to give a dwarf a normal building
removal job at the dock. The boom stops while the job is pending.

Built walls are part of the fortress. Crane positions, heights, boom angles, block
choices and queued progress are saved with the site. On reload an interrupted
lift starts again from block preparation.

If the workshop is built but the crane controls do not appear, check that
DFHack is running and the Rail Crane overlays are enabled in its control
panel.
