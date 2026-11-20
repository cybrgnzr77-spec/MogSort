# MogSort 1.0 (Ashita v4)

Sorts your storage containers automatically the moment you open them: Mog Safe, Mog Safe 2, Storage,
Mog Locker, Mog Satchel, Mog Sack, Mog Case and Mog Wardrobes 1–8. The result is exactly what you'd get by
pressing **Sort → Auto** yourself, and it follows your **Config → Gameplay → Sort Type** setting.

[Downloads\(https://github.com/cybrgnzr77-spec/MogSort/releases)

## Install

1. Download the repository (Code → Download ZIP) or clone it, and put its files in `Ashita/addons/MogSort/`,
   so you have `Ashita/addons/MogSort/MogSort.lua`. The `tests` folder is optional.
2. In game: `/addon load mogsort`. To load it every time, add that line to your Ashita startup script.

## Use

There's nothing to do: open a container and it's already sorted. If you use **Switch** inside the storage view
to show another container, that one gets sorted too.

| Command | Effect |
|---|---|
| `/mogsort` | Show status and commands |
| `/mogsort on` / `off` | Turn auto-sorting on or off (saved) |
| `/mogsort skip <container>` | Never auto-sort that container, e.g. `/mogsort skip locker` |
| `/mogsort unskip <container>` | Undo a skip |
| `/mogsort verbose` | Print a line each time a container is sorted |
| `/mogsort all` | Gather duplicate stacks across your storage (see below) |
| `/mogsort all preview` | Show what `/mogsort all` would move, without moving anything |
| `/mogsort stop` | Stop a running `/mogsort all` |

Container names: `safe safe2 storage locker satchel sack case wardrobe wardrobe2 … wardrobe8`.

The inventory isn't touched. Use the game's own **Config → Gameplay → Auto-sort** option for that.

### Only bags you've unlocked

Before touching a container, whether sorting it or moving items in or out, MogSort checks that you have it,
using the same flags the game's storage menus use. It checks again right before every move:

- **Mog Safe 2:** needs the Mog House 2nd floor.
- **Mog Locker:** needs a lease that's valid where you are. The server only sends the Locker's size when it is.
- **Mog Satchel:** must be unlocked (the client's test: raw size of 30 or more).
- **Mog Sack and Wardrobes 2–8:** must be bought.
- **Every container:** must have at least one slot.

Anything that isn't available is skipped without a message.

### When it sorts

- **When you open a container.** A container is sorted **once per opening**. Moving the cursor between the two
  lists or using **Manual** sort doesn't trigger another sort, so your manual order isn't undone. Close the view
  and open it again, and it sorts again.
- **After a move.** When you move items **into** a storage container from another container, that container
  is sorted again once the server confirms the move. This works with the storage view open or closed, for
  example when another addon moves items for you. Several quick moves result in one sort about half a second
  after the last one.
- **What doesn't trigger a re-sort:** moving items *out* of a container (it stays in order), a move the server
  refuses, and Manual sort. Manual sort moves items within one container, so it's ignored and your manual
  order stays.

## Gathering duplicate stacks: `/mogsort all`

Finds stackable items that sit in more than one storage bag and moves every stack of each one into the
**first bag that holds it**. "First" follows the game's menu order: Mog Safe, Mog Safe 2, Storage, Mog Locker,
Mog Satchel, Mog Sack, Mog Case. Wardrobes and the inventory are never touched.

- **Where it works:** in **your own Mog House**, or while **talking to a nomad moogle**. Talking means the nomad
  moogle's menu (or a storage window opened from it) was open within the last minute, and you're still within
  6 yalms of where you were then, the range at which the game closes that menu. Anywhere else, or when visiting
  someone else's Mog House, it says so and does nothing.
- **Which bags:** only bags you've unlocked (see above) that the server lets you use where you are.
  **Storage is left out at a nomad moogle**, because the server only allows it in your own Mog House.
- **How it moves:** partial stacks in the target bag are topped up first; anything left over goes into a free
  slot. Only whole stacks are sent: the server tops up what fits and leaves the rest in place.
- **What stays put:** non-stackable items, and stacks that are busy (bazaar, equipped and so on). A busy stack
  never moves; other stacks of that item can still join its bag.
- **Full bags:** if the target bag has no room, that item's other stacks stay where they are, and you're told
  which item and bag.
- **Pacing:** one move at a time. MogSort waits until the inventory shows the server applied each move, then
  pauses 0.4 s before the next. Auto-sorting is paused during the run; afterwards, each bag that received items
  is sorted once.
- **It stops cleanly** (every move is complete on its own) if you zone, leave the Mog House, walk away from the
  nomad moogle, type `/mogsort stop`, or if the server doesn't confirm a move within 4 s.

## Safety

- **Server rate limit.** LandSandBoat servers drop a sort packet (0x03A) sent within 1 second of the previous
  one for the same container. After 4 drops the character is logged out as a "lightluggage" bot. MogSort watches
  every outgoing 0x03A, including the ones the game sends when you press Sort → Auto yourself. It never sorts a
  container within 2 seconds of the last one; if it's too soon, it waits.
- **Sorting:** MogSort doesn't craft sort packets or write game memory. It reads memory and calls the game's own
  "sort this container" routine, the same one the Sort menu uses.
- **`/mogsort all`** sends the same item-move packet (0x029) the storage window sends, one at a time. It only
  touches bags the server allows where you are (the rules are in LandSandBoat's `0x029_item_move.cpp`). LSB
  drops any move it rejects with just a log line, so a wrong guess can't hurt your character; MogSort would
  notice the missing confirmation and stop.
- **Unsupported client?** If the routine can't be found, for example after a client update, MogSort prints an
  error and does nothing.

## How it works

FFXiMain.dll's code is stored compressed (section `POL1`) and unpacked at start-up. In the unpacked code:

- **The sort routine.** `0x101F0460` is a small cdecl routine, `sort_container(int container)`. It switches over
  containers 0–16. For each one it loads that container's item-list object and calls the routine that rebuilds
  and sorts the client-side display order (`0x1021C7C0` → `0x1021C7E0`, using the Sort Type setting). That second
  routine also queues c2s **0x03A {container}**, which makes the server merge partial stacks. The display order
  lives in the client, which is why sending 0x03A by itself only merges stacks and doesn't reorder anything.
- **Which container is open.** The storage view's window object is stored in a global; the routine that opens
  the view at `0x101DAF70` loads it. That object's field `+0x5C` points to the list object of the container it
  shows. MogSort compares that pointer against the list objects that `sort_container` uses. It reads this mapping
  from the routine's jump table at run time, because the order isn't simple: Safe 2 comes after the wardrobes.
- **When the view is open.** That's detected from the focused menu's name, `menu    bank`.
- **Moves.** Item moves are seen in c2s **0x029**: the source bag is at +0x08 and the target bag at +0x09. The
  server's confirmation arrives as s2c **0x020** (bag at +0x0E) or **0x01F** (bag at +0x0A). A container is
  re-sorted only when an update arrives for it within 5 seconds of a move into it from a different bag. That
  way zone-in item resends never trigger sorts.

For `/mogsort all` and the unlock checks, small getters in the client give the flags below. All of them live in the client's
game-state object, and MogSort reads the field offsets out of the getters' code at load time:

| Flag | Field |
|---|---|
| In a Mog House room | `+0x3C35C`, bit 0x100 |
| Zone has a nomad moogle | `+0x40DAC`, bit 0x40 (the zone-in handler copies it from s2c 0x00A byte 0xAF) |
| Owner of the house being visited (0 = your own) | `+0x40C3C` |
| Mog House 2F, for Safe 2 | `+0x3C43A`, bit 0 |
| Locker lease | `ItemNum2[4]` at `+0x198A4` (s2c 0x01C; LSB sends a Locker size only when the lease is valid where you are) |
| Raw bag sizes (size + 1) | `ItemNum[c]` at `+0x19891`; the Satchel counts as unlocked at 30 or more (threshold read from the client's code) |

The Mog Garden and the Feretory also count as rooms, but they aren't your Mog House, so they're excluded by
zone id.

All signatures are matched at load time with `ashita.memory.find`. Each one matches exactly once in the client
(the tests check this).

## Tests

```
sh tests/run_all.sh                                  # logic tests
sh tests/run_all.sh "<path>/FFXiMain.dll"            # + end-to-end against the real client code (read-only)
```

These need a Lua 5.3 interpreter; `texlua` works, or set `LUA=lua5.3`.

**`tests/test_sortcore.lua`** covers the auto-sort state machine with a simulated clock, menus and storage view:

- **Opening a container,** switching to another, and reopening.
- **Re-sorting after moves:** settling, bursts of moves, Manual sort, moves out, unconfirmed moves and zoning.
- **Pausing during `/mogsort all`,** and the sort queued for each bag afterwards.
- **Two 20 000-step fuzz runs,** one with moves mixed in, checking that no container is ever sorted within
  2 seconds of a previous 0x03A.

**`tests/test_consolidate.lua`** covers `/mogsort all`'s logic:

- **The access rules:** your own Mog House, nomad moogles, visiting, Mog Garden and Feretory, and missing bags.
- **The nomad range and time window.**
- **The planner,** over 3,000 random storage layouts. Every run must finish, keep every item, move only whole
  stacks, never overfill a bag or a stack, and leave each movable item in one bag.
- **The runner,** against a simulated server: spacing between moves, an unconfirmed move, leaving, stopping,
  and having nothing to do.
- **The packet's bytes.**

**`tests/test_addon.lua`** loads `MogSort.lua` in a simulated Ashita v4 environment. It unpacks the given
FFXiMain.dll in memory (the file is only read), finds every signature in the real code, and reads the real jump
table and getter offsets. It then plays through:

- **Auto-sort:** open, switch, reopen, `/satchel` from the field, a recent manual sort, moves into the Case and
  Satchel (confirmed by 0x020 or 0x01F), Manual sort, moves out, the commands, zoning, and the inventory and
  unknown containers.
- **`/mogsort all` refusals:** in the field, at a nomad zone without talking to the moogle, when visiting, and
  when the conversation was too long ago.
- **`/mogsort all` runs,** against a separate model of LSB's move handler: preview sends nothing, the nomad run
  leaves Storage alone, the own-house run includes it, bazaar stacks and non-stackables stay put, nothing is
  sorted during a run and each bag that received items is sorted after.
- **Stopping:** walking away, `/mogsort stop`, and zoning.
- **Unlock checks:** Safe 2 without the 2F, a Locker without a lease, a Satchel below the client's threshold, a
  Sack with no slots, and an unbought Wardrobe are never sorted. `/mogsort all` never names a locked bag in a
  move and leaves its items in place.

Test totals: 59 in `test_sortcore.lua`, 39 in `test_consolidate.lua`, and 63 in `test_addon.lua`.

## Credits and license

MogSort is released under the **GNU General Public License v3.0 or later** (see `LICENSE`).

The only code-level borrowing is the focused-menu pointer chain from Ashita's `autologin` addon, which is GPL-3.0
and so compatible. Everything else listed below supplied facts (packet layouts, server rules, file formats) or
notes that guided the research. MogSort's code was written from scratch, and the credit is given here.

- **Ashita Development Team / atom0s** (GPL-3.0): the focused-menu pointer chain follows `get_menu_name()` from
  Ashita's bundled `autologin` addon.
- **Windower team:** the 0x03A, 0x029, 0x01F and 0x020 packet layouts, and the meaning of byte 0xAF in 0x00A
  (`addons/libs/packets/fields.lua`).
- **LandSandBoat** (GPL-3.0): the server-side 0x03A behaviour and rate limit (`src/map/packets/c2s/0x03a_item_stack.cpp`),
  which updates a move sends back and which bags are usable where (`0x029_item_move.cpp`), the zone-in flags
  (`0x00a_login.cpp`), and the Locker size in `0x01c_item_max.cpp`.
- **lenonk/vana-client** (MIT, © 2026 Lenon Kitchens): reverse-engineering notes on the client's sort views,
  storage menus and game-state fields, and the POL1 packing format. The test helper `tests/pol1.lua` implements
  that format from the notes' description. Every address above was then checked against the unpacked
  FFXiMain.dll.

FFXiMain.dll and all other game files belong to Square Enix and are **not** included. The end-to-end test reads
your own copy, only when you pass its path.
