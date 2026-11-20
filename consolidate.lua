--[[
* MogSort - "/mogsort all": gathers stackable items that sit in more than one storage bag into the first bag
*           (in menu order) that holds them. No Ashita calls in this file, so it can be unit tested.
*
* Copyright (c) 2026 MogSort contributors
* Licensed under the GNU General Public License v3.0 or later (see LICENSE).
*
* Server rules this follows (LandSandBoat src/map/packets/c2s/0x029_item_move.cpp):
*   - c2s 0x029 {u32 count @4, u8 from bag @8, u8 to bag @9, u8 from slot @10, u8 to slot @11}.
*   - Moving a WHOLE stack to a slot holding the same item tops that stack up (as much as fits; the rest stays
*     where it was). Moving a whole stack to slot 0x52 puts it in the first free slot of the target bag.
*     Moving part of a stack splits it into a new slot. This module only ever moves whole stacks.
*   - The bags a character may use depend on where it is; a move touching any other bag is dropped by the server.
*     access() mirrors those rules from the client's own flags.
--]]

local consolidate = {};

-- Bags in the order the game's storage menus list them; "first bag" means first in this order.
consolidate.BAG_ORDER = { 1, 9, 2, 4, 5, 6, 7 };   -- Safe, Safe 2, Storage, Locker, Satchel, Sack, Case
consolidate.BAG_NAMES = { [1] = 'Mog Safe', [9] = 'Mog Safe 2', [2] = 'Storage', [4] = 'Mog Locker',
                          [5] = 'Mog Satchel', [6] = 'Mog Sack', [7] = 'Mog Case' };

consolidate.FREE_SLOT    = 0x52;  -- "first free slot" target index
consolidate.MOVE_DELAY   = 0.4;   -- seconds between a confirmed move and the next one
consolidate.MOVE_TIMEOUT = 4.0;   -- seconds to wait for the inventory to show a move before giving up
consolidate.MAX_MOVES    = 600;   -- hard stop (7 bags x 80 slots can't need more than this)
consolidate.NOMAD_RANGE  = 6.0;   -- yalms; the game closes the nomad moogle's menu beyond this
consolidate.NOMAD_WINDOW = 60.0;  -- seconds after the nomad moogle's menu was last seen that the command starts

-- Zones that put the client "in a room" but are not the player's own Mog House.
consolidate.NOT_MOG_HOUSE = { [280] = true, [285] = true };   -- Mog Garden, Feretory

-------------------------------------------------------------------------------------------------------------------
-- Where am I, and which bags may I use here?
-------------------------------------------------------------------------------------------------------------------

---Decides access from the client's flags.
---@param f table { in_room, visiting (owner id or 0), zone, nomad_zone, nomad_talk (bool),
---                 unlocked = { [bag] = bool } (sortcore.unlocked: unlocked / leased, with at least one slot) }
---@return string|nil where  'mog_house' | 'nomad' | nil (not allowed)
---@return table bags        bag ids usable here, in BAG_ORDER
function consolidate.access(f)
    local own_house = f.in_room and (f.visiting == 0) and not consolidate.NOT_MOG_HOUSE[f.zone];
    local where = nil;
    if (own_house) then
        where = 'mog_house';
    elseif (f.nomad_zone and f.nomad_talk) then
        where = 'nomad';
    end
    if (where == nil) then return nil, {}; end

    local bags = {};
    for _, b in ipairs(consolidate.BAG_ORDER) do
        -- Not unlocked (Safe 2 without the 2F, Sack / Satchel not bought, no slots) or no Locker lease: skip it.
        local ok = f.unlocked[b] == true;
        if (b == 2) then ok = ok and where == 'mog_house'; end  -- Storage only in your own Mog House
        if (ok) then bags[#bags + 1] = b; end
    end
    return where, bags;
end

---Remembers the nomad moogle conversation (menu seen focused at a position) and tells whether it still counts.
function consolidate.new_nomad_latch()
    local latch = { t = nil, x = 0, y = 0, z = 0 };

    function latch.seen(now, x, y, z)
        latch.t, latch.x, latch.y, latch.z = now, x, y, z;
    end

    function latch.distance(x, y, z)
        local dx, dy, dz = x - latch.x, y - latch.y, z - latch.z;
        return math.sqrt(dx * dx + dy * dy + dz * dz);
    end

    ---@param fresh boolean require the conversation to be recent (starting a run) or only nearby (during a run)
    function latch.active(now, x, y, z, fresh)
        if (latch.t == nil) then return false; end
        if (fresh and now - latch.t > consolidate.NOMAD_WINDOW) then return false; end
        return latch.distance(x, y, z) <= consolidate.NOMAD_RANGE;
    end

    function latch.clear() latch.t = nil; end
    return latch;
end

-------------------------------------------------------------------------------------------------------------------
-- Planning: one move at a time from the live contents
-------------------------------------------------------------------------------------------------------------------

---A stack the addon may move or top up: real item, not busy (bazaar / equipped / etc. flags), stackable.
local function eligible(it, stack_of)
    return it ~= nil and it.id ~= 0 and it.id ~= 0xFFFF and it.count > 0 and (it.flags or 0) == 0
        and (stack_of(it.id) or 1) > 1;
end

---Finds the next move.
---@param bags table array in BAG_ORDER of { bag = id, capacity = n, items = { [slot] = { id, count, flags } } }
---@param stack_of function(item id) -> stack size
---@return table|nil move  { from, from_slot, to, to_slot, count, id }
---@return table blocked   item id -> target bag that is full (only filled when nothing else can move)
function consolidate.next_move(bags, stack_of)
    -- First bag (in order) that holds each item.
    local first = {};
    for bi, b in ipairs(bags) do
        for slot, it in pairs(b.items) do
            if (it.id ~= 0 and first[it.id] == nil) then first[it.id] = bi; end
        end
    end
    local ids = {};
    for id in pairs(first) do ids[#ids + 1] = id; end
    table.sort(ids);   -- deterministic order

    local blocked = {};
    for _, id in ipairs(ids) do
        local ti = first[id];
        local target = bags[ti];
        if ((stack_of(id) or 1) > 1) then
            -- Partial stacks of this item in the target bag (lowest slot first), and its free slots.
            local partial, used = nil, 0;
            local slots = {};
            for slot in pairs(target.items) do slots[#slots + 1] = slot; end
            table.sort(slots);
            for _, slot in ipairs(slots) do
                local it = target.items[slot];
                if (it.id ~= 0) then used = used + 1; end
                if (partial == nil and it.id == id and eligible(it, stack_of) and it.count < stack_of(id)) then
                    partial = slot;
                end
            end
            local free = target.capacity - used;

            -- Every eligible stack of the item in a later bag moves to the target.
            for bi = ti + 1, #bags do
                local src = bags[bi];
                local sslots = {};
                for slot, it in pairs(src.items) do
                    if (it.id == id and eligible(it, stack_of)) then sslots[#sslots + 1] = slot; end
                end
                table.sort(sslots);
                local slot = sslots[1];
                if (slot ~= nil) then
                    local it = src.items[slot];
                    if (partial ~= nil) then
                        return { from = src.bag, from_slot = slot, to = target.bag, to_slot = partial, count = it.count, id = id };
                    elseif (free > 0) then
                        return { from = src.bag, from_slot = slot, to = target.bag, to_slot = consolidate.FREE_SLOT, count = it.count, id = id };
                    else
                        blocked[id] = target.bag;
                        break;
                    end
                end
            end
        end
    end
    return nil, blocked;
end

---Applies a move to a bags table the way the server does (used for previews and tests).
function consolidate.apply(bags, m, stack_of)
    local src, dst;
    for _, b in ipairs(bags) do
        if (b.bag == m.from) then src = b; end
        if (b.bag == m.to) then dst = b; end
    end
    local it = src.items[m.from_slot];
    if (m.to_slot ~= consolidate.FREE_SLOT) then
        local p = dst.items[m.to_slot];
        local n = math.min(stack_of(it.id) - p.count, it.count);
        p.count = p.count + n;
        it.count = it.count - n;
        if (it.count == 0) then src.items[m.from_slot] = nil; end
    else
        for s = 1, dst.capacity do
            if (dst.items[s] == nil) then
                dst.items[s] = { id = it.id, count = it.count, flags = 0 };
                src.items[m.from_slot] = nil;
                return;
            end
        end
        error('apply: no free slot');
    end
end

---Deep copy of a bags table.
function consolidate.copy(bags)
    local out = {};
    for i, b in ipairs(bags) do
        local items = {};
        for s, it in pairs(b.items) do items[s] = { id = it.id, count = it.count, flags = it.flags }; end
        out[i] = { bag = b.bag, capacity = b.capacity, items = items };
    end
    return out;
end

---Simulates a whole run without touching the game: returns the list of moves and the blocked items.
function consolidate.plan(bags, stack_of)
    local sim = consolidate.copy(bags);
    local moves = {};
    while (#moves < consolidate.MAX_MOVES) do
        local m, blocked = consolidate.next_move(sim, stack_of);
        if (m == nil) then return moves, blocked; end
        moves[#moves + 1] = m;
        consolidate.apply(sim, m, stack_of);
    end
    return moves, {};
end

-------------------------------------------------------------------------------------------------------------------
-- Runner: sends one move, waits until the inventory shows it, pauses, repeats
-------------------------------------------------------------------------------------------------------------------

---@param deps table {
---   now()                  -> seconds,
---   read_bags(list)        -> bags table (live) for the given bag ids,
---   stack_of(id)           -> stack size,
---   send_move(m)           -> sends c2s 0x029,
---   still_allowed()        -> false aborts (left the Mog House / walked away from the nomad / zoned),
---   finished(summary)      -> called once with { moves, items, blocked = {id -> bag}, touched = {bag -> true},
---                             aborted = reason or nil } }
function consolidate.new_runner(deps)
    local r = { running = false };

    local function finish(reason, blocked)
        r.running = false;
        deps.finished({ moves = r.moves, items = r.items, blocked = blocked or {}, touched = r.touched, aborted = reason });
    end

    function r.start(bags_list)
        r.running, r.bags_list = true, bags_list;
        r.moves, r.items, r.touched = 0, 0, {};
        r.pending, r.next_at = nil, deps.now();
    end

    function r.stop(reason)
        if (r.running) then finish(reason or 'stopped'); end
    end

    ---Snapshot of the source slot (item id and count) so we can tell when the server applied the move.
    local function slot_state(bags, bag, slot)
        for _, b in ipairs(bags) do
            if (b.bag == bag) then
                local it = b.items[slot];
                if (it == nil or it.id == 0) then return 0, 0; end
                return it.id, it.count;
            end
        end
        return -1, 0;
    end

    function r.tick()
        if (not r.running) then return; end
        if (not deps.still_allowed()) then return finish('you left the Mog House / nomad moogle'); end
        local now = deps.now();
        local bags = deps.read_bags(r.bags_list);

        if (r.pending ~= nil) then
            local p = r.pending;
            local id, count = slot_state(bags, p.m.from, p.m.from_slot);
            if (id ~= p.id or count ~= p.count) then
                -- Applied: count what actually left the slot (whole stack, or only what fit into the partial stack).
                r.items = r.items + (id == p.id and (p.count - count) or p.count);
                r.moves = r.moves + 1;
                r.touched[p.m.to] = true;
                r.pending = nil;
                r.next_at = now + consolidate.MOVE_DELAY;
            elseif (now - p.sent > consolidate.MOVE_TIMEOUT) then
                return finish('the server did not confirm a move');
            end
            return;
        end

        if (now < r.next_at) then return; end
        if (r.moves >= consolidate.MAX_MOVES) then return finish('too many moves'); end

        local m, blocked = consolidate.next_move(bags, deps.stack_of);
        if (m == nil) then return finish(nil, blocked); end
        local id, count = slot_state(bags, m.from, m.from_slot);
        r.pending = { m = m, sent = now, id = id, count = count };
        deps.send_move(m);
    end

    return r;
end

---Builds the 12-byte c2s 0x029 packet (byte table, header included) for a move.
function consolidate.packet(m)
    local c = m.count;
    return { 0x29, 0x06, 0x00, 0x00,                        -- id, size (12 bytes / 2), sequence (filled by client)
             c % 256, math.floor(c / 256) % 256, 0, 0,      -- count (u32)
             m.from, m.to, m.from_slot, m.to_slot };
end

return consolidate;
