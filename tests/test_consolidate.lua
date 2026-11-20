--[[
* Unit tests for consolidate.lua ("/mogsort all"). Run from the addon folder:  texlua tests/test_consolidate.lua
* Simulates the client's location flags, the storage bags, and a server that applies c2s 0x029 the way
* LandSandBoat does (with a delay, and optionally refusing moves).
--]]
package.path = './?.lua;' .. package.path;
local cons = require('consolidate');

local passed, failed = 0, 0;
local function check(cond, label)
    if (cond) then passed = passed + 1; else failed = failed + 1; print('FAIL: ' .. label); end
end
local function list(t) local s = {} for _, v in ipairs(t) do s[#s + 1] = tostring(v) end return table.concat(s, ',') end

-------------------------------------------------------------------------------------------------------------------
-- 1. access(): where am I and which bags are usable
-------------------------------------------------------------------------------------------------------------------
local core = require('sortcore');
-- Builds access() input from readable switches, going through sortcore.unlocked like the addon does.
local function flags(o)
    o = o or {};
    local r = { item_num = {}, locker_lease = (o.locker_lease == false) and 0 or 81,
                safe2 = o.safe2_unlocked ~= false, satchel_min = 30 };
    for _, b in ipairs(cons.BAG_ORDER) do r.item_num[b] = 81; end
    for b, n in pairs(o.item_num or {}) do r.item_num[b] = n; end
    local f = { in_room = false, visiting = 0, zone = 100, nomad_zone = false, nomad_talk = false, unlocked = {} };
    for _, b in ipairs(cons.BAG_ORDER) do f.unlocked[b] = core.unlocked(r, b); end
    for k, v in pairs(o) do if f[k] ~= nil then f[k] = v; end end
    return f;
end
local w, b = cons.access(flags({ in_room = true }));
check(w == 'mog_house' and list(b) == '1,9,2,4,5,6,7', 'own Mog House: all seven bags in menu order');
w, b = cons.access(flags({ in_room = true, safe2_unlocked = false, locker_lease = false }));
check(list(b) == '1,2,5,6,7', 'no 2F and no lease: Safe 2 and Locker left out');
w, b = cons.access(flags({ in_room = true, item_num = { [5] = 20, [6] = 1 } }));
check(list(b) == '1,9,2,4,7', 'Satchel below the client\'s threshold and Sack with no slots: left out');
w = cons.access(flags({ in_room = true, visiting = 12345 }));
check(w == nil, 'visiting another Mog House is refused');
w = cons.access(flags({ in_room = true, zone = 280 }));
check(w == nil, 'Mog Garden is not the Mog House');
w = cons.access(flags({ in_room = true, zone = 285 }));
check(w == nil, 'Feretory is not the Mog House');
w = cons.access(flags({ nomad_zone = true, nomad_talk = false }));
check(w == nil, 'nomad zone without talking to the moogle is refused');
w = cons.access(flags({ nomad_zone = false, nomad_talk = true }));
check(w == nil, 'nomad menu remembered but zone has no nomad moogle: refused');
w, b = cons.access(flags({ nomad_zone = true, nomad_talk = true }));
check(w == 'nomad' and list(b) == '1,9,4,5,6,7', 'nomad: everything but Storage');
w, b = cons.access(flags({ nomad_zone = true, nomad_talk = true, locker_lease = false }));
check(list(b) == '1,9,5,6,7', 'nomad without a Locker lease valid here: Locker left out');
w, b = cons.access(flags({ in_room = true, item_num = { [9] = 0, [4] = 0, [5] = 0, [6] = 0 } }));
check(list(b) == '1,2,7', 'bags with no slots are left out');
w = cons.access(flags({}));
check(w == nil, 'out in the field: refused');

-------------------------------------------------------------------------------------------------------------------
-- 2. nomad latch
-------------------------------------------------------------------------------------------------------------------
local L = cons.new_nomad_latch();
check(not L.active(10, 0, 0, 0, true), 'latch: nothing seen');
L.seen(10, 100, 50, 0);
check(L.active(20, 103, 52, 0, true), 'latch: recent and close');
check(not L.active(20, 107, 50, 0, true), 'latch: 7 yalms away is too far');
check(not L.active(10 + cons.NOMAD_WINDOW + 1, 100, 50, 0, true), 'latch: too old to start a run');
check(L.active(10 + 600, 100, 50, 0, false), 'latch: an ongoing run only needs to stay close');
L.clear();
check(not L.active(20, 100, 50, 0, false), 'latch: cleared on zoning');

-------------------------------------------------------------------------------------------------------------------
-- 3. next_move / plan
-------------------------------------------------------------------------------------------------------------------
local STACK = { [4096] = 12, [4097] = 12, [4112] = 12, [9000] = 99, [12345] = 1, [5000] = 1 };
local function stack_of(id) return STACK[id] or 1; end
local function bag(id, cap, items) local t = {} for s, it in pairs(items) do t[s] = { id = it[1], count = it[2], flags = it[3] or 0 } end return { bag = id, capacity = cap, items = t } end
local function totals(bags) local t = {} for _, b in ipairs(bags) do for _, it in pairs(b.items) do t[it.id] = (t[it.id] or 0) + it.count end end return t end
local function bags_with(bags, id) local n = 0 for _, b in ipairs(bags) do for _, it in pairs(b.items) do if it.id == id then n = n + 1 break end end end return n end

-- Crystals in Safe (partial 5), Sack (12) and Case (3): Safe is first, so everything goes there.
local bags = { bag(1, 80, { [1] = { 4096, 5 } }), bag(9, 80, {}), bag(6, 30, { [4] = { 4096, 12 } }), bag(7, 30, { [2] = { 4096, 3 } }) };
local m = cons.next_move(bags, stack_of);
check(m and m.from == 6 and m.from_slot == 4 and m.to == 1 and m.to_slot == 1 and m.count == 12,
    'first move tops up the partial stack in the first bag');
local moves = cons.plan(bags, stack_of);
local sim = cons.copy(bags); for _, mv in ipairs(moves) do cons.apply(sim, mv, stack_of); end
check(bags_with(sim, 4096) == 1 and totals(sim)[4096] == 20, 'all 20 crystals end up in the Safe');
check(sim[1].items[1].count == 12 and sim[1].items[2].count == 8, 'Safe: one full stack (12) and one of 8');
check(#moves == 3, 'three moves (top up, remainder to a new slot, last stack): ' .. #moves);
check(bags[3].items[4].count == 12, 'plan() does not change its input');

-- Non-stackable items, busy items and single-bag items are left alone.
bags = { bag(1, 80, { [1] = { 12345, 1 }, [2] = { 4097, 4, 19 } }), bag(7, 80, { [1] = { 12345, 1 }, [2] = { 4097, 6 } }), bag(5, 80, { [9] = { 9000, 50 } }) };
m = cons.next_move(bags, stack_of);
check(m and m.id == 4097 and m.to_slot == cons.FREE_SLOT, 'bazaar stack in the first bag is not topped up (new slot instead)');
bags[2].items[2].flags = 5;
check(cons.next_move(bags, stack_of) == nil, 'busy source stacks stay put; non-stackables and single-bag items ignored');

-- Target bag full: reported as blocked, other items still handled.
bags = { bag(1, 2, { [1] = { 4096, 12 }, [2] = { 4112, 12 } }), bag(5, 80, { [1] = { 4096, 5 }, [2] = { 9000, 1 } }), bag(6, 80, { [3] = { 9000, 2 } }) };
local mv, blocked = cons.next_move(bags, stack_of);
check(mv and mv.id == 9000 and mv.from == 6 and mv.to == 5, 'other items still move when one target is full');
moves, blocked = cons.plan(bags, stack_of);
check(#moves == 1 and blocked[4096] == 1, 'full Safe reported as blocked for crystals');

-- Fuzz: random bags; the plan must converge, keep every item, and leave each movable item in one bag.
math.randomseed(7);
local ids = { 4096, 4097, 4112, 9000, 12345, 5000 };
for round = 1, 3000 do
    local bs = {};
    for i, id in ipairs(cons.BAG_ORDER) do
        local cap = math.random(0, 12);
        local items = {};
        for s = 1, cap do
            if (math.random() < 0.6) then
                local iid = ids[math.random(#ids)];
                items[s] = { id = iid, count = math.random(1, STACK[iid]), flags = (math.random() < 0.05) and 19 or 0 };
            end
        end
        bs[i] = { bag = id, capacity = cap, items = items };
    end
    local before = totals(bs);
    local mvs, blk = cons.plan(bs, stack_of);
    local s2 = cons.copy(bs);
    local ok = #mvs < cons.MAX_MOVES;
    for _, x in ipairs(mvs) do
        ok = ok and x.from ~= x.to and x.count > 0 and s2[1] ~= nil;
        local src; for _, bb in ipairs(s2) do if bb.bag == x.from then src = bb end end
        ok = ok and src.items[x.from_slot] ~= nil and src.items[x.from_slot].count == x.count;   -- whole stacks only
        cons.apply(s2, x, stack_of);
    end
    local after = totals(s2);
    for id, n in pairs(before) do ok = ok and after[id] == n; end
    -- every stackable item without busy stacks or a blocked target sits in one bag
    for _, id in ipairs({ 4096, 4097, 4112, 9000 }) do
        local busy = false;
        for _, bb in ipairs(s2) do for _, it in pairs(bb.items) do if it.id == id and it.flags ~= 0 then busy = true end end end
        if (not busy and blk[id] == nil) then ok = ok and bags_with(s2, id) <= 1; end
    end
    -- no slot overflows, no stack above its size
    for _, bb in ipairs(s2) do
        local n = 0;
        for slot, it in pairs(bb.items) do n = n + 1; ok = ok and slot <= bb.capacity and it.count <= STACK[it.id]; end
        ok = ok and n <= bb.capacity;
    end
    if (not ok) then check(false, 'fuzz round ' .. round); break; end
    if (round == 3000) then check(true, 'fuzz: 3000 random layouts converge, keep all items, gather each item'); end
end

-------------------------------------------------------------------------------------------------------------------
-- 4. runner against a simulated server
-------------------------------------------------------------------------------------------------------------------
local function new_world(layout)
    local w = { t = 0, live = cons.copy(layout), queue = {}, sent = {}, allowed = true, refuse = false, done = nil };
    w.runner = cons.new_runner({
        now           = function () return w.t; end,
        read_bags     = function (lst) return w.live; end,
        stack_of      = stack_of,
        send_move     = function (mv) w.sent[#w.sent + 1] = mv; if not w.refuse then w.queue[#w.queue + 1] = { at = w.t + 0.15, m = mv } end end,
        still_allowed = function () return w.allowed; end,
        finished      = function (s) w.done = s; end,
    });
    function w.step(dt)
        w.t = w.t + dt;
        for i = #w.queue, 1, -1 do
            if (w.queue[i].at <= w.t) then cons.apply(w.live, w.queue[i].m, stack_of); table.remove(w.queue, i); end
        end
        w.runner.tick();
    end
    return w;
end
local layout = { bag(1, 80, { [1] = { 4096, 5 } }), bag(6, 30, { [4] = { 4096, 12 } }), bag(7, 30, { [2] = { 4096, 3 }, [5] = { 9000, 7 } }), bag(5, 30, { [1] = { 9000, 9 } }) };
local W = new_world(layout);
W.runner.start({ 1, 6, 7, 5 });
for _ = 1, 400 do W.step(0.05); if W.done then break end end
check(W.done ~= nil and W.done.aborted == nil, 'runner finishes');
check(bags_with(W.live, 4096) == 1 and bags_with(W.live, 9000) == 1, 'runner gathered crystals and the 9000 stacks');
-- Crystals: 7 top up the Safe's 5, the Sack's other 5 take a new slot, the Case's 3 join them (15);
-- the 9000s: first seen in the Case (bag order 1,6,7,5), the Satchel's 9 join it (9). 24 items in all.
check(W.done.items == 24 and W.done.moves == #W.sent, ('runner counts items that actually moved (%d)'):format(W.done.items));
check(W.done.touched[1] and W.done.touched[7] and not W.done.touched[6], 'touched bags = targets only');
check(#W.sent == 4, 'four moves sent: ' .. #W.sent);

-- One move in flight at a time, with MOVE_DELAY after each confirmation.
W = new_world(layout);
local sent_at = {};
W.runner.start({ 1, 6, 7, 5 });
for _ = 1, 400 do local n = #W.sent; W.step(0.05); if #W.sent > n then sent_at[#sent_at + 1] = W.t end if W.done then break end end
local min_gap = math.huge;
for i = 2, #sent_at do min_gap = math.min(min_gap, sent_at[i] - sent_at[i - 1]); end
check(min_gap >= 0.15 + cons.MOVE_DELAY - 1e-9, ('moves are spaced: confirmation + delay (min %.2f s)'):format(min_gap));

-- Server refuses (no confirmation): abort after MOVE_TIMEOUT, only one packet sent.
W = new_world(layout); W.refuse = true;
W.runner.start({ 1, 6, 7, 5 });
for _ = 1, 200 do W.step(0.05); if W.done then break end end
check(W.done and W.done.aborted == 'the server did not confirm a move' and #W.sent == 1, 'unconfirmed move aborts the run');

-- Leaving (walked away / left the house) aborts before the next move.
W = new_world(layout);
W.runner.start({ 1, 6, 7, 5 });
W.step(0.05); W.allowed = false; W.step(0.05);
check(W.done and W.done.aborted ~= nil and #W.sent == 1, 'leaving aborts the run');
-- stop()
W = new_world(layout);
W.runner.start({ 1, 6, 7, 5 }); W.step(0.05); W.runner.stop('cancelled');
check(W.done and W.done.aborted == 'cancelled' and not W.runner.running, '/mogsort stop cancels');
-- Nothing to do.
W = new_world({ bag(1, 80, { [1] = { 4096, 5 } }), bag(7, 80, { [1] = { 9000, 5 } }) });
W.runner.start({ 1, 7 }); W.step(0.05);
check(W.done and W.done.moves == 0 and W.done.aborted == nil and #W.sent == 0, 'nothing to move finishes at once');

-------------------------------------------------------------------------------------------------------------------
-- 5. packet bytes
-------------------------------------------------------------------------------------------------------------------
local p = cons.packet({ from = 6, from_slot = 4, to = 1, to_slot = 0x52, count = 300 });
check(list(p) == table.concat({ 0x29, 0x06, 0, 0, 300 % 256, 1, 0, 0, 6, 1, 4, 0x52 }, ','), '0x029 packet layout');

print(('consolidate: %d passed, %d failed'):format(passed, failed));
os.exit(failed == 0 and 0 or 1);
