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
print("  probeDistance     : " .. tostring(bogey.getProbeDistance()))
print("  occupiedSignal(f) : " .. tostring(bogey.getProbeOccupiedSignalDistance(true)))
print("  occupiedSignal(b) : " .. tostring(bogey.getProbeOccupiedSignalDistance(false)))

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
