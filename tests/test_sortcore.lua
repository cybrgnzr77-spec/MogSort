--[[
* Unit tests for sortcore.lua. Run from the addon folder:  texlua tests/test_sortcore.lua   (any Lua 5.1+ works)
* Simulates the clock, the focused menu, the storage view's list object and the game's sort helper.
--]]
package.path = './?.lua;' .. package.path;
local core = require('sortcore');

local passed, failed = 0, 0;
local function check(cond, label)
    if (cond) then passed = passed + 1; else failed = failed + 1; print('FAIL: ' .. label); end
end

-- A fake game: slot addresses 0x1000 + 4*i hold list objects 0xA000 + c (container c).
local function fake_game()
    local g = { t = 100.0, menu = nil, shown = nil, sorted = {}, disabled = {} };
    g.slots = {};
    local layout = { [0]=0, 1, 2, 5, 6, 7, 3, 4, 8, 10, 11, 12, 13, 14, 15, 16, 9 }; -- like the client: Safe 2 last
    for i = 0, 16 do g.slots[0x1000 + 4 * i] = layout[i]; end
    g.sorter = core.new({
        now          = function () return g.t; end,
        menu_name    = function () return g.menu; end,
        bank_list    = function () return g.shown and (0xA000 + g.shown) or nil; end,
        list_of_slot = function (slot) return 0xA000 + g.slots[slot]; end,
        slots        = g.slots,
        sort         = function (c) g.sorted[#g.sorted + 1] = c; end,
        is_enabled   = function (c) return not g.disabled[c]; end,
    });
    return g;
end

-- 1. Helpers
check(core.short_menu_name('menu    bank    ') == 'bank', 'short name strips padding');
check(core.short_menu_name('menu    itmsortw') == 'itmsortw', 'short name full width');
check(core.short_menu_name('menu    bank\0\0\0\0') == 'bank', 'short name NUL padded');
check(core.short_menu_name('xxxx    bank    ') == nil, 'short name rejects other prefixes');
check(core.short_menu_name(nil) == nil, 'short name nil');
check(core.container_id('Safe2') == 9 and core.container_id('9') == 9, 'container_id by name / number');
check(core.container_id('inventory') == nil and core.container_id('0') == nil and core.container_id('17') == nil,
    'container_id rejects inventory and recycle bin');
check(core.container_name(16) == 'wardrobe8', 'container_name');

-- 2. Sorts once when the storage view opens on a container.
local g = fake_game();
g.menu = 'storage'; g.sorter.tick();
check(#g.sorted == 0, 'no sort in the moogle menu');
g.menu = 'bank'; g.shown = 1; g.sorter.tick();
check(#g.sorted == 1 and g.sorted[1] == 1, 'sorts Mog Safe on open');
for _ = 1, 20 do g.t = g.t + 0.05; g.sorter.tick(); end
check(#g.sorted == 1, 'does not re-sort while the view stays open');

-- 3. Moving around inside the view does not re-sort (keeps a Manual sort intact).
for _, m in ipairs({ 'inventor', 'itmsortw', 'sortyn', 'itemctrl', 'bank' }) do
    g.menu = m; g.t = g.t + 3; g.sorter.tick();
end
check(#g.sorted == 1, 'no re-sort when focus moves within the storage view');

-- 4. Switching the view to another container sorts that one (Safe 2: the table's last slot).
g.menu = 'itmstora'; g.sorter.tick();
g.menu = 'bank'; g.shown = 9; g.t = g.t + 0.1; g.sorter.tick();
check(g.sorted[2] == 9, 'switch to Safe 2 sorts Safe 2');

-- 5. Closing and reopening sorts again.
g.menu = 'storage'; g.sorter.tick();
g.menu = 'bank'; g.shown = 1; g.t = g.t + 5; g.sorter.tick();
check(g.sorted[3] == 1, 'reopen sorts again');
g.menu = nil; g.sorter.tick();
g.menu = 'bank'; g.t = g.t + 5; g.sorter.tick();
check(g.sorted[4] == 1, 'closing to no menu also ends the session');

-- 6. Rate limit: a 0x03A for the container within MIN_GAP delays our sort until the gap has passed.
g = fake_game();
g.sorter.on_sort_packet(5);                    -- e.g. the user just pressed Sort > Auto on the Satchel
g.menu = 'bank'; g.shown = 5;
g.t = g.t + 0.5; g.sorter.tick();
check(#g.sorted == 0, 'waits after a recent 0x03A (0.5 s)');
g.t = g.t + core.MIN_GAP - 0.6; g.sorter.tick();
check(#g.sorted == 0, 'still waits just under MIN_GAP');
g.t = g.t + 0.2; g.sorter.tick();
check(#g.sorted == 1 and g.sorted[1] == 5, 'sorts once the gap has passed');
-- Our own sort counts too: reopen right away must wait.
g.menu = 'storage'; g.sorter.tick();
g.menu = 'bank'; g.t = g.t + 0.3; g.sorter.tick();
check(#g.sorted == 1, 'reopen within MIN_GAP of our own sort waits');
g.t = g.t + core.MIN_GAP; g.sorter.tick();
check(#g.sorted == 2, 'then sorts');

-- 7. Never two sorts of one container closer than MIN_GAP, whatever the menu does (fuzz).
g = fake_game();
math.randomseed(1234);
local menus = { 'bank', 'bank', 'inventor', 'storage', nil, 'itmstora', 'sortyn' };
local last, worst = {}, math.huge;
for _ = 1, 20000 do
    g.t = g.t + math.random() * 0.3;
    g.menu = menus[math.random(#menus)];
    g.shown = ({ 1, 2, 5, 9, 16 })[math.random(5)];
    if (math.random() < 0.05) then g.sorter.on_sort_packet(g.shown); last[g.shown] = g.t; end
    local before = #g.sorted;
    g.sorter.tick();
    if (#g.sorted > before) then
        local c = g.sorted[#g.sorted];
        if (last[c]) then worst = math.min(worst, g.t - last[c]); end
        last[c] = g.t;
    end
end
check(#g.sorted > 100, 'fuzz produced sorts (' .. #g.sorted .. ')');
check(worst >= core.MIN_GAP, ('fuzz: minimum gap %.2f s >= MIN_GAP'):format(worst));

-- 8. Disabled / unhandled containers and odd states.
g = fake_game();
g.disabled[4] = true;
g.menu = 'bank'; g.shown = 4; g.sorter.tick();
check(#g.sorted == 0, 'skipped container is not sorted');
g.shown = 0; g.sorter.tick();
check(#g.sorted == 0, 'inventory on the storage side is not sorted');
g.shown = 17; g.sorter.tick();
check(#g.sorted == 0, 'unknown list object (recycle bin) is ignored');
g.shown = nil; g.sorter.tick();
check(#g.sorted == 0, 'no bank object is ignored');
g.shown = 7; g.sorter.reset(); g.sorter.tick();
check(g.sorted[1] == 7, 'reset (zone) then open sorts');

-- 10. Re-sort after moving items into a storage container.
g = fake_game();
g.menu = 'bank'; g.shown = 1; g.sorter.tick();                 -- open Mog Safe: sorted on open
check(g.sorted[1] == 1, 'move: open sorts first');
g.t = g.t + 3;
g.sorter.on_move(0, 1);                                         -- inventory -> Safe
g.t = g.t + 0.1; g.sorter.on_item_update(1);                   -- server confirms (0x020 for the Safe)
g.t = g.t + 0.2; g.sorter.tick();
check(#g.sorted == 1, 'move: waits for SETTLE after the last update');
g.t = g.t + 0.4; g.sorter.tick();
check(g.sorted[2] == 1, 'move: Safe re-sorted after the move settles');
g.t = g.t + 0.2; g.sorter.on_item_update(1); g.t = g.t + 1; g.sorter.tick();
check(#g.sorted == 2, 'move: updates after the re-sort (stack merges) do not re-sort again');

-- Several quick moves give one sort, and never within MIN_GAP of the previous one.
g.t = g.t + 0.3;
for _ = 1, 5 do g.sorter.on_move(0, 1); g.t = g.t + 0.1; g.sorter.on_item_update(1); g.t = g.t + 0.15; g.sorter.tick(); end
check(#g.sorted == 2, 'move burst: no sort while moves keep coming');
g.t = g.t + 0.6; g.sorter.tick();
check(#g.sorted == 3 and g.sorted[3] == 1, 'move burst: one sort once quiet');
local t3 = g.t;
g.sorter.on_move(0, 1); g.t = g.t + 0.05; g.sorter.on_item_update(1); g.t = g.t + 0.6; g.sorter.tick();
check(#g.sorted == 3, 'move: held back inside MIN_GAP of the last sort');
g.t = t3 + core.MIN_GAP + 0.01; g.sorter.tick();
check(#g.sorted == 4, 'move: sorted when the gap allows');

-- Moves that must not trigger a sort.
local n = #g.sorted;
g.sorter.on_move(1, 1); g.sorter.on_item_update(1); g.t = g.t + 3; g.sorter.tick();
check(#g.sorted == n, 'Manual sort (same source and target bag) is left alone');
g.sorter.on_move(1, 0); g.sorter.on_item_update(0); g.sorter.on_item_update(1); g.t = g.t + 3; g.sorter.tick();
check(#g.sorted == n, 'moving out of the Safe to the inventory does not sort');
g.sorter.on_item_update(5); g.t = g.t + 3; g.sorter.tick();
check(#g.sorted == n, 'item updates without a move (zone-in resend) do not sort');
g.sorter.on_move(0, 6); g.t = g.t + core.MOVE_TIMEOUT + 1; g.sorter.on_item_update(6); g.t = g.t + 3; g.sorter.tick();
check(#g.sorted == n, 'an unconfirmed move expires');
g.disabled[7] = true;
g.sorter.on_move(0, 7); g.sorter.on_item_update(7); g.t = g.t + 3; g.sorter.tick();
check(#g.sorted == n and g.sorter.dirty[7] == nil, 'skipped container is not re-sorted');

-- Works without the storage view open (e.g. another addon moving items to the Satchel in the field).
g.menu = nil; g.sorter.tick();
g.sorter.on_move(0, 5); g.sorter.on_item_update(5); g.t = g.t + 0.6; g.sorter.tick();
check(g.sorted[#g.sorted] == 5, 'move into Satchel re-sorts it with no menu open');
-- Zoning drops pending moves.
g.sorter.on_move(0, 8); g.sorter.reset(); g.sorter.on_item_update(8); g.t = g.t + 3; g.sorter.tick();
check(g.sorted[#g.sorted] == 5, 'reset drops pending moves');

-- 11. Gap fuzz with moves mixed in.
g = fake_game();
math.randomseed(99);
last, worst = {}, math.huge;
for _ = 1, 20000 do
    g.t = g.t + math.random() * 0.3;
    g.menu = menus[math.random(#menus)];
    g.shown = ({ 1, 2, 5, 9, 16 })[math.random(5)];
    local r = math.random();
    local c = ({ 1, 2, 5, 9, 16 })[math.random(5)];
    if (r < 0.05) then g.sorter.on_sort_packet(c); last[c] = g.t;
    elseif (r < 0.25) then g.sorter.on_move(math.random(0, 2) == 0 and c or 0, c);
    elseif (r < 0.45) then g.sorter.on_item_update(c); end
    local before = #g.sorted;
    g.sorter.tick();
    if (#g.sorted > before) then
        local s = g.sorted[#g.sorted];
        if (last[s]) then worst = math.min(worst, g.t - last[s]); end
        last[s] = g.t;
    end
end
check(#g.sorted > 300, 'fuzz with moves produced sorts (' .. #g.sorted .. ')');
check(worst >= core.MIN_GAP, ('fuzz with moves: minimum gap %.2f s >= MIN_GAP'):format(worst));

-- 12. Paused while "/mogsort all" runs; queue_sort afterwards.
g = fake_game();
g.sorter.set_paused(true);
g.menu = 'bank'; g.shown = 1; g.sorter.tick();
g.sorter.on_move(0, 5); g.sorter.on_item_update(5); g.t = g.t + 3; g.sorter.tick();
check(#g.sorted == 0, 'paused: no open-sort and no move re-sort');
g.sorter.set_paused(false);
g.sorter.queue_sort(9); g.sorter.queue_sort(0);
g.menu = nil; g.t = g.t + 0.2; g.sorter.tick();
check(#g.sorted == 0, 'queue_sort waits for SETTLE');
g.t = g.t + 0.4; g.sorter.tick();
check(g.sorted[1] == 9 and #g.sorted == 1, 'queue_sort sorts the queued storage bag (not the inventory)');
g.t = g.t + 3; g.sorter.tick();
check(#g.sorted == 1, 'the move seen while paused was dropped');

-- 13. Unlock / lease checks (sortcore.unlocked).
local function raw(o)
    local r = { item_num = {}, locker_lease = 81, safe2 = true, satchel_min = 30 };
    for c = 0, 16 do r.item_num[c] = 81; end
    for k, v in pairs(o or {}) do if k == 'n' then for c, n in pairs(v) do r.item_num[c] = n end else r[k] = v end end
    return r;
end
check(core.capacity(raw(), 1) == 80 and core.capacity(raw({ n = { [6] = 1 } }), 6) == 0 and core.capacity(raw({ n = { [6] = 0 } }), 6) == 0,
    'capacity = ItemNum - 1, never negative');
local all = true;
for c in pairs(core.CONTAINERS) do all = all and core.unlocked(raw(), c); end
check(all, 'everything unlocked: every container usable');
check(not core.unlocked(raw({ safe2 = false }), 9), 'Safe 2 without the 2F: locked');
check(not core.unlocked(raw({ locker_lease = 0 }), 4), 'Locker without a lease: locked');
check(not core.unlocked(raw({ n = { [5] = 29 } }), 5) and core.unlocked(raw({ n = { [5] = 30 } }), 5),
    'Satchel needs ItemNum >= 30 (the client\'s own test)');
check(not core.unlocked(raw({ n = { [6] = 1 } }), 6), 'Sack with no slots: locked');
check(not core.unlocked(raw({ n = { [12] = 0 } }), 12), 'Wardrobe 4 not bought: locked');
check(core.unlocked(raw({ safe2 = false, locker_lease = 0 }), 1), 'Mog Safe unaffected by other flags');

-- 9. build_slot_map against synthetic code bytes (layout of the real helper's cases).
local mem = {};
local function w32(a, v) for i = 0, 3 do mem[a + i] = math.floor(v / 256 ^ i) % 256; end end
local function r8(a) return mem[a] or 0; end
local function r32(a) return r8(a) + r8(a + 1) * 256 + r8(a + 2) * 65536 + r8(a + 3) * 16777216; end
local jt, code = 0x5000, 0x6000;
for c = 0, 16 do
    local case = code + c * 0x20;
    w32(jt + 4 * c, case);
    mem[case] = 0x8B; mem[case + 1] = 0x0D; w32(case + 2, 0x7000 + 4 * c); mem[case + 6] = 0x6A; mem[case + 7] = c;
end
local map = core.build_slot_map(r32, r8, jt);
check(map ~= nil and map[0x7000 + 4 * 9] == 9 and map[0x7000] == 0, 'build_slot_map reads the cases');
mem[code + 3 * 0x20 + 7] = 4;
check(core.build_slot_map(r32, r8, jt) == nil, 'build_slot_map rejects a case pushing the wrong id');
mem[code + 3 * 0x20 + 7] = 3; mem[code + 3 * 0x20] = 0x90;
check(core.build_slot_map(r32, r8, jt) == nil, 'build_slot_map rejects unexpected code');

print(('sortcore: %d passed, %d failed'):format(passed, failed));
os.exit(failed == 0 and 0 or 1);
