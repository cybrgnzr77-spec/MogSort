--[[
* End-to-end test of MogSort.lua inside a simulated Ashita v4 environment.
*
*   texlua tests/test_addon.lua "<path to FFXiMain.dll>"
*
* With a DLL path the signatures are searched in the REAL client code (unpacked in memory from the DLL, which is
* only read), and the jump table / slot addresses come from it. Without one, the test is skipped.
* Simulated: the Ashita API (events, memory reads, pointer manager, settings, chat, ffi), the game's runtime data
* (list objects, the bank window, the focused menu) and the sort helper, which "sends" 0x03A like the client does.
--]]
package.path = './?.lua;./tests/?.lua;' .. package.path;

local dll = arg[1];
if (dll == nil) then print('test_addon: skipped (no FFXiMain.dll path given)'); os.exit(0); end
local text, TEXT_VA = require('pol1').unpack_text(dll);

local passed, failed = 0, 0;
local function check(cond, label)
    if (cond) then passed = passed + 1; else failed = failed + 1; io.stdout:write('FAIL: ' .. label .. '\n'); end
end

---------------------------------------------------------------------------------------------------------------
-- Simulated memory: code bytes from the unpacked .text, data bytes from a sparse table written by the test.
---------------------------------------------------------------------------------------------------------------
local data = {};
local function r8(a)
    if (data[a] ~= nil) then return data[a]; end
    local o = a - TEXT_VA;
    if (o >= 0 and o < #text) then return text:byte(o + 1); end
    return 0;
end
local function r32(a) return r8(a) | (r8(a + 1) << 8) | (r8(a + 2) << 16) | (r8(a + 3) << 24); end
local function w32(a, v) for i = 0, 3 do data[a + i] = (v >> (8 * i)) & 0xFF; end end
local function wstr(a, s) for i = 1, #s do data[a + i - 1] = s:byte(i); end end

local finds = {};
local function find(module, _, pat, off, _)
    assert(module == 'FFXiMain.dll');
    -- Ashita pattern (hex pairs, '??' = any byte) -> Lua pattern ('.' = any, non-alphanumeric bytes escaped).
    local lp = {};
    for i = 1, #pat, 2 do
        local tok = pat:sub(i, i + 1);
        local c = (tok ~= '??') and string.char(tonumber(tok, 16)) or nil;
        lp[#lp + 1] = (c == nil) and '.' or (c:match('%w') and c or ('%' .. c));
    end
    lp = table.concat(lp);
    local first, count, p = nil, 0, 1;
    while true do
        local x = text:find(lp, p);
        if (x == nil) then break; end
        first = first or x; count = count + 1; p = x + 1;
    end
    finds[pat] = count;
    return first and (TEXT_VA + first - 1 + off) or 0;
end

---------------------------------------------------------------------------------------------------------------
-- Simulated Ashita environment
---------------------------------------------------------------------------------------------------------------
local events, printed, saved = {}, {}, 0;
local clock = 1000.0;
local sort_calls = {};
local MENU_PTR = 0x30000000;

addon = {};
ashita = {
    events = { register = function (ev, name, fn) events[ev] = events[ev] or {}; events[ev][name] = fn; end },
    memory = {
        find = find, read_uint32 = r32, read_uint8 = r8,
        read_string = function (a, n) local t = {} for i = 0, n - 1 do t[#t + 1] = string.char(r8(a + i)) end return table.concat(t) end,
    },
};
-- Game data behind the memory / resource managers (filled by the "/mogsort all" scenarios).
local world = {
    bags = {},          -- [bag] = { cap = n, slots = { [slot] = { Id, Count, Flags } } }
    zone = 230, pos = { 0, 0, 0 },
    stack = { [4096] = 12, [4097] = 12, [9000] = 99, [12345] = 1 },
    names = { [4096] = 'Fire Crystal', [4097] = 'Ice Crystal', [9000] = 'Test Ore', [12345] = 'Test Ring' },
    out = {},           -- injected packets { id, bytes }
};
local function bagslots(b) world.bags[b] = world.bags[b] or { cap = 0, slots = {} }; return world.bags[b]; end
local MM = {
    GetInventory = function () return {
        GetContainerCountMax = function (_, b) return bagslots(b).cap; end,
        GetContainerItem = function (_, b, s) return bagslots(b).slots[s] or { Id = 0, Count = 0, Flags = 0 }; end,
    } end,
    GetParty = function () return {
        GetMemberTargetIndex = function () return 1234; end,
        GetMemberZone = function () return world.zone; end,
    } end,
    GetEntity = function () return {
        GetLocalPositionX = function () return world.pos[1]; end,
        GetLocalPositionY = function () return world.pos[2]; end,
        GetLocalPositionZ = function () return world.pos[3]; end,
    } end,
};
AshitaCore = {
    GetPointerManager = function () return { Get = function (_, n) return n == 'menu' and MENU_PTR or 0 end } end,
    GetMemoryManager  = function () return MM; end,
    GetResourceManager = function () return { GetItemById = function (_, id)
        return { StackSize = world.stack[id] or 1, Name = { world.names[id] or ('#' .. id) } }; end } end,
    GetPacketManager  = function () return { AddOutgoingPacket = function (_, id, bytes)
        world.out[#world.out + 1] = { id = id, bytes = bytes }; end } end,
};
os.clock = function () return clock; end

local function fire(ev, e) for _, fn in pairs(events[ev] or {}) do fn(e); end end

package.preload['common'] = function ()
    local mt = { __index = table };
    function table.append(t, v) t[#t + 1] = v; return t; end
    T = function (t) return setmetatable(t or {}, mt); end
    function string.args(s) local t = {} for w in s:gmatch('%S+') do t[#t + 1] = w end return t end
    function string.any(s, ...) for _, v in ipairs({ ... }) do if s == v then return true end end return false end
    return true;
end
package.preload['chat'] = function ()
    local o = {}; o.__index = o;
    function o.append(self, x) return setmetatable({ s = self.s .. x.s }, o) end
    return {
        header  = function (n) return setmetatable({ s = '[' .. n .. '] ' }, o) end,
        message = function (s) return setmetatable({ s = s }, o) end,
        error   = function (s) return setmetatable({ s = 'ERR ' .. s }, o) end,
    };
end
package.preload['settings'] = function ()
    return { load = function (d) return d end, save = function () saved = saved + 1 end, register = function () end };
end
local SORT_FN;
package.loaded['ffi'] = nil;   -- LuaTeX ships its own ffi; replace it with the mock
package.preload['ffi'] = function ()
    return { cast = function (ty, addr)
        assert(ty == 'void (__cdecl *)(int32_t)', 'cast type');
        SORT_FN = addr;
        return function (c)
            sort_calls[#sort_calls + 1] = c;
            -- The real helper queues c2s 0x03A {c}; Ashita reports it through packet_out.
            fire('packet_out', { id = 0x03A, size = 8, data = string.char(0x3A, 0x04, 0, 0, c, 0, 0, 0) });
        end
    end };
end
_G.print = function (s) printed[#printed + 1] = tostring(s.s or s); end

---------------------------------------------------------------------------------------------------------------
-- Load the addon
---------------------------------------------------------------------------------------------------------------
dofile('MogSort.lua');
check(addon.name == 'MogSort' and addon.version == '1.0', 'addon metadata: MogSort 1.0');
fire('load', {});
for p, n in pairs(finds) do check(n == 1, ('signature matches exactly once (%d): %s'):format(n, p:sub(1, 24))); end
check(SORT_FN == 0x101F0460, ('sort helper found at %08X'):format(SORT_FN or 0));
check(#printed == 0, 'no load errors: ' .. (printed[1] or ''));

-- Runtime data the client would hold: list objects in the slot table, the bank window, the menu chain.
local slot_of = {};
local jt = r32(SORT_FN + 0x19);
for c = 0, 16 do slot_of[c] = r32(r32(jt + 4 * c) + 2); end
check(slot_of[1] == 0x10666E30 and slot_of[9] == 0x10666E6C and slot_of[10] == 0x10666E50,
    'slot table read from the client code (Safe 2 sits after the wardrobes)');
for c = 0, 16 do w32(slot_of[c], 0x40000000 + c * 0x1000); end
-- The client's game-state object: the addon finds g_state and the field offsets in the real client code.
-- Raw sizes (ItemNum = slots + 1) at +0x19891, Locker lease (ItemNum2[4]) at +0x198A4 + 8, 2F flag at +0x3C43A.
local G_REF, G = 0x104DFD98, 0x60000000;
w32(G_REF, G);
local function item_num(c, n) data[G + 0x19891 + c] = n; end
for c = 0, 16 do item_num(c, 81); end
data[G + 0x3C43A] = 1; data[G + 0x198A4 + 8] = 81; data[G + 0x198A4 + 9] = 0;
local BANK_GLOBAL = 0x10663468;
local BANK_OBJ = 0x50000000;
w32(BANK_GLOBAL, BANK_OBJ);

local MENU_OBJ, MENU_DATA = 0x30001000, 0x30002000;
w32(MENU_PTR, 0x30000100); w32(0x30000100, MENU_OBJ); w32(MENU_OBJ + 4, MENU_DATA);
local function focus(name)
    if (name == nil) then w32(0x30000100, 0); return; end
    w32(0x30000100, MENU_OBJ);
    wstr(MENU_DATA + 0x46, ('menu    ' .. name .. '        '):sub(1, 16));
end
local function show(c) w32(BANK_OBJ + 0x5C, 0x40000000 + c * 0x1000); end
local function frames(n, dt) for _ = 1, n do clock = clock + (dt or 1 / 60); fire('d3d_present', {}); end end

---------------------------------------------------------------------------------------------------------------
-- Scenarios
---------------------------------------------------------------------------------------------------------------
focus('storage'); frames(10);
check(#sort_calls == 0, 'nothing sorted in the moogle storage menu');

show(1); focus('bank'); frames(30);
check(#sort_calls == 1 and sort_calls[1] == 1, 'opening Mog Safe sorts container 1 once');

focus('inventor'); frames(200); focus('bank'); frames(200);
check(#sort_calls == 1, 'moving focus inside the view does not re-sort');

focus('itmstora'); frames(5); show(9); focus('bank'); frames(5);
check(sort_calls[2] == 9, 'switching to Mog Safe 2 sorts container 9');

focus(nil); frames(5); show(5); focus('bank'); frames(5);
check(sort_calls[3] == 5, '/satchel opened from the field sorts container 5');

-- The game's own Sort > Auto sends 0x03A twice; reopening right after must wait for the gap.
focus(nil); frames(2);
fire('packet_out', { id = 0x03A, size = 8, data = string.char(0x3A, 4, 0, 0, 6, 0, 0, 0) });
show(6); focus('bank'); frames(30);    -- 0.5 s later
check(#sort_calls == 3, 'Sack waits after a recent 0x03A');
frames(120);                           -- +2 s
check(sort_calls[4] == 6, 'Sack sorted once the gap passed');

-- Commands
fire('command', { command = '/mogsort skip locker' });
focus(nil); frames(2); show(4); focus('bank'); frames(10);
check(#sort_calls == 4, 'skipped Locker is not sorted');
fire('command', { command = '/mogsort unskip locker' });
focus(nil); frames(2); focus('bank'); frames(10);
check(sort_calls[5] == 4, 'unskipped Locker sorts again');
fire('command', { command = '/mogsort off' });
focus(nil); frames(2); show(7); focus('bank'); frames(10);
check(#sort_calls == 5, 'off: nothing sorted');
fire('command', { command = '/mogsort on' });
frames(10);
check(sort_calls[6] == 7, 'on: Case sorted');
local e = { command = '/mogsort skip bogus' }; fire('command', e);
check(e.blocked == true and printed[#printed]:find('Unknown container') ~= nil, 'unknown container rejected');
check(saved >= 4, 'settings saved on changes');

-- Moving items into a storage container re-sorts it (packets as the client / server would send them).
local function move(from, to) fire('packet_out', { id = 0x029, size = 12, data = string.char(0x29, 6, 0, 0, 1, 0, 0, 0, from, to, 3, 0x52) }); end
local function attr(bag)  -- s2c 0x020: bag at +0x0E
    fire('packet_in', { id = 0x020, size = 0x2C, data = string.char(0x20, 0x16, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0x10, 0x10, bag, 9) .. string.rep('\0', 0x1C) });
end
local function assign(bag)  -- s2c 0x01F: bag at +0x0A
    fire('packet_in', { id = 0x01F, size = 0x10, data = string.char(0x1F, 8, 0, 0, 1, 0, 0, 0, 0x10, 0x10, bag, 9, 0, 0, 0, 0) });
end
frames(150);
local n0 = #sort_calls;
move(0, 7); frames(3); attr(7); frames(60);
check(sort_calls[n0 + 1] == 7 and #sort_calls == n0 + 1, 'move inventory -> Case re-sorts the Case (0x020)');
frames(150); move(0, 5); frames(3); assign(5); frames(60);
check(sort_calls[n0 + 2] == 5, 'move inventory -> Satchel re-sorts the Satchel (0x01F)');
frames(150); move(7, 7); attr(7); frames(60);
check(#sort_calls == n0 + 2, 'Manual sort move (same bag) does not re-sort');
move(7, 0); attr(0); attr(7); frames(60);
check(#sort_calls == n0 + 2, 'move Case -> inventory does not sort');

-- Zone change resets; inventory and the recycle bin are never sorted by the addon.
local nz = #sort_calls;
focus(nil); move(0, 8); fire('packet_in', { id = 0x00A }); attr(8); frames(200);   -- zoning closes menus, drops the move
check(#sort_calls == nz, 'zoning drops a pending move');
show(7); focus('bank'); frames(10);
check(sort_calls[nz + 1] == 7, 'after zoning the reopened view sorts again');
focus(nil); frames(2); show(0); focus('bank'); frames(10);
check(#sort_calls == nz + 1, 'inventory is never sorted');
w32(BANK_OBJ + 0x5C, 0x4FFFF000); focus(nil); frames(2); focus('bank'); frames(10);
check(#sort_calls == nz + 1, 'unknown list object ignored');


---------------------------------------------------------------------------------------------------------------
-- "/mogsort all"
---------------------------------------------------------------------------------------------------------------
local function state(o)
    w32(G + 0x3C35C, o.room and 0x100 or 0);              -- in a Mog House room
    data[G + 0x40DAC] = o.nomad and 0x40 or 0;             -- zone has a nomad moogle
    w32(G + 0x40C3C, o.visiting or 0);                     -- owner of the house being visited
    data[G + 0x3C43A] = (o.safe2 == false) and 0 or 1;     -- Mog House 2F
    data[G + 0x198A4 + 8] = (o.lease == false) and 0 or 81; data[G + 0x198A4 + 9] = 0;   -- ItemNum2[Locker]
    world.allowed = o.allowed;                             -- bags the simulated server accepts
    for _, b in ipairs({ 1, 9, 2, 4, 5, 6, 7 }) do item_num(b, world.bags[b] and (world.bags[b].cap + 1) or 0); end
end

-- A small server applying c2s 0x029 like LandSandBoat's GP_CLI_COMMAND_ITEM_MOVE (written separately from the
-- addon's own model on purpose), 0.1 s after the packet is sent.
local served, rejected = 0, 0;
local function first_free(b) for i = 1, bagslots(b).cap do if bagslots(b).slots[i] == nil then return i end end end
local function serve()
    for i = #world.out, 1, -1 do
        local o = world.out[i];
        o.age = (o.age or 0) + 1;
        if (o.age >= 6) then
            table.remove(world.out, i);
            local b = o.bytes;
            assert(o.id == 0x29 and #b == 12 and b[1] == 0x29 and b[2] == 0x06, 'malformed 0x029');
            local n, from, to, s1, s2 = b[5] + b[6] * 256 + b[7] * 65536, b[9], b[10], b[11], b[12];
            if (not world.allowed[from] or not world.allowed[to]) then rejected = rejected + 1; goto continue; end
            do
                local it = bagslots(from).slots[s1];
                if (it == nil or it.Flags ~= 0 or it.Count < n) then rejected = rejected + 1; goto continue; end
                if (n < it.Count) then
                    local f = first_free(to); if f == nil then rejected = rejected + 1; goto continue end
                    it.Count = it.Count - n; bagslots(to).slots[f] = { Id = it.Id, Count = n, Flags = 0 };
                elseif (s2 < 82) then
                    local p2 = bagslots(to).slots[s2];
                    if (p2 == nil or p2.Id ~= it.Id or p2.Flags ~= 0) then rejected = rejected + 1; goto continue; end
                    local room = world.stack[it.Id] - p2.Count;
                    local mv = math.min(room, it.Count);
                    p2.Count = p2.Count + mv; it.Count = it.Count - mv;
                    if (it.Count == 0) then bagslots(from).slots[s1] = nil; end
                else
                    local f = first_free(to); if f == nil then rejected = rejected + 1; goto continue end
                    bagslots(to).slots[f] = it; bagslots(from).slots[s1] = nil;
                end
                served = served + 1;
            end
            ::continue::
        end
    end
end
local function run(n) for _ = 1, n do clock = clock + 1 / 60; serve(); fire('d3d_present', {}); end end
local function layout()
    world.bags = {};
    bagslots(1).cap = 80; bagslots(1).slots = { [1] = { Id = 4096, Count = 5, Flags = 0 } };                 -- Safe
    bagslots(9).cap = 80; bagslots(9).slots = { [3] = { Id = 9000, Count = 40, Flags = 0 } };                -- Safe 2
    bagslots(2).cap = 80; bagslots(2).slots = { [1] = { Id = 4096, Count = 12, Flags = 0 } };                -- Storage
    bagslots(4).cap = 80; bagslots(4).slots = {};                                                             -- Locker
    bagslots(5).cap = 80; bagslots(5).slots = { [2] = { Id = 9000, Count = 70, Flags = 0 }, [3] = { Id = 12345, Count = 1, Flags = 0 } };
    bagslots(6).cap = 80; bagslots(6).slots = { [7] = { Id = 4096, Count = 12, Flags = 0 }, [8] = { Id = 4097, Count = 3, Flags = 19 } };
    bagslots(7).cap = 80; bagslots(7).slots = { [1] = { Id = 4096, Count = 3, Flags = 0 }, [2] = { Id = 12345, Count = 1, Flags = 0 }, [3] = { Id = 4097, Count = 2, Flags = 0 } };
end
local function total(b, id) local n = 0 for _, it in pairs(bagslots(b).slots) do if it.Id == id then n = n + it.Count end end return n end
local function holders(id) local t = {} for b = 1, 9 do if total(b, id) > 0 then t[#t + 1] = b end end return table.concat(t, ',') end
local function last_print() return printed[#printed] or ''; end
local ALL = { [0] = true, [1] = true, [9] = true, [2] = true, [4] = true, [5] = true, [6] = true, [7] = true };
local NOMAD_OK = { [0] = true, [1] = true, [9] = true, [4] = true, [5] = true, [6] = true, [7] = true };

check(finds['E8????????F6C4017403B001C38A44240484C07411A1????????F680????????40'] == 1 and
      finds['6A04E8????????83C4046685C00F97C0C3'] == 1, 'location signatures each match once in the client');

-- Out in the field: refused, nothing sent.
focus(nil); layout(); state({ allowed = {} });
fire('command', { command = '/mogsort all' }); run(30);
check(last_print():find('Mog House or talking to a nomad moogle') ~= nil and #world.out == 0 and served == 0,
    'field: refused with a message');

-- Nomad zone but not talking to the moogle: refused.
state({ nomad = true, allowed = NOMAD_OK });
fire('command', { command = '/mogsort all' }); run(30);
check(last_print():find('nomad moogle') ~= nil and served == 0, 'nomad zone without the conversation: refused');

-- Visiting someone else's Mog House: refused.
state({ room = true, visiting = 777, allowed = {} });
fire('command', { command = '/mogsort all' }); run(30);
check(last_print():find('Mog House or talking') ~= nil and served == 0, 'visiting another Mog House: refused');

-- Talk to the nomad moogle (its menu has focus), close it, run. Storage is out of reach and must not be touched.
state({ nomad = true, allowed = NOMAD_OK }); world.pos = { 10, 20, 0 };
focus('mogext'); run(5); focus(nil); run(5);
fire('command', { command = '/mogsort all preview' }); run(30);
check(#world.out == 0 and served == 0, 'preview sends nothing');
local pv = table.concat(printed, '\n');
check(pv:find('Preview %(nomad moogle%)') ~= nil and pv:find('Fire Crystal x12: Mog Sack %-> Mog Safe') ~= nil
    and pv:find('Storage') == nil, 'preview lists the moves and leaves Storage out at a nomad');
local nsorts = #sort_calls;
fire('command', { command = '/mogsort all' });
local during = #sort_calls;
run(600);
check(rejected == 0 and served > 0, ('nomad run: %d moves, none rejected by the server'):format(served));
check(holders(4096) == '1,2' and total(1, 4096) == 20 and total(2, 4096) == 12, 'crystals gathered in the Safe; Storage untouched');
check(holders(9000) == '9' and total(9, 9000) == 110, 'ore gathered in Safe 2 (first bag holding it)');
check(holders(4097) == '6' and bagslots(6).slots[8].Count == 3 and bagslots(6).slots[8].Flags == 19,
    'Ice Crystals join the Sack (first bag) in a new slot; the bazaar stack itself is untouched');
check(holders(12345) == '5,7', 'non-stackable rings are not moved');
check(last_print():find('Done:') ~= nil, 'run reports Done: ' .. last_print());
check(#sort_calls > during, 'targets re-sorted after the run');
local sorted_after = {}; for i = during + 1, #sort_calls do sorted_after[sort_calls[i]] = true end
check(sorted_after[1] and sorted_after[9] and not sorted_after[2], 'the Safe and Safe 2 were re-sorted, Storage not');

-- Own Mog House: Storage included; its crystals move to the Safe.
served, rejected = 0, 0;
layout(); state({ room = true, allowed = ALL }); world.zone = 230;
fire('command', { command = '/mogsort all' });
local s0 = #sort_calls;
run(30);
check(#sort_calls == s0, 'no sorting while the run is moving items');
run(800);
check(rejected == 0 and holders(4096) == '1' and total(1, 4096) == 32, 'Mog House run: Storage crystals gathered too');

-- Walking away from the nomad moogle mid-run stops it.
served, rejected = 0, 0;
layout(); state({ nomad = true, allowed = NOMAD_OK }); world.pos = { 10, 20, 0 };
focus('storage2'); run(3); focus(nil);
fire('command', { command = '/mogsort all' }); run(20);
world.pos = { 30, 20, 0 }; run(60);
check(last_print():find('Stopped: you left') ~= nil and served >= 1 and served < 4, 'walking away stops the run');

-- /mogsort stop and zoning.
layout(); state({ room = true, allowed = ALL });
fire('command', { command = '/mogsort all' }); run(20);
fire('command', { command = '/mogsort stop' });
check(last_print():find('Stopped: cancelled') ~= nil, '/mogsort stop');
fire('command', { command = '/mogsort all' }); run(10);
fire('packet_in', { id = 0x00A });
check(last_print():find('changed zones') ~= nil, 'zoning stops a run');
run(300); world.out = {};

-- Nomad conversation too long ago: refused.
state({ nomad = true, allowed = NOMAD_OK }); world.pos = { 10, 20, 0 };
focus('mogext'); run(2); focus(nil); clock = clock + 120; run(2);
fire('command', { command = '/mogsort all' }); run(5);
check(last_print():find('talking to a nomad moogle') ~= nil, 'nomad conversation over a minute ago: refused');

---------------------------------------------------------------------------------------------------------------
-- Unlock / lease checks before touching a container
---------------------------------------------------------------------------------------------------------------
for c = 0, 16 do item_num(c, 81); end
data[G + 0x3C43A] = 1; data[G + 0x198A4 + 8] = 81;
world.out = {}; focus(nil); run(200);
local function open_view(c) focus(nil); run(3); show(c); focus('bank'); run(10); end

local n1 = #sort_calls;
data[G + 0x3C43A] = 0; open_view(9);
check(#sort_calls == n1, 'auto-sort: Safe 2 without the 2F is not sorted');
data[G + 0x3C43A] = 1; open_view(9);
check(sort_calls[#sort_calls] == 9, 'auto-sort: Safe 2 sorted once the 2F is unlocked');
run(150);
n1 = #sort_calls; data[G + 0x198A4 + 8] = 0; open_view(4);
check(#sort_calls == n1, 'auto-sort: Locker without a lease is not sorted');
data[G + 0x198A4 + 8] = 81;
item_num(5, 20); open_view(5);
check(#sort_calls == n1, 'auto-sort: Satchel below the client threshold is not sorted');
item_num(6, 1); focus(nil); run(150);
move(0, 6); frames(3); attr(6); run(60);
check(#sort_calls == n1, 'auto-sort: move into a Sack with no slots does not sort it');
item_num(14, 0); move(0, 14); attr(14); run(60);
check(#sort_calls == n1, 'auto-sort: move into an unbought Wardrobe 6 does not sort it');
item_num(5, 81); item_num(6, 81); item_num(14, 81);

-- /mogsort all skips a locked Satchel and a Locker without a lease (no packet ever names them).
served, rejected = 0, 0;
layout(); bagslots(4).slots = { [1] = { Id = 9000, Count = 10, Flags = 0 } };
state({ room = true, lease = false, allowed = ALL });
item_num(5, 20);                                   -- Satchel not unlocked (client: ItemNum < 30)
fire('command', { command = '/mogsort all preview' }); run(5);
local pv2 = table.concat(printed, '\n', #printed - 6);
check(pv2:find('Mog Satchel') == nil and pv2:find('Mog Locker') == nil, 'preview: locked Satchel and unleased Locker not listed');
local named = {};
fire('command', { command = '/mogsort all' });
for _ = 1, 900 do
    for _, o in ipairs(world.out) do named[o.bytes[9]] = true; named[o.bytes[10]] = true; end
    run(1);
end
check(not named[5] and not named[4], 'run: no move names the Satchel or the Locker');
check(total(5, 9000) == 70 and total(4, 9000) == 10 and total(9, 9000) == 40, 'their ore stays put; Safe 2 keeps its own');
check(holders(4096) == '1' and rejected == 0, 'the other bags were still gathered, nothing rejected');

io.stdout:write(('test_addon: %d passed, %d failed\n'):format(passed, failed));
os.exit(failed == 0 and 0 or 1);
