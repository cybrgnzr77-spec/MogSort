--[[
* MogSort - Auto-sorts Mog House storage containers (Safe, Safe 2, Storage, Locker, Satchel, Sack, Case,
*           Wardrobes 1-8) the moment their storage view is opened, and again after you move items into one,
*           exactly as the menu's Sort > Auto does.
*
* Copyright (c) 2026 MogSort contributors
*
* This program is free software: you can redistribute it and/or modify it under the terms of the GNU General
* Public License as published by the Free Software Foundation, either version 3 of the License, or (at your
* option) any later version. This program is distributed WITHOUT ANY WARRANTY; see the LICENSE file.
*
* Credits:
*   - Focused-menu pointer chain ("menu" pointer -> +0x04 -> name at +0x46) follows the get_menu_name() helper
*     of Ashita's bundled 'autologin' addon by atom0s (Ashita Development Team, GPL-3.0).
*   - Packet layouts (0x03A, 0x029, 0x01F, 0x020): Windower Lua packets/fields.lua (Windower team).
*   - Server-side 0x03A rate limit: LandSandBoat src/map/packets/c2s/0x03a_item_stack.cpp (GPL-3.0).
*   - Client sort internals located with help from the notes of lenonk/vana-client (MIT), then verified against
*     the unpacked FFXiMain.dll code (see README).
--]]

addon.name    = 'MogSort';
addon.author  = 'MogSort contributors';
addon.version = '1.0';
addon.desc    = 'Sorts Mog House storage containers automatically when you open them.';
addon.link    = 'https://github.com/cybrgnzr77-spec/MogSort';

require('common');
local chat     = require('chat');
local ffi      = require('ffi');
local settings = require('settings');
local core     = require('sortcore');
local cons     = require('consolidate');

-------------------------------------------------------------------------------------------------------------------
-- Signatures (FFXiMain.dll). Each one was checked to match exactly once in the unpacked client code.
-------------------------------------------------------------------------------------------------------------------

-- sort_container(int container), cdecl: switch over containers 0..16; each case runs the container's
-- Sort > Auto (view rebuild + c2s 0x03A). Starts: mov eax,[esp+4]; cmp eax,12h; jge; cmp eax,10h; ja; jmp [tbl+eax*4]
local SIG_SORT = '8B44240483F8120F8D????????83F8100F87????????FF2485????????8B0D????????6A006A016A00E8';
local SORT_JUMPTABLE_OFFSET = 0x19;   -- the jmp [eax*4 + table] operand inside SIG_SORT

-- Where the storage-view opener stores the bank window object: mov eax,[g_bank]; mov cl,[esp+14h]; ...;
-- mov byte [eax+70h],1; mov [eax+71h],cl. Offset 1 lands on the [g_bank] operand.
local SIG_BANK = 'A1????????8A4C241483C404C64070018848718B0D????????6A0057E8';
local BANK_LIST_OFFSET = 0x5C;        -- bank window: list object of the container it shows (set on open / switch)

-- "/mogsort all" location checks. All of these read the client's game-state object (g_state):
-- FUN in_room_or_nomad(bool nomad): call in_room_getter; test ah,1 (state+0x3C35C bit 0x100 = in a Mog House room);
-- ...; mov eax,[g_state]; test byte [eax+0x40DAC],40h (zone has a nomad moogle; set from s2c 0x00A byte 0xAF).
local SIG_ROOM_NOMAD = 'E8????????F6C4017403B001C38A44240484C07411A1????????F680????????40';
-- visiting_owner(): mov eax,[eax+0x40C3C] (owner of the Mog House being visited, 0 = none / our own).
local SIG_VISITING   = '8B44240485C07509A1????????85C074078B803C0C0400C3';
-- safe2_flag(): mov cl,[eax+0x3C43A] (bit 0: Mog House 2F, needed for Mog Safe 2).
local SIG_SAFE2      = '8B44240485C07509A1????????85C0740B33C98A883AC403008BC1C3';
-- locker_lease(): push 4; call item_num2(container); test ax,ax; seta al. item_num2 reads u16 [eax+ecx*2+0x198A4]
-- (s2c 0x01C ItemNum2; the server sends the Locker's only while a lease is valid where you are).
local SIG_LOCKER     = '6A04E8????????83C4046685C00F97C0C3';
-- item_num(container): mov al,[eax+ecx+0x19891] (s2c 0x01C ItemNum, u8 per container = size + 1).
local SIG_ITEMNUM    = 'A1????????85C075030CFFC38B4C24048A8408????????C3';
-- satchel_ok(): cmp byte [eax+0x19896],1Eh; jb (the client's "Satchel unlocked" test: ItemNum[5] >= 30).
local SIG_SATCHEL    = 'A1????????85C0740C80B8????????1E7203B001C3';

local POLL_INTERVAL = 0.05;           -- seconds between checks (cheap: a few memory reads)
local NOMAD_MENUS   = { mogext = true, storage2 = true };   -- the nomad moogle's menu and its Storage submenu

-------------------------------------------------------------------------------------------------------------------
-- Settings
-------------------------------------------------------------------------------------------------------------------

local defaults = T{
    enabled = true,
    verbose = false,
    skip    = T{},    -- container names the user turned off, e.g. { 'locker' }
};

local mogsort = {
    settings  = settings.load(defaults),
    ready     = false,
    sort_fn   = nil,
    bank_ref  = 0,     -- address of the global that holds the bank window pointer
    slots     = nil,
    sorter    = nil,
    next_poll = 0,
    loc       = nil,   -- addresses for the location checks (nil: "/mogsort all" unavailable)
    latch     = cons.new_nomad_latch(),
    runner    = nil,
    stacks    = {},    -- item id -> stack size cache
};

local function msg(text)
    print(chat.header(addon.name):append(chat.message(text)));
end

local function err(text)
    print(chat.header(addon.name):append(chat.error(text)));
end

local function is_skipped(name)
    for _, v in ipairs(mogsort.settings.skip) do
        if (v == name) then return true; end
    end
    return false;
end

settings.register('settings', 'mogsort_settings_update', function (s)
    if (s ~= nil) then mogsort.settings = s; end
    settings.save();
end);

-------------------------------------------------------------------------------------------------------------------
-- Game memory access
-------------------------------------------------------------------------------------------------------------------

---Short name of the focused menu ("bank", "inventor", ...) or nil when no menu has focus.
local function menu_name()
    local ptr = AshitaCore:GetPointerManager():Get('menu');
    if (ptr == 0) then return nil; end
    ptr = ashita.memory.read_uint32(ptr);
    if (ptr == 0) then return nil; end
    ptr = ashita.memory.read_uint32(ptr);
    if (ptr == 0) then return nil; end
    ptr = ashita.memory.read_uint32(ptr + 0x04);
    if (ptr == 0) then return nil; end
    return core.short_menu_name(ashita.memory.read_string(ptr + 0x46, 16));
end

---List object shown on the storage side of the open storage view.
local function bank_list()
    local bank = ashita.memory.read_uint32(mogsort.bank_ref);
    if (bank == 0) then return nil; end
    return ashita.memory.read_uint32(bank + BANK_LIST_OFFSET);
end

---Finds the location-check addresses from the client's own getters (offsets are read from their code).
local function init_location()
    local m  = ashita.memory.find('FFXiMain.dll', 0, SIG_ROOM_NOMAD, 0, 0);
    local v  = ashita.memory.find('FFXiMain.dll', 0, SIG_VISITING, 0, 0);
    local s2 = ashita.memory.find('FFXiMain.dll', 0, SIG_SAFE2, 0, 0);
    local lk = ashita.memory.find('FFXiMain.dll', 0, SIG_LOCKER, 0, 0);
    local inum = ashita.memory.find('FFXiMain.dll', 0, SIG_ITEMNUM, 0, 0);
    local sat  = ashita.memory.find('FFXiMain.dll', 0, SIG_SATCHEL, 0, 0);
    if (m == 0 or v == 0 or s2 == 0 or lk == 0 or inum == 0 or sat == 0) then return nil; end

    local r32, r8 = ashita.memory.read_uint32, ashita.memory.read_uint8;
    -- in_room getter: target of the call at m (E8 rel32): mov eax,[g_state]; ...; mov eax,[eax+off]; ret
    local rel = r32(m + 1);
    if (rel >= 0x80000000) then rel = rel - 0x100000000; end
    local getter = (m + 5 + rel) % 0x100000000;
    if (r8(getter) ~= 0xA1 or r8(getter + 0x0A) ~= 0x8B or r8(getter + 0x0B) ~= 0x80) then return nil; end
    -- locker getter: target of the call at lk+2: ...; mov ax,[eax+ecx*2+off]; ret
    rel = r32(lk + 3);
    if (rel >= 0x80000000) then rel = rel - 0x100000000; end
    local item_num2 = (lk + 7 + rel) % 0x100000000;
    if (r8(item_num2 + 0x12) ~= 0x66 or r8(item_num2 + 0x13) ~= 0x8B) then return nil; end
    -- The Satchel test must read ItemNum[5] from the same table item_num() uses.
    local item_num_off = r32(inum + 0x13);
    if (r32(sat + 0x0B) ~= item_num_off + 5) then return nil; end

    return {
        item_num_off = item_num_off,            -- 0x19891 (u8 per container)
        satchel_min  = r8(sat + 0x0F),          -- 30
        state_ref  = r32(m + 0x16),             -- address of g_state
        room_off   = r32(getter + 0x0C),        -- 0x3C35C (bit 0x100)
        nomad_off  = r32(m + 0x1C),             -- 0x40DAC
        nomad_bit  = r8(m + 0x20),              -- 0x40
        visit_off  = r32(v + 0x13),             -- 0x40C3C
        safe2_off  = r32(s2 + 0x15),            -- 0x3C43A (bit 0)
        locker_off = r32(item_num2 + 0x16) + 2 * 4,   -- ItemNum2[4]
    };
end

---Player position (x, y, z) or nil.
local function player_pos()
    local idx = AshitaCore:GetMemoryManager():GetParty():GetMemberTargetIndex(0);
    if (idx == nil or idx == 0) then return nil; end
    local e = AshitaCore:GetMemoryManager():GetEntity();
    return e:GetLocalPositionX(idx), e:GetLocalPositionY(idx), e:GetLocalPositionZ(idx);
end

---Raw unlock data for sortcore.unlocked(): sizes, Locker lease, 2F flag. nil when the game state isn't there.
local function client_raw()
    local L = mogsort.loc;
    local r32, r8 = ashita.memory.read_uint32, ashita.memory.read_uint8;
    local g = r32(L.state_ref);
    if (g == 0) then return nil; end
    local n = {};
    for c = 0, 17 do n[c] = r8(g + L.item_num_off + c); end
    return {
        item_num     = n,
        locker_lease = r8(g + L.locker_off) + r8(g + L.locker_off + 1) * 256,
        safe2        = r8(g + L.safe2_off) % 2 == 1,
        satchel_min  = L.satchel_min,
    };
end

---True when the container is unlocked (Locker: leased) right now.
local function unlocked(c)
    local raw = client_raw();
    return raw ~= nil and core.unlocked(raw, c);
end

---Reads the client's location flags for consolidate.access().
local function client_flags(fresh)
    local L = mogsort.loc;
    local r32, r8 = ashita.memory.read_uint32, ashita.memory.read_uint8;
    local g = r32(L.state_ref);
    if (g == 0) then return nil; end
    local raw = client_raw();
    if (raw == nil) then return nil; end
    local open = {};
    for _, b in ipairs(cons.BAG_ORDER) do open[b] = core.unlocked(raw, b); end
    local x, y, z = player_pos();
    return {
        in_room        = (r32(g + L.room_off) % 0x200) >= 0x100,
        visiting       = r32(g + L.visit_off),
        zone           = AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0),
        nomad_zone     = math.floor(r8(g + L.nomad_off) / L.nomad_bit) % 2 == 1,
        nomad_talk     = x ~= nil and mogsort.latch.active(os.clock(), x, y, z, fresh),
        unlocked       = open,
    };
end

---Live contents of the given bags, in the given order.
local function read_bags(list)
    local inv = AshitaCore:GetMemoryManager():GetInventory();
    local raw = client_raw() or { item_num = {} };
    local out = {};
    for i, b in ipairs(list) do
        local cap = core.capacity(raw, b);   -- the server's size (ItemNum - 1), used for free-slot counts
        local items = {};
        for slot = 1, cap do
            local it = inv:GetContainerItem(b, slot);
            if (it ~= nil and it.Id ~= 0 and it.Id ~= 0xFFFF) then
                items[slot] = { id = it.Id, count = it.Count, flags = it.Flags };
            end
        end
        out[i] = { bag = b, capacity = cap, items = items };
    end
    return out;
end

local function stack_of(id)
    local n = mogsort.stacks[id];
    if (n == nil) then
        local res = AshitaCore:GetResourceManager():GetItemById(id);
        n = (res ~= nil and res.StackSize) or 1;
        mogsort.stacks[id] = n;
    end
    return n;
end

local function item_name(id)
    local res = AshitaCore:GetResourceManager():GetItemById(id);
    return (res ~= nil and res.Name ~= nil and res.Name[1]) or ('item ' .. id);
end

---Prints the end-of-run report and queues sorts for the bags that received items.
local function on_finished(sum)
    mogsort.sorter.set_paused(false);
    for b in pairs(sum.touched) do mogsort.sorter.queue_sort(b); end
    if (sum.aborted ~= nil) then
        err(('Stopped: %s. Moved %d stack(s), %d item(s) so far.'):format(sum.aborted, sum.moves, sum.items));
        return;
    end
    if (sum.moves == 0 and next(sum.blocked) == nil) then
        msg('No duplicate stacks found. Nothing to move.');
    else
        msg(('Done: %d move(s), %d item(s) gathered.'):format(sum.moves, sum.items));
    end
    for id, bag in pairs(sum.blocked) do
        err(('%s: %s is full; the other stacks were left where they are.'):format(item_name(id), cons.BAG_NAMES[bag]));
    end
end

---"/mogsort all [preview]"
local function cmd_all(preview)
    if (mogsort.runner.running) then
        msg('Already running. Use /mogsort stop to cancel.');
        return;
    end
    local f = client_flags(true);
    local where, bags = nil, {};
    if (f ~= nil) then where, bags = cons.access(f); end
    if (where == nil) then
        err('You must be in your Mog House or talking to a nomad moogle to use /mogsort all.');
        return;
    end
    if (#bags < 2) then
        msg('Fewer than two storage bags are usable here; nothing to gather.');
        return;
    end

    local names = {};
    for _, b in ipairs(bags) do names[#names + 1] = cons.BAG_NAMES[b]; end
    if (preview) then
        local moves, blocked = cons.plan(read_bags(bags), stack_of);
        msg(('Preview (%s): %d move(s). Bags: %s'):format(where == 'nomad' and 'nomad moogle' or 'Mog House',
            #moves, table.concat(names, ', ')));
        for i = 1, math.min(#moves, 20) do
            local m = moves[i];
            msg(('  %s x%d: %s -> %s'):format(item_name(m.id), m.count, cons.BAG_NAMES[m.from], cons.BAG_NAMES[m.to]));
        end
        if (#moves > 20) then msg(('  ... and %d more'):format(#moves - 20)); end
        for id, bag in pairs(blocked) do
            err(('%s: %s is full; the other stacks would stay where they are.'):format(item_name(id), cons.BAG_NAMES[bag]));
        end
        return;
    end

    msg('Gathering duplicate stacks across: ' .. table.concat(names, ', ') .. '. /mogsort stop cancels.');
    mogsort.sorter.set_paused(true);
    mogsort.runner.start(bags);
end

---Finds the signatures and builds the sorter. Returns true on success.
local function init()
    local fn = ashita.memory.find('FFXiMain.dll', 0, SIG_SORT, 0, 0);
    local bk = ashita.memory.find('FFXiMain.dll', 0, SIG_BANK, 1, 0);
    if (fn == 0 or bk == 0) then
        err('Could not find the game\'s sort routine (unsupported client version). Addon disabled.');
        return false;
    end

    local slots = core.build_slot_map(ashita.memory.read_uint32, ashita.memory.read_uint8,
        ashita.memory.read_uint32(fn + SORT_JUMPTABLE_OFFSET));
    if (slots == nil) then
        err('The game\'s sort routine does not look as expected. Addon disabled.');
        return false;
    end

    mogsort.loc = init_location();
    if (mogsort.loc == nil) then
        err('Could not find the game\'s storage unlock flags (unsupported client version). Addon disabled.');
        return false;
    end

    mogsort.sort_fn  = ffi.cast('void (__cdecl *)(int32_t)', fn);
    mogsort.bank_ref = ashita.memory.read_uint32(bk);
    mogsort.slots    = slots;
    mogsort.sorter   = core.new({
        now          = os.clock,   -- wall-clock seconds on Windows
        menu_name    = menu_name,
        bank_list    = bank_list,
        list_of_slot = ashita.memory.read_uint32,
        slots        = slots,
        sort         = function (c) mogsort.sort_fn(c); end,
        -- Never touch a container the player hasn't unlocked (or a Locker without a current lease).
        is_enabled   = function (c)
            return mogsort.settings.enabled and not is_skipped(core.container_name(c)) and unlocked(c);
        end,
        log          = function (m) if (mogsort.settings.verbose) then msg(m); end end,
    });

    mogsort.runner = cons.new_runner({
        now           = os.clock,
        read_bags     = read_bags,
        stack_of      = stack_of,
        send_move     = function (m) AshitaCore:GetPacketManager():AddOutgoingPacket(0x29, cons.packet(m)); end,
        still_allowed = function ()
            local f = client_flags(false);
            if (f == nil) then return false; end
            local where, bags = cons.access(f);
            if (where == nil) then return false; end
            -- every bag the run started with must still be usable
            local ok = {};
            for _, b in ipairs(bags) do ok[b] = true; end
            for _, b in ipairs(mogsort.runner.bags_list) do if (not ok[b]) then return false; end end
            return true;
        end,
        finished      = on_finished,
    });
    return true;
end

-------------------------------------------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------------------------------------------

ashita.events.register('load', 'mogsort_load', function ()
    mogsort.ready = init();
end);

ashita.events.register('unload', 'mogsort_unload', function ()
    settings.save();
end);

-- Track every 0x03A leaving the client (the game's own Sort > Auto included) so we never crowd the server's
-- one-per-second-per-container limit. Byte 0x04 of the packet is the container.
-- Also watch item moves (0x029: +0x08 source bag, +0x09 target bag) to re-sort the container that received items.
ashita.events.register('packet_out', 'mogsort_packet_out', function (e)
    if (not mogsort.ready) then return; end
    if (e.id == 0x03A and e.size >= 5) then
        mogsort.sorter.on_sort_packet(e.data:byte(0x04 + 1));
    elseif (e.id == 0x029 and e.size >= 0x0A) then
        mogsort.sorter.on_move(e.data:byte(0x08 + 1), e.data:byte(0x09 + 1));
    end
end);

-- Item updates confirm a move (0x01F: bag at +0x0A, 0x020: bag at +0x0E). Zoning (0x00A) closes every menu.
ashita.events.register('packet_in', 'mogsort_packet_in', function (e)
    if (not mogsort.ready) then return; end
    if (e.id == 0x01F and e.size >= 0x0B) then
        mogsort.sorter.on_item_update(e.data:byte(0x0A + 1));
    elseif (e.id == 0x020 and e.size >= 0x0F) then
        mogsort.sorter.on_item_update(e.data:byte(0x0E + 1));
    elseif (e.id == 0x00A) then
        mogsort.runner.stop('you changed zones');
        mogsort.latch.clear();
        mogsort.sorter.reset();
    end
end);

ashita.events.register('d3d_present', 'mogsort_present', function ()
    if (not mogsort.ready) then return; end
    local now = os.clock();
    if (now < mogsort.next_poll) then return; end
    mogsort.next_poll = now + POLL_INTERVAL;

    -- Remember talking to a nomad moogle: its menu (or a storage view it opened) has focus.
    if (mogsort.loc ~= nil) then
        local name = menu_name();
        local nomad = name ~= nil and NOMAD_MENUS[name];
        if (not nomad and name == 'bank') then
            local bank = ashita.memory.read_uint32(mogsort.bank_ref);
            nomad = bank ~= 0 and ashita.memory.read_uint8(bank + 0x70) == 1 and ashita.memory.read_uint8(bank + 0x71) == 1;
        end
        if (nomad) then
            local x, y, z = player_pos();
            if (x ~= nil) then mogsort.latch.seen(now, x, y, z); end
        end
    end

    if (mogsort.runner.running) then
        mogsort.runner.tick();
        return;
    end
    if (mogsort.settings.enabled) then mogsort.sorter.tick(); end
end);

ashita.events.register('command', 'mogsort_command', function (e)
    local args = e.command:args();
    if (#args == 0 or not args[1]:any('/mogsort')) then return; end
    e.blocked = true;

    local sub = (args[2] or ''):lower();
    if (sub == 'all') then
        if (not mogsort.ready) then err('Not ready: unsupported client.'); return; end
        cmd_all((args[3] or ''):lower() == 'preview');
    elseif (sub == 'stop') then
        if (mogsort.ready and mogsort.runner.running) then mogsort.runner.stop('cancelled'); else msg('Nothing is running.'); end
    elseif (sub == 'on' or sub == 'off') then
        mogsort.settings.enabled = (sub == 'on');
        settings.save();
        msg('Auto-sort ' .. (mogsort.settings.enabled and 'enabled.' or 'disabled.'));
    elseif (sub == 'verbose') then
        mogsort.settings.verbose = not mogsort.settings.verbose;
        settings.save();
        msg('Verbose ' .. (mogsort.settings.verbose and 'on.' or 'off.'));
    elseif (sub == 'skip' or sub == 'unskip') then
        local id = core.container_id(args[3]);
        if (id == nil) then
            err('Unknown container. Use one of: safe safe2 storage locker satchel sack case wardrobe wardrobe2-8');
            return;
        end
        local name = core.container_name(id);
        local list = T{};
        for _, v in ipairs(mogsort.settings.skip) do
            if (v ~= name) then list:append(v); end
        end
        if (sub == 'skip') then list:append(name); end
        mogsort.settings.skip = list;
        settings.save();
        msg(('%s will %sbe sorted.'):format(name, sub == 'skip' and 'not ' or ''));
    else
        msg(('Status: %s%s. Skipped: %s'):format(
            mogsort.settings.enabled and 'on' or 'off',
            mogsort.ready and '' or ' (not ready: unsupported client)',
            #mogsort.settings.skip > 0 and table.concat(mogsort.settings.skip, ', ') or 'none'));
        msg('Commands: /mogsort on|off, /mogsort skip|unskip <container>, /mogsort verbose');
        msg('          /mogsort all [preview] (gather duplicate stacks; Mog House / nomad moogle), /mogsort stop');
    end
end);
