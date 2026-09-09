-- bogey_probe.lua - standalone Simurail_PhysicsBogey drive test
-- Usage (on the locomotive computer):  lua bogey_probe.lua
-- Does NOT run the locomotive program; only talks to the bogey peripheral.
-- Purpose: verify whether setMaxStress alone can drive the train (and show
-- current bogey state / occupied signal).

local name, bogey
for _, n in ipairs(peripheral.getNames()) do
    if peripheral.getType(n) == "Simurail_PhysicsBogey" then
        name, bogey = n, peripheral.wrap(n)
        break
    end
end

if not bogey then
    print("ERROR: no Simurail_PhysicsBogey found")
    print("peripherals on this computer:")
    for _, n in ipairs(peripheral.getNames()) do
        print("  " .. n .. "  ->  " .. peripheral.getType(n))
    end
    return
end

print("bogey peripheral: " .. name)
print("  hasTrack          : " .. tostring(bogey.hasTrack()))
print("  controlMode       : " .. tostring(bogey.getControlMode()))
print("  maxStress         : " .. tostring(bogey.getMaxStress()))
print("  stressMultiplier  : " .. tostring(bogey.getStressMultiplier()))
print("  brakeStrength     : " .. tostring(bogey.getBrakeStrength()))
print("  probeDistance     : " .. tostring(bogey.getProbeDistance()) .. "   (0 = probe disabled)")
print("  occupiedSignal(f) : " .. tostring(bogey.getProbeOccupiedSignalDistance(true)))
print("  occupiedSignal(b) : " .. tostring(bogey.getProbeOccupiedSignalDistance(false)))

-- Probe snapshot for the axle the locomotive protects with (front axle).
-- Distances are blocks along the track; -1 means "nothing found in the window".
local function probeAxle(front)
    local tag = front and "front" or "back "
    print("--- probe " .. tag .. " axle ---")
    local function p(label, method, ...)
        local ok, r = pcall(bogey[method], ...)
        if not ok then
            print(string.format("  %-24s: ERR %s", label, tostring(r)))
        elseif type(r) == "table" then
            local parts = {}
            for i = 1, #r do parts[i] = tostring(r[i]) end
            print(string.format("  %-24s: {%s}", label, table.concat(parts, ",")))
        else
            print(string.format("  %-24s: %s", label, tostring(r)))
        end
    end
    p("occupiedSignalDist", "getProbeOccupiedSignalDistance", front)
    p("occupiedSignalNames", "getProbeOccupiedSignalNames", front)
    p("occupiedSignalAligned", "getProbeOccupiedSignalAligned", front)
    p("occupiedSignalForced", "getProbeOccupiedSignalForced", front)
    p("signalDistance", "getProbeSignalDistance", front)
    p("signalNames", "getProbeSignalNames", front)
    p("signalAligned", "getProbeSignalAligned", front)
    p("stationDistance", "getProbeStationDistance", front)
    p("stationName", "getProbeStationName", front)
    p("discontinuityDist", "getProbeDiscontinuityDistance", front)
    p("trackDir", "getTrackDir", front)
end
probeAxle(true)
probeAxle(false)

-- Which axle points the way the train travels: compare the two trackDir
-- vectors with the direction the train is about to move. The axle whose
-- vector matches that direction is the one redProbeFront must select.
print()
print("trackDir above = the direction each axle probes toward.")
print("Pick the axle whose trackDir matches the travel direction and set")
print("redProbeFront accordingly (true = front axle, false = back axle).")

-- Read all probe methods available (guard against missing methods)
local function probePrint(method, ...)
    if bogey[method] then
        local ok, r = pcall(bogey[method], ...)
        print(string.format("  %-38s: %s", method, ok and tostring(r) or ("ERR " .. tostring(r))))
    else
        print(string.format("  %-38s: <not registered>", method))
    end
end
probePrint("getProbeStationDistance", true)
probePrint("getProbeSignalDistance", true)
probePrint("getProbeDiscontinuityDistance", true)

print()
print("--- DRIVE TEST: setMaxStress(64) for 3s ---")
local ok, err = pcall(function() bogey.setMaxStress(64) end)
print("set(64) ok = " .. tostring(ok) .. (ok and "" or (" err = " .. tostring(err))))
print("after set: maxStress = " .. tostring(bogey.getMaxStress())
    .. ", multiplier = " .. tostring(bogey.getStressMultiplier()))
print(">>> watch the train: it should drive FORWARD now")
os.sleep(3)

print("--- stopping: maxStress to 0 ---")
bogey.setMaxStress(0)
print("done. If the train never moved, note whether the wheel axles spin")
print("(if they spin but no motion -> red light/protection elsewhere is braking)")
