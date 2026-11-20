--[[
* MogSort - sorter logic (sortcore.lua) (no Ashita calls in this file, so it can be unit tested)
*
* Copyright (c) 2026 MogSort contributors
* Licensed under the GNU General Public License v3.0 or later (see LICENSE).
*
* How the game sorts (found in FFXiMain.dll, see README "How it works"):
*   - The order you see in a container is a client-side "view". The menu's Sort > Auto rebuilds that view
*     (by the item record's sort key, then item id, or "group identical items" when Sort Type 2 is set) and
*     then sends c2s 0x03A {container}, on which the server merges partial stacks.
*   - FFXiMain has a small cdecl helper, sort_container(container), that does exactly those two steps for one
*     container. This addon calls that helper; it never builds packets or edits the view itself.
*
* When it sorts: once when a storage view opens on a container (and when Switch shows another one), and again
* after you move items INTO a storage container from another container (c2s 0x029 confirmed by s2c 0x01F/0x020).
*
* Server safety (LandSandBoat 0x03a_item_stack.cpp): a 0x03A for a container sent within 1 s of the last
* accepted one is dropped, and the 4th such drop logs the character out (map.LIGHTLUGGAGE_BLOCK). This module
* tracks every outgoing 0x03A (ours and the game's own) and never sorts a container sooner than MIN_GAP after one.
--]]

local core = {};

-- Seconds to keep between two 0x03A packets for one container. The server's window is 1 s; 2 s leaves room
-- for clock jitter and for the game menu's own double send.
core.MIN_GAP = 2.0;

-- Re-sort after a move: wait this long after the last item update for the container, so a burst of moves (or a
-- stack split into several packets) gives one sort, and the client has added the new slot to its view first.
core.SETTLE = 0.5;

-- A move the server never confirms (destination full, item busy...) is forgotten after this many seconds.
core.MOVE_TIMEOUT = 5.0;

-- Container ids (FFXI bag ids) this addon may sort, with display names. 0 (Inventory), 3 (Temporary) and
-- 17 (Recycle Bin) are left alone: the inventory has its own Gameplay > Auto-sort option, and the game's helper
-- does not handle the other two.
core.CONTAINERS = {
    [1]  = 'safe',      [2]  = 'storage',   [4]  = 'locker',    [5]  = 'satchel',
    [6]  = 'sack',      [7]  = 'case',      [8]  = 'wardrobe',  [9]  = 'safe2',
    [10] = 'wardrobe2', [11] = 'wardrobe3', [12] = 'wardrobe4', [13] = 'wardrobe5',
    [14] = 'wardrobe6', [15] = 'wardrobe7', [16] = 'wardrobe8',
};

-- Focused-menu names (the 8 characters after "menu    ") that belong to an open storage view. While one of
-- these has focus the view is still open, so a container is not re-sorted (that would undo a Manual sort).
-- Any other focused menu (or none) ends the session, so the next open sorts again.
core.STORAGE_MENUS = {
    ['bank']     = true,   -- the storage container list (left side)
    ['inventor'] = true,   -- the inventory list (right side)
    ['itmsortw'] = true,   -- Sort window (Auto / Manual / Switch)
    ['itmstora'] = true,   -- Switch: container picker
    ['sortyn']   = true,   -- "Sort items?" yes/no
    ['itemctrl'] = true,   -- quantity picker when moving a stack
};

---Slot count of a container from the client's raw size byte (s2c 0x01C ItemNum; the server sends size + 1).
function core.capacity(raw, c)
    local n = (raw.item_num[c] or 0) - 1;
    return n > 0 and n or 0;
end

---True when the player has unlocked the container (or, for the Mog Locker, holds a lease valid where they are).
---Mirrors the client's own storage menus (FFXiMain FUN_10145ca0 / FUN_101f3c60):
---  Safe 2: Mog House 2F flag; Locker: ItemNum2[Locker] > 0 (the server sends it only with a valid lease);
---  Satchel: ItemNum >= SATCHEL_MIN (30 in the client); every container: at least one slot.
---@param raw table { item_num = { [c] = raw ItemNum }, locker_lease = number, safe2 = bool, satchel_min = number }
function core.unlocked(raw, c)
    if (core.capacity(raw, c) == 0) then return false; end
    if (c == 9) then return raw.safe2 == true; end
    if (c == 4) then return (raw.locker_lease or 0) > 0; end
    if (c == 5) then return (raw.item_num[5] or 0) >= (raw.satchel_min or 30); end
    return true;
end

---Returns the container name for an id, or nil when this addon does not handle it.
function core.container_name(id)
    return core.CONTAINERS[id];
end

---Returns the container id for a name or numeric string ("safe2", "9"), or nil.
function core.container_id(name)
    if (name == nil) then return nil; end
    local n = tonumber(name);
    if (n ~= nil) then
        return core.CONTAINERS[n] ~= nil and n or nil;
    end
    name = name:lower();
    for id, v in pairs(core.CONTAINERS) do
        if (v == name) then return id; end
    end
    return nil;
end

---Strips a raw 16-byte menu id ("menu    bank    ", maybe NUL padded) to its short name ("bank").
function core.short_menu_name(raw)
    if (raw == nil) then return nil; end
    raw = raw:gsub('%z.*$', '');               -- cut at the first NUL
    if (raw:sub(1, 8) ~= 'menu    ') then return nil; end
    local s = raw:sub(9):gsub('%s+$', '');     -- drop the prefix and trailing spaces
    return s;
end

---Builds the list-object -> container map from the game's sort helper.
---The helper is a jump table over container ids; each case loads that container's list object from a global
---table (mov ecx, [table_slot]) and pushes the container id. Reading it at runtime means the mapping follows the
---client rather than a hard-coded order (Safe 2 is NOT next to Safe in that table).
---@param read_u32 function(addr) -> number
---@param read_u8 function(addr) -> number
---@param jump_table number address of the helper's jump table
---@return table|nil map  slot address -> container id, nil if the code doesn't look as expected
function core.build_slot_map(read_u32, read_u8, jump_table)
    local map = {};
    for c = 0, 16 do
        local case = read_u32(jump_table + 4 * c);
        -- Expected case code: 8B 0D <slot32> 6A <x> 6A 01 6A 00 E8 ...  (mov ecx,[slot]; push x; push 1; push 0)
        if (case == 0 or read_u8(case) ~= 0x8B or read_u8(case + 1) ~= 0x0D or read_u8(case + 6) ~= 0x6A) then
            return nil;
        end
        local slot = read_u32(case + 2);
        local pushed = read_u8(case + 7);
        if (pushed ~= c) then return nil; end   -- the pushed container id must match the case index
        map[slot] = c;
    end
    return map;
end

---Creates a sorter state machine.
---@param deps table {
---   now()            -> seconds (monotonic),
---   menu_name()      -> short focused menu name or nil,
---   bank_list()      -> list object currently shown by the storage view (bank +0x5C) or nil,
---   list_of_slot(s)  -> list object stored in a slot of the game's table,
---   slots            -> map slot address -> container id (from build_slot_map),
---   sort(container)  -> calls the game's helper,
---   is_enabled(c)    -> bool,
---   log(msg)         -> optional debug output }
function core.new(deps)
    local self = {
        deps        = deps,
        session     = nil,   -- set of containers already sorted since the storage view opened
        last_03a    = {},    -- container -> time of the last 0x03A seen leaving the client
        moves       = {},    -- container -> time we asked the server to move an item into it (c2s 0x029)
        dirty       = {},    -- container -> time of the last confirmed item update after such a move
        paused      = false, -- true while "/mogsort all" moves items: a sort now would shift slots under it
    };

    ---Pauses / resumes all sorting (moves seen while paused are ignored).
    function self.set_paused(p)
        self.paused = p and true or false;
    end

    ---Asks for a re-sort of a container once it has been quiet for SETTLE (used after "/mogsort all").
    function self.queue_sort(c)
        if (core.CONTAINERS[c] ~= nil) then
            self.moves[c] = deps.now();
            self.dirty[c] = deps.now();
        end
    end

    ---Records an outgoing item move (c2s 0x029). Only moves between two different containers count: Manual sort
    ---inside one container also sends 0x029 (same source and target), and re-sorting would undo it.
    function self.on_move(from, to)
        if (not self.paused and from ~= to and core.CONTAINERS[to] ~= nil) then
            self.moves[to] = deps.now();
        end
    end

    ---Records an incoming item update (s2c 0x01F / 0x020) for a container. It marks the container for a re-sort
    ---only while a move into it is pending, so zone-in resends and stack merges don't trigger sorts on their own.
    function self.on_item_update(bag)
        local t = self.moves[bag];
        if (t ~= nil and deps.now() - t <= core.MOVE_TIMEOUT) then
            self.dirty[bag] = deps.now();
        end
    end

    ---Re-sorts at most one container that received items and has been quiet for SETTLE. Returns it or nil.
    function self.tick_moves()
        local now = deps.now();
        for c, t in pairs(self.moves) do
            if (self.dirty[c] == nil and now - t > core.MOVE_TIMEOUT) then
                self.moves[c] = nil;   -- never confirmed: drop it
            end
        end
        for c, t in pairs(self.dirty) do
            if (now - t >= core.SETTLE and self.gap_ok(c)) then
                self.dirty[c] = nil;
                self.moves[c] = nil;
                if (deps.is_enabled(c)) then
                    self.last_03a[c] = now;
                    deps.sort(c);
                    if (deps.log) then deps.log(('re-sorted %s after a move'):format(core.CONTAINERS[c])); end
                    return c;   -- one sort per tick keeps the work per frame tiny
                end
            end
        end
        return nil;
    end

    ---Records an outgoing 0x03A (call from packet_out for every 0x03A, including the game's own).
    function self.on_sort_packet(container)
        self.last_03a[container] = deps.now();
    end

    ---Returns the container shown on the storage side, by matching its list object against the game's table.
    function self.current_container()
        local list = deps.bank_list();
        if (list == nil or list == 0) then return nil; end
        for slot, c in pairs(deps.slots) do
            if (deps.list_of_slot(slot) == list) then return c; end
        end
        return nil;
    end

    ---True when a 0x03A for this container now would be accepted by the server with room to spare.
    function self.gap_ok(c)
        local t = self.last_03a[c];
        return t == nil or (deps.now() - t) >= core.MIN_GAP;
    end

    ---One poll step. Returns the container sorted this step, or nil.
    function self.tick()
        if (self.paused) then return nil; end
        local moved = self.tick_moves();
        if (moved ~= nil) then return moved; end

        local name = deps.menu_name();

        if (name ~= 'bank') then
            -- Leaving the storage view (any menu outside it, or no menu) ends the session.
            if (name == nil or not core.STORAGE_MENUS[name]) then
                self.session = nil;
            end
            return nil;
        end

        self.session = self.session or {};
        local c = self.current_container();
        if (c == nil or core.CONTAINERS[c] == nil or self.session[c] or not deps.is_enabled(c)) then
            return nil;
        end
        if (not self.gap_ok(c)) then
            return nil;   -- wait: a 0x03A for this container went out moments ago; try again next tick
        end

        self.session[c] = true;
        self.last_03a[c] = deps.now();   -- packet_out will refresh this too
        deps.sort(c);
        if (deps.log) then deps.log(('sorted %s'):format(core.CONTAINERS[c])); end
        return c;
    end

    ---Forget the current view and pending moves (zone change: every menu closes, the server resends all items).
    function self.reset()
        self.session = nil;
        self.moves   = {};
        self.dirty   = {};
    end

    return self;
end

return core;
