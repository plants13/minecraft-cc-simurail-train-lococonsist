-- depot_probe.lua - print item names in the "right" inventory peripheral once
-- Usage (on the computer next to the depot):  lua depot_probe.lua
-- The depot exposes a CC inventory peripheral; we read it and exit.

local inv = peripheral.wrap("right")
if not inv then
    print("ERROR: no peripheral on the right side")
    print("peripherals found:")
    for _, n in ipairs(peripheral.getNames()) do
        print("  " .. n .. "  ->  " .. peripheral.getType(n))
    end
    return
end

print("peripheral type: " .. (peripheral.getType("right") or "?"))

-- list() returns { [slot] = { name = "mod:item", count = n, ... }, ... }
local ok, list = pcall(function() return inv.list() end)
if not ok then
    print("list() failed: " .. tostring(list))
    return
end

if not list or next(list) == nil then
    print("empty")
    return
end

for slot, item in pairs(list) do
    if item and type(item) == "table" then
        local name = item.name or "?"
        local count = item.count or 0
        -- getItemDetail adds richer info (displayName etc.) per slot
        local display = ""
        local ok2, detail = pcall(function() return inv.getItemDetail(slot) end)
        if ok2 and detail and detail.displayName then
            display = detail.displayName
        end
        if display ~= "" then
            print(string.format("slot %d: %s x%d  (%s)", slot, name, count, display))
        else
            print(string.format("slot %d: %s x%d", slot, name, count))
        end
    end
end
print("done")
