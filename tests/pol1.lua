--[[
* Test helper (Lua 5.3, e.g. texlua): reads FFXiMain.dll and returns its unpacked .text section.
* The client ships .text compressed (LZSS stream in section POL1, unpacked by the loader at start-up).
* Format (documented in lenonk/vana-client MODLOG, MIT): flag byte read MSB first, 1 = literal byte,
* 0 = two bytes b0 b1: distance ((b0 << 8) | b1) & 0xFFF back into the output (0 ends), length (b0 >> 4) + 3.
* Only READS the DLL.
--]]
local pol1 = {};

local function sections(pe)
    local e_lfanew = string.unpack('<I4', pe, 0x3C + 1);
    local nsec = string.unpack('<I2', pe, e_lfanew + 6 + 1);
    local optsz = string.unpack('<I2', pe, e_lfanew + 20 + 1);
    local base = string.unpack('<I4', pe, e_lfanew + 24 + 28 + 1);
    local t, off = {}, e_lfanew + 24 + optsz;
    for i = 0, nsec - 1 do
        local o = off + i * 40;
        local name = pe:sub(o + 1, o + 8):gsub('%z+$', '');
        local vsize, va, rawsize, rawptr = string.unpack('<I4I4I4I4', pe, o + 8 + 1);
        t[name] = { va = va, vsize = vsize, rawsize = rawsize, rawptr = rawptr };
    end
    return t, base;
end

---@return string text, number text_va (absolute)
function pol1.unpack_text(path)
    local f = assert(io.open(path, 'rb')); local pe = f:read('a'); f:close();
    local s, base = sections(pe);
    local src = pe:sub(s.POL1.rawptr + 1, s.POL1.rawptr + s.POL1.rawsize);
    local out, n, i = {}, 0, 1;
    while i <= #src do
        local flags = src:byte(i); i = i + 1;
        for bit = 7, 0, -1 do
            if (flags & (1 << bit)) ~= 0 then
                n = n + 1; out[n] = src:byte(i); i = i + 1;
            else
                local b0, b1 = src:byte(i, i + 1); i = i + 2;
                local d = ((b0 << 8) | b1) & 0xFFF;
                if d == 0 then goto done; end
                for _ = 1, (b0 >> 4) + 3 do n = n + 1; out[n] = out[n - d]; end
            end
        end
    end
    ::done::
    local chunks = {};
    for k = 1, n, 4096 do chunks[#chunks + 1] = string.char(table.unpack(out, k, math.min(k + 4095, n))); end
    local text = table.concat(chunks);
    assert(#text == s['.text'].vsize, ('unpacked size %x ~= .text size %x'):format(#text, s['.text'].vsize));
    return text, base + s['.text'].va;
end

return pol1;
