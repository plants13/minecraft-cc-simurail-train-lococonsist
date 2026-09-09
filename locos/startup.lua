-- startup.lua
-- Combined consist program: master and slave modes in one script.
--
-- The direction lever (analog input on SIDE_REVERSE) selects the mode:
--   0-4   : forward  -> run as MASTER
--   5-10  : neutral  -> run as SLAVE
--   11-15 : reverse  -> run as MASTER
--
-- Network safety: exactly ONE vehicle may be in master mode. If zero or
-- more than one master is detected on the consist protocol, every vehicle
-- cuts traction and applies emergency brake (EB).

-- ============================================================
-- 0. Load config
-- ============================================================
local cfg = dofile("config_locomodel.lua")

local MAX_SPEED       = cfg.maxSpeed
local SIDE_SETSPEED   = cfg.sideSetSpeed
local SIDE_REVERSE    = cfg.sideReverse
local SIDE_MONITOR    = cfg.sideMonitor
local SIDE_MODEM      = cfg.sideModem or "front"       -- wireless modem side (rednet)
local VISUAL_MAX      = cfg.visualMaxSpeed or 10.0     -- visual driving speed cap (m/s, 36 km/h)
local CALIB_ACCEL_DUR    = cfg.calibAccelDur     or 3.0   -- s: accel measurement window
local CALIB_BRAKE_STR    = math.max(0.05, math.min(1, cfg.calibBrakeStrength or 0.5))  -- brake run strength
local CALIB_PLATEAU_TIME = cfg.calibPlateauTime  or 2.0   -- s without a speed gain -> top speed
local CALIB_PLATEAU_EPS  = cfg.calibPlateauEps   or 0.1   -- m/s: a gain above this counts as progress
local CALIB_MIN_TOP      = cfg.calibMinTopSpeed  or 5.0   -- m/s: below this the run has failed
local CALIB_START_CLEAR  = cfg.calibStartClearance or 64.0 -- blocks: clear track needed to start
local CALIB_RUN_TIMEOUT  = cfg.calibRunTimeout   or 120.0 -- s: safety net for the climb
local CALIB_BRAKE_TIMEOUT = cfg.calibBrakeTimeout or 60.0 -- s: floor for the brake run (scaled by top speed)
local CALIB_BRAKE_MIN_DECEL = 0.2  -- m/s^2: slowest plausible decel, used to scale the brake timeout
local CALIB_SETTLE       = cfg.calibSettle       or 0.5   -- s: output settle before sampling
local CALIB_STOP         = 0.3   -- m/s: treated as stopped
local CALIB_FILE         = "calib.json"

-- ============================================================
-- 0b. Simurail physics bogey peripheral (drive/brake/direction via CC)
-- ============================================================
-- Drive, brake and direction are sent to every reachable
-- Simurail_PhysicsBogey peripheral (attached directly or on a wired/wireless
-- network). This is the ONLY output channel: there is no redstone fallback.
-- The red signal ahead comes from the bogey probe (section 0c), not from a
-- redstone input.
local DRIVE_STRESS_MAX = cfg.bogeyDriveMax or 128   -- drive stress range +/-128
local bogeys        = {}     -- all reachable Simurail_PhysicsBogey peripherals
local bCallWarned   = false
local lastSentStress = {}   -- per-bogey: last SIGNED drive stress sent (change-only)
local lastSentBrake  = {}   -- per-bogey: last brake strength sent (change-only)

for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "Simurail_PhysicsBogey" then
        local p = peripheral.wrap(name)
        bogeys[#bogeys + 1] = p
        -- Drive stress is controlled via setMaxStress (+/-128), which
        -- directly reflects the kinetic stress draw. Lock the stress
        -- multiplier at 1 so drive stress == |maxStress| exactly: a
        -- leftover multiplier override or a STRENGTH control-mode redstone
        -- input would otherwise scale it behind our back.
        pcall(p.setStressMultiplierOverride, 1)
    end
end
if #bogeys > 0 then
    print("Bogey peripherals found: " .. #bogeys)
else
    print("ERROR: no Simurail_PhysicsBogey peripheral - this vehicle cannot drive or brake")
    print("       (check the wired network / that the bogey block is loaded)")
end

-- ============================================================
-- 0c. Red-signal protection source (bogey probe, fixed axle)
-- ============================================================
-- The Simurail bogey probe walks the track graph ahead of an axle and caches
-- the nearest signal boundary that is red for us (forced red, or its block
-- occupied by a consist group other than ours). getProbe* returns the last
-- scan, so:
--   * the probe window MUST be > 0 - the mod default is 0 (disabled), which
--     is why an earlier attempt at using the probe saw nothing; we force the
--     configured window onto every bogey at startup,
--   * data refreshes on the server every bogeyProbeInterval ticks
--     (default 5 ticks = 0.25 s, so ~14 blocks of travel at 50 m/s).
-- Only the FIRST occupied boundary in the window is reported, and a boundary
-- whose signal faces the other way is ignored (we cannot see past it).
--
-- Protection rule: NO approach braking. The train drives normally until the
-- red is inside RED_EB_DIST blocks, which means the axle has effectively
-- reached the signal -> EB latch.
local RED_PROBE_FRONT = cfg.redProbeFront ~= false   -- true/nil = front axle (default), false = back
local RED_WINDOW      = cfg.redProbeWindow or 128.0  -- blocks
local RED_EB_DIST     = cfg.redEbDistance or 4.0     -- blocks: trip inside this

-- Force the scan window on every bogey (0 = probe disabled in the mod).
for _, p in ipairs(bogeys) do
    local ok, cur = pcall(p.getProbeDistance)
    if not ok or type(cur) ~= "number" or cur < RED_WINDOW then
        local ok2, err = pcall(p.setProbeDistance, RED_WINDOW)
        if not ok2 then
            print("WARN: cannot set probe distance on a bogey: " .. tostring(err))
        end
    end
end

-- Distance (blocks) to the nearest red-for-us signal ahead, or nil if clear.
-- Fixed axle per config: each axle looks out of its own end of the bogey.
-- Only signals inside RED_WINDOW count, so a bogey left with a longer scan
-- range does not report a red that is far away.
local function redSignalAhead()
    local best = nil
    for _, p in ipairs(bogeys) do
        local ok, d = pcall(p.getProbeOccupiedSignalDistance, RED_PROBE_FRONT)
        if ok and type(d) == "number" and d >= 0 and d <= RED_WINDOW then
            local ok2, aligned = pcall(p.getProbeOccupiedSignalAligned, RED_PROBE_FRONT)
            if ok2 and aligned then
                if best == nil or d < best then best = d end
            end
        end
    end
    return best
end

-- ============================================================
-- 0d. Performance curve from calib.json (automatic control / LKJ input)
-- ============================================================
-- The calibration run fits two straight lines in speed v (m/s):
--   accel: a(v) = a0 + a1 * v   at full traction (traction fades as v rises,
--                                reaching 0 at the bogey's target speed)
--   brake: d(v) = d0 + d1 * v   deceleration at FULL brake strength
-- Both come from least-squares fits over per-interval dv/dt samples, so a
-- speed-dependent rate is captured instead of a single average. The brake run
-- is measured at calibBrakeStrength and normalised to full brake (brake force
-- is linear in brakeStrength in the bogey physics).
-- Integrate them for acceleration time and braking distance:
--   t = integral dv / a(v)          s = integral v / d(v) dv
-- This is what a future LKJ target-speed/braking-curve controller needs.
local perf = { accel = nil, brake = nil, top = nil, savedAt = nil }

local function loadPerf()
    if not fs.exists(CALIB_FILE) then return false end
    local ok, data = pcall(function()
        local f = fs.open(CALIB_FILE, "r")
        local text = f.readAll()
        f.close()
        return textutils.unserializeJSON(text)
    end)
    if not ok or type(data) ~= "table" then return false end
    local acc, brk = data.accel, data.brake
    if type(acc) == "table" and type(acc.a0) == "number" then
        perf.accel = { a0 = acc.a0, a1 = acc.a1 or 0, vmax = acc.vmax, rms = acc.rms, r2 = acc.r2 }
    elseif type(acc) == "table" and type(acc.mps2) == "number" then
        perf.accel = { a0 = acc.mps2, a1 = 0 }
    end
    if type(brk) == "table" then
        if type(brk.d0) == "number" then
            perf.brake = { d0 = brk.d0, d1 = brk.d1 or 0, rms = brk.rms, r2 = brk.r2 }
        elseif type(brk.mps2Full) == "number" then
            perf.brake = { d0 = brk.mps2Full, d1 = 0 }
        elseif type(brk.mps2) == "number" and type(brk.strength) == "number" and brk.strength > 0 then
            perf.brake = { d0 = brk.mps2 / brk.strength, d1 = 0 }
        elseif type(brk.mps2) == "number" then
            perf.brake = { d0 = brk.mps2, d1 = 0 }
        end
    end
    perf.top = type(data.topMps) == "number" and data.topMps or nil
    perf.savedAt = data.savedAt
    return perf.accel ~= nil or perf.brake ~= nil
end

-- Acceleration available at v (m/s) at full traction, or nil if unknown.
local function accelAt(v)
    if not perf.accel then return nil end
    return math.max(0, perf.accel.a0 + perf.accel.a1 * v)
end

-- Deceleration at v (m/s) for a brake strength (default 1 = full brake).
local function decelAt(v, strength)
    if not perf.brake then return nil end
    return math.max(0, (perf.brake.d0 + perf.brake.d1 * v) * (strength or 1))
end

-- Track distance (blocks) to slow from v0 to v1, integrating ds = v/d(v) dv
-- with the trapezoid rule. nil = no curve, or the deceleration vanishes in the
-- interval (the train could not stop).
local function brakeDistance(v0, v1, strength)
    if not perf.brake then return nil end
    if v0 <= v1 then return 0 end
    local steps = 64
    local dv = (v0 - v1) / steps
    local s = 0
    for i = 0, steps - 1 do
        local va = v1 + i * dv
        local vb = va + dv
        local da, db = decelAt(va, strength), decelAt(vb, strength)
        if da <= 0.01 or db <= 0.01 then return nil end
        s = s + dv * (va / da + vb / db) / 2
    end
    return s
end

-- Time (s) to accelerate from v0 to v1 at full traction, integrating
-- dt = dv / a(v). nil = no curve, or the acceleration vanishes in the interval.
local function accelTime(v0, v1)
    if not perf.accel then return nil end
    if v1 <= v0 then return 0 end
    local steps = 64
    local dv = (v1 - v0) / steps
    local t = 0
    for i = 0, steps - 1 do
        local va = v0 + i * dv
        local vb = va + dv
        local aa, ab = accelAt(va), accelAt(vb)
        if aa <= 0.01 or ab <= 0.01 then return nil end
        t = t + dv * (1 / aa + 1 / ab) / 2
    end
    return t
end

local function printPerf()
    if not perf.accel and not perf.brake then
        print("Performance curve: none - run Calibrate")
        return
    end
    local parts = {}
    if perf.accel then
        local s = string.format("accel %.3f%+.4f*v m/s^2", perf.accel.a0, perf.accel.a1)
        local v0 = perf.accel.vmax
        if not (type(v0) == "number" and v0 > 0) and perf.accel.a1 < 0 and perf.accel.a0 > 0 then
            v0 = -perf.accel.a0 / perf.accel.a1
        end
        if type(v0) == "number" and v0 > 0 then
            s = s .. string.format(" (zero at %.0f km/h)", v0 * 3.6)
        end
        if type(perf.accel.r2) == "number" then
            s = s .. string.format(", r2 %.3f", perf.accel.r2)
        end
        parts[#parts + 1] = s
    end
    if perf.brake then
        local s = string.format("brake(full) %.3f%+.4f*v m/s^2", perf.brake.d0, perf.brake.d1)
        if type(perf.brake.r2) == "number" then
            s = s .. string.format(", r2 %.3f", perf.brake.r2)
        end
        parts[#parts + 1] = s
    end
    if perf.top then parts[#parts + 1] = string.format("top %.0f km/h", perf.top * 3.6) end
    print("Performance curve: " .. table.concat(parts, " | "))
    if perf.accel and perf.top then
        local t = accelTime(0, perf.top)
        if t then print(string.format("  full traction 0->top: %.0f s", t)) end
        if type(perf.accel.vmax) == "number" and perf.accel.vmax > 0
            and perf.top > 0 and math.abs(perf.accel.vmax - perf.top) / perf.top > 0.15 then
            print(string.format("  NOTE: curve reaches zero at %.0f km/h but the run topped out at %.0f km/h",
                perf.accel.vmax * 3.6, perf.top * 3.6))
        end
    end
    if perf.brake and perf.top then
        local d = brakeDistance(perf.top, 0, 1)
        if d then print(string.format("  full brake top->0: %.0f blocks", d)) end
    end
end

loadPerf()
printPerf()

-- Call one bogey peripheral method; returns ok. There is no fallback channel
-- any more, so a failing call simply means the value was not applied (the
-- failure is reported once on the console).
local function bCallOne(p, method, ...)
    if p and p[method] then
        local ok, r1 = pcall(p[method], ...)
        if not ok and not bCallWarned then
            bCallWarned = true
            print("BOGEY CALL FAILED: " .. tostring(r1) .. " (reported once)")
        end
        return ok
    end
    return false
end

local mu = {}
local muOK, muCfg = pcall(dofile, "mu_config.lua")
if muOK and type(muCfg) == "table" then
    mu = muCfg
end
local MU_PROTOCOL = mu.protocol or "loco-mu"
local MU_TTL      = 2.5   -- s: a sender's status expires after this long
local MU_CTRL_TTL = 1.5   -- s: slave applies EB if no fresh master control

local locoName = os.getComputerLabel() or ("CC#" .. os.getComputerID())
local selfID   = os.getComputerID()
local visualDriving = false   -- runtime "VisualDriving" command state
local redLatch      = false   -- stop curve cannot stop in time: full brake until handle EB
local calib         = nil     -- active performance-calibration state machine (nil = idle)
local calibHold     = false   -- hold full brake after calibration until really stopped
local calibArmed    = false   -- "Calibrate" typed at EB handle arms it; pull to N to start

-- ============================================================
-- 1. Lever mode + output helpers
-- ============================================================

-- Lever zones: 0-4 forward (master), 5-10 neutral (slave), 11-15 reverse (master)
local function leverMode(sig)
    if sig <= 4 then
        return "master", false     -- forward
    elseif sig >= 11 then
        return "master", true      -- reverse
    else
        return "slave", false      -- neutral
    end
end

-- Set brake output; level is strength 0..1 (bogey brakeStrength).
-- The (mainThread) peripheral is only called when the value actually
-- changed, so the loop never blocks on per-tick peripheral tasks.
local revSign = 1   -- sign applied to the drive stress (reverse)
local function setBrake(level)
    local out = math.max(0, math.min(1, level))
    for _, p in ipairs(bogeys) do
        local last = lastSentBrake[p]
        if last == nil or math.abs(out - last) >= 0.01 then
            lastSentBrake[p] = out
            bCallOne(p, "setBrakeStrengthOverride", out)
        end
    end
end

-- Remember the travel direction; it is applied as the sign of the drive
-- stress (negative = reverse). There is no reverse gearbox output any more.
local function setReverseGearbox(activate)
    revSign = activate and -1 or 1
end

-- Set throttle output; throttleInput is drive stress 0..DRIVE_STRESS_MAX
-- (bogey setMaxStress). revSign picks the direction, and the change-only
-- cache stores the SIGNED value so a direction flip with an unchanged
-- magnitude is still pushed to the bogey.
-- The bogey needs kinetic RPM (getSpeed) to produce force - that comes from
-- the gearbox / kinetic network, which must be fed by constant redstone.
local function setThrottleOutput(throttleInput)
    local out = math.max(0, math.min(DRIVE_STRESS_MAX, throttleInput))
    local signed = revSign * out
    for _, p in ipairs(bogeys) do
        local last = lastSentStress[p]
        if last == nil or math.abs(signed - last) >= 1 then
            lastSentStress[p] = signed
            bCallOne(p, "setMaxStress", signed)
        end
    end
end

-- ============================================================
-- 2. RHI notch mapping (master side)
-- ============================================================
-- Notch mapping (RHI handle):
--   0    : EB  - emergency brake, full brake strength 1.0, set speed = 0
--   1-9  : B9..B1 - direct brake strength (10-sig)/15 (sig 1 -> 0.6 ... sig 9 -> 0.067), set speed = 0
--   10   : N   - neutral, no traction, no brake (coast)
--   11   : K1  - decrease set speed 5 km/h per second
--   12   : K2  - decrease set speed 1 km/h per second
--   13   : C   - keep set speed unchanged
--   14   : K3  - increase set speed 1 km/h per second
--   15   : K4  - increase set speed 5 km/h per second
--
-- Coming back into the N/K1..K4 region from EB, a B notch or C re-seeds the
-- set speed with the current actual speed (see updateRHI).
--
-- Ramp rates in m/s per second; per-tick step is scaled by measured dt so
-- the rates stay exactly 5/1 km/h/s regardless of pidDt or loop overhead.
local RAMP_HI = 5.0 / 3.6   -- 5 km/h/s
local RAMP_LO = 1.0 / 3.6   -- 1 km/h/s

local masterCut    = false    -- true = EB (signal 0), full shutdown
local rhi_setSpeed = 0        -- persistent set speed maintained by RHI
local notchLevel   = "?"      -- current notch name (EB/B9..B1/N/K1/K2/C/K3/K4), for display
local notchBrake   = 0        -- direct brake signal for B9..B1 (0 = none)
local notchNeutral = false    -- true = N (signal 10), no traction and no brake
local lastNotchCat = nil      -- notch region of the previous tick (see below)

-- Notch regions: EB and B hold the set speed at zero, C freezes it, and
-- N/K1..K4 are the region where the set speed is actually driven.
local function notchCategory(sig)
    if sig == 0 then return "eb" end
    if sig <= 9 then return "brake" end
    if sig == 13 then return "hold" end
    return "kn"        -- N (10) and K1..K4 (11, 12, 14, 15)
end

-- Call each loop; updates rhi_setSpeed, notchLevel and mode flags from current
-- notch signal. actualSpeed (m/s) is used to hand the set speed over when the
-- handle comes back into the N/K region.
local function updateRHI(dt, actualSpeed)
    local sig = redstone.getAnalogInput(SIDE_SETSPEED)

    -- Entering the speed-control region (N / K1..K4) from EB, a B notch or C
    -- starts the set speed at the CURRENT speed: the train then holds or ramps
    -- from where it is, instead of from the stale value EB/B left behind
    -- (zero after EB/B, an old target after C). Inside the N/K region the set
    -- speed is left alone so the K ramps keep working.
    local cat = notchCategory(sig)
    if cat == "kn" and lastNotchCat ~= "kn" then
        rhi_setSpeed = math.max(0, math.min(MAX_SPEED, actualSpeed or 0))
    end
    lastNotchCat = cat

    if sig == 0 then
        -- EB: full emergency brake, set speed zero
        masterCut = true
        notchBrake = 0
        notchNeutral = false
        rhi_setSpeed = 0
        notchLevel = "EB"
        return
    end

    masterCut = false

    if sig <= 9 then
        -- B9..B1: direct brake strength (10-sig)/15 of full, set speed zero
        notchBrake = (10 - sig) / 15
        notchNeutral = false
        rhi_setSpeed = 0
        notchLevel = string.format("B%d", 10 - sig)
        return
    end

    if sig == 10 then
        -- N: neutral, no traction and no brake; set speed unchanged
        notchBrake = 0
        notchNeutral = true
        notchLevel = "N"
        return
    end

    notchBrake = 0
    notchNeutral = false

    if sig >= 11 and sig <= 12 then
        -- K1 (11): -5 km/h/s, K2 (12): -1 km/h/s
        local rate = (sig == 11) and RAMP_HI or RAMP_LO
        rhi_setSpeed = rhi_setSpeed - rate * dt
        notchLevel = (sig == 11) and "K1" or "K2"
    elseif sig == 13 then
        -- C: keep set speed unchanged
        notchLevel = "C"
    elseif sig >= 14 and sig <= 15 then
        -- K3 (14): +1 km/h/s, K4 (15): +5 km/h/s
        local rate = (sig == 14) and RAMP_LO or RAMP_HI
        rhi_setSpeed = rhi_setSpeed + rate * dt
        notchLevel = (sig == 14) and "K3" or "K4"
    end

    -- Clamp to valid range
    rhi_setSpeed = math.max(0, math.min(MAX_SPEED, rhi_setSpeed))
end

-- Returns the current persistent set speed (used by main loop)
local function getSetSpeed()
    return rhi_setSpeed
end

-- ============================================================
-- 3. Unified PID controller (master side)
-- ============================================================
local PID_DT       = cfg.pidDt or 0.05   -- loop cadence (0.05 s = 20 Hz)
local PID_KI       = cfg.pidKi
local PID_KD       = cfg.pidKd
local KP_NEAR      = cfg.pidKpNear
local KP_MID       = cfg.pidKpMid
local KP_FAR       = cfg.pidKpFar
local THRESH_NEAR  = cfg.nearThreshold
local THRESH_FAR   = cfg.farThreshold
local DEADBAND     = cfg.pidDeadband
local NO_BRAKE     = cfg.noBrakeWindow or 0.5   -- m/s: no-brake coast window near setpoint
local BRAKE_SCALE  = cfg.brakeScale
local EMERG_KP     = cfg.emergencyBrakeKp

local pid = { integral = 0, lastError = 0 }

local function pidReset()
    pid.integral  = 0
    pid.lastError = 0
end

-- Variable gain: returns Kp based on absolute error magnitude
-- Two-segment continuous interpolation, no jump at zone boundaries:
--   near zone  (|err| < nearThreshold)                : KP_NEAR
--   mid zone   (nearThreshold <= |err| < midErr)      : KP_NEAR -> KP_MID
--   mid zone   (midErr <= |err| < farThreshold)       : KP_MID  -> KP_FAR
--   far zone   (|err| >= farThreshold)                : KP_FAR
local function gainSchedule(absErr)
    local midErr = (THRESH_NEAR + THRESH_FAR) / 2
    if absErr < THRESH_NEAR then
        return KP_NEAR
    elseif absErr < midErr then
        local t = (absErr - THRESH_NEAR) / (midErr - THRESH_NEAR)
        return KP_NEAR + t * (KP_MID - KP_NEAR)
    elseif absErr < THRESH_FAR then
        local t = (absErr - midErr) / (THRESH_FAR - midErr)
        return KP_MID + t * (KP_FAR - KP_MID)
    else
        return KP_FAR
    end
end

-- Unified PID compute:
--   returns driveOut [0,DRIVE_STRESS_MAX] and brakeOut [0,1]
--   positive PID output -> drive stress; negative -> brake strength
--   setSpeed==0: emergency brake, bypass PID
local function pidCompute(setSpeed, actualSpeed, dt)
    -- Emergency stop
    if setSpeed <= 0 then
        pidReset()
        if actualSpeed > 0.02 then
            return 0, math.min(1, EMERG_KP * actualSpeed * BRAKE_SCALE)
        else
            return 0, 0
        end
    end

    local err = setSpeed - actualSpeed
    local absErr = math.abs(err)

    -- Deadband: freeze integral near setpoint, no throttle and no brake (coast)
    -- No-brake window: slightly over setpoint (err < 0, |err| < noBrakeWindow)
    -- -> coast instead of braking, so the train eases into the target speed
    if absErr < DEADBAND or (err < 0 and absErr < NO_BRAKE) then
        pid.lastError = err
        return 0, 0
    end

    -- Variable Kp
    local Kp = gainSchedule(absErr)

    -- Integral (anti-windup +/-30; tuned for the 0..128 output range)
    pid.integral = math.max(-30, math.min(30, pid.integral + err * dt))

    -- Derivative
    local D = PID_KD * (err - pid.lastError) / dt
    pid.lastError = err

    local output = Kp * err + PID_KI * pid.integral + D

    -- Split into drive / brake with direct peripheral units:
    --   positive -> drive stress 0..128 (bogey setMaxStress)
    --   negative -> brake strength 0..1 (bogey setBrakeStrength), capped by
    --   brakeScale at the full-drive level. No 0-15 analog scale anymore.
    if output >= 0 then
        return math.min(DRIVE_STRESS_MAX, output), 0
    else
        return 0, math.min(1, -output / DRIVE_STRESS_MAX * BRAKE_SCALE)
    end
end

-- ============================================================
-- 4. Output slew-rate limiting (master side)
-- ============================================================
-- In master mode, throttle and brake outputs ramp toward the PID target at
-- most MAX_OUT_DELTA stress units (0..128) per 0.1 s of loop time, so force
-- never jumps. EB / B / N / fault states still switch instantly.
local MAX_OUT_DELTA = cfg.maxOutputDelta or 17.0
local lastDriveOut  = 0
local lastBrakeOut  = 0

-- Move current output toward target by at most maxDelta per tick
local function rampOut(target, last, maxDelta)
    if target > last + maxDelta then
        return last + maxDelta
    elseif target < last - maxDelta then
        return last - maxDelta
    else
        return target
    end
end

-- ============================================================
-- 5. Velocity sensor (scan direct sides AND wired network)
-- ============================================================
local sensor = nil
-- The sensor may be attached directly to the computer OR reached through a
-- wired network (e.g. via a wired modem block), so scan peripheral.getNames()
-- instead of only the six computer sides.
for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "velocity_sensor" then
        sensor = peripheral.wrap(name)
        print("Velocity sensor found: " .. name)
        break
    end
end
if not sensor then
    print("WARNING: No velocity_sensor found. Actual speed will show N/A.")
end

-- Read actual speed from sensor; returns nil if unavailable
local function getActualSpeed()
    if not sensor then return nil end
    local ok, v = pcall(sensor.getVelocity)
    if ok and type(v) == "number" then return math.abs(v) end
    return nil
end

-- ============================================================
-- 6. Monitor helpers + display
-- ============================================================
local monitor = peripheral.wrap(SIDE_MONITOR)

local function mCall(method, ...)
    if monitor and monitor[method] then
        pcall(monitor[method], ...)
    end
end

local monH = 0   -- monitor height in characters (0 = unknown)
if monitor then
    -- Shrink text so more info fits on a 1x1 monitor
    mCall("setTextScale", 0.5)
    mCall("setBackgroundColor", colors.black)
    mCall("clear")
    local ok, w, h = pcall(monitor.getSize)
    if ok and type(h) == "number" then
        monH = h
        -- A 1x1 monitor at text scale 0.5 is 15x10 characters; a 2x2 is 30x20.
        print(string.format("Monitor: %dx%d characters", w or 0, h))
    end
end

-- Speed color: green=slow, yellow=mid, red=fast, gray=stopped
local function speedColor(v)
    if v <= 0 then
        return colors.lightGray
    elseif v < MAX_SPEED * 0.4 then
        return colors.green
    elseif v < MAX_SPEED * 0.8 then
        return colors.yellow
    else
        return colors.red
    end
end

-- updateDisplay(setSpeed, actualSpeed, driveOut, brakeOut, reverse, level, role, fault, redDist)
local function updateDisplay(setSpeed, actualSpeed, driveOut, brakeOut, reverse, level, role, fault, redDist)
    if not monitor then return end
    mCall("clear")

    -- Line 1: Locomotive name
    mCall("setCursorPos", 1, 1)
    mCall("setTextColor", colors.yellow)
    monitor.write(locoName)

    -- Line 2: Set speed (km/h)
    mCall("setCursorPos", 1, 2)
    mCall("setTextColor", speedColor(setSpeed))
    monitor.write(string.format("Set:%.1f", setSpeed * 3.6))

    -- Line 3: Actual speed from sensor, km/h (0 if sensor unavailable)
    mCall("setCursorPos", 1, 3)
    mCall("setTextColor", speedColor(actualSpeed))
    monitor.write(string.format("Spd:%.1f ", actualSpeed * 3.6))

    -- Line 4: Drive stress output (0..128, sign = direction)
    mCall("setCursorPos", 1, 4)
    mCall("setTextColor", colors.cyan)
    local stressOut = math.floor(driveOut + 0.5)
    if reverse then stressOut = -stressOut end
    monitor.write(string.format("T:%+4d", stressOut))

    -- Line 5: Brake strength percent (0-100, bogey brakeStrength is 0..1)
    mCall("setCursorPos", 1, 5)
    if brakeOut > 0 then
        mCall("setTextColor", colors.red)
    else
        mCall("setTextColor", colors.gray)
    end
    monitor.write(string.format("B:%3d%%", math.floor(brakeOut * 100 + 0.5)))

    -- Line 6: Direction
    mCall("setCursorPos", 1, 6)
    if reverse then
        mCall("setTextColor", colors.orange)
        monitor.write("DIR: << REV")
    else
        mCall("setTextColor", colors.lime)
        monitor.write("DIR:  FWD >>")
    end

    -- Line 7: status flags (BRK / red distance / VIS / LAT / ARM)
    local flags = {}
    if brakeOut > 0 then flags[#flags + 1] = "BRK" end
    if redDist then flags[#flags + 1] = string.format("R:%.0f", redDist) end
    if visualDriving then flags[#flags + 1] = "VIS" end
    if redLatch then flags[#flags + 1] = "LAT" end
    if calibArmed then flags[#flags + 1] = "ARM" end
    local clock = os.date("%H:%M:%S")
    local line7 = table.concat(flags, " ")
    if monH < 9 then
        -- Short monitor: no room for the clock line, keep it on line 7.
        line7 = (line7 ~= "") and (clock .. " " .. line7) or clock
    end
    mCall("setCursorPos", 1, 7)
    mCall("setTextColor", colors.lightGray)
    monitor.write(line7)

    -- Line 8: Role + notch level, or network fault
    mCall("setCursorPos", 1, 8)
    if fault then
        mCall("setTextColor", colors.red)
        monitor.write("** FAULT EB **")
    else
        mCall("setTextColor", colors.white)
        monitor.write((role == "master" and "M:" or "S:") .. (level or "?"))
    end

    -- Line 9: clock, under the notch level
    if monH >= 9 then
        mCall("setCursorPos", 1, 9)
        mCall("setTextColor", colors.lightGray)
        monitor.write(clock)
    end
end

-- ============================================================
-- 7. Wireless network (modem side per config)
-- ============================================================
local netUp = pcall(rednet.open, SIDE_MODEM)
if not netUp then
    print("WARNING: no modem on side '" .. SIDE_MODEM .. "', consist network disabled")
else
    print("Network up on protocol '" .. MU_PROTOCOL .. "'")
end

-- seen[senderID] = { mode = "master"/"slave", label = ..., t = os.clock() }
local seen = {}
local lastCtrl   = nil   -- last control message received from the master
local lastCtrlRx = 0
local ctrlMaster = nil   -- label of the current control master
local broadcastFailWarned = false
local txCount, rxCount = 0, 0
local lastBroadcastAt = 0

-- Broadcast this vehicle's status (and control data if it is the master),
-- throttled to ~10 Hz so a fast loop does not flood rednet.
local function broadcastState(role, ctrl)
    if not netUp then return end
    local bNow = os.clock()
    if bNow - lastBroadcastAt < 0.1 then return end
    lastBroadcastAt = bNow
    local msg = { role = role, label = locoName }
    if ctrl then
        msg.ctrl = ctrl
    end
    local ok, err = pcall(rednet.broadcast, msg, MU_PROTOCOL)
    if not ok and not broadcastFailWarned then
        broadcastFailWarned = true
        print("BROADCAST FAILED: " .. tostring(err) .. " (reported once)")
    end
    txCount = txCount + 1
end

-- ============================================================
-- 7b. Runtime commands + event dispatch
-- ============================================================
-- Commands are typed at the terminal and submitted with Enter.
--   VisualDriving (or vd) : toggle visual driving mode (speed cap +
--                           red signals allowed). Type help for the list.
local cmdBuffer = ""

local function submitCommand()
    local cmd = string.lower(cmdBuffer)
    cmdBuffer = ""
    if cmd == "visualdriving" or cmd == "vd" then
        visualDriving = not visualDriving
        if visualDriving then
            print("Visual driving ON: max " .. (VISUAL_MAX * 3.6) .. " km/h, red signals allowed")
        else
            print("Visual driving OFF")
        end
    elseif cmd == "help" then
        print("Commands: VisualDriving (vd), Calibrate (calib), help")
    elseif cmd == "calibrate" or cmd == "calib" then
        if calib then
            print("CALIB: already running (step " .. calib.step .. ")")
        elseif calibArmed then
            calibArmed = false
            print("CALIB: disarmed")
        elseif redstone.getAnalogInput(SIDE_SETSPEED) == 0 then
            calibArmed = true
            print("CALIB: armed - pull the RHI handle to N to start")
        else
            print("CALIB: set the RHI handle to EB (signal 0) first")
        end
    elseif cmd ~= "" then
        print("Unknown command: '" .. cmdBuffer .. "' (type help)")
    end
end

local function handleKey(key)
    if key == keys.enter then
        submitCommand()
    elseif key == keys.backspace then
        cmdBuffer = string.sub(cmdBuffer, 1, -2)
    end
end

-- Pull events unfiltered so nothing is discarded: rednet traffic arrives as
-- rednet_message (the rednet background daemon, started in a parallel
-- coroutine by the BIOS, converts modem_message and CC's parallel library
-- delivers the event to every listener); keyboard char/key events drive
-- commands; the timer bounds the wait and paces the loop. This replaces
-- rednet.receive and sleep(), neither of which can coexist with live
-- keyboard input.
-- Returns sender, msg, protocol, or nil on timeout.
local function receiveWithInput(timeout)
    local timer = os.startTimer(timeout)
    while true do
        local ev, p1, p2, p3 = os.pullEvent()
        if ev == "terminate" then
            error("Terminated", 0)
        elseif ev == "timer" then
            if p1 == timer then return nil end
        elseif ev == "char" then
            cmdBuffer = cmdBuffer .. p1
        elseif ev == "key" then
            handleKey(p1)
        elseif ev == "rednet_message" then
            -- senderID, message, protocol
            return p1, p2, p3
        end
    end
end

-- ============================================================
-- 7c. Performance calibration (master only, runtime "Calibrate" cmd)
-- ============================================================
-- Runs a full-throttle accel phase, then a full-brake decel phase from a
-- cruise speed, fitting the velocity samples (least squares) to get real
-- m/s^2 rates. Saved as JSON to CALIB_FILE on this computer so future
-- automatic train control (LKJ) can use real performance numbers.
-- Pre-checks happen in the main loop (startCalibration is called there).
--
-- Two-step arming: pull the RHI handle to EB (signal 0) and type "Calibrate"
-- to arm, then pull the handle to N (signal 10) to actually start. Failure to
-- meet the pre-checks keeps the calibration armed (printed once) so you can
-- retry; type "Calibrate" again at EB to disarm.

local calibAccelRate, calibBrakeRate, calibTopSpeed = nil, nil, nil
local calibAccelFit, calibBrakeFit = nil, nil   -- { a0, a1, v0, rms, r2, n }

local function calibFit(samples)
    local n = #samples
    if n < 5 then return nil end
    local sT, sV, sTT, sTV = 0, 0, 0, 0
    for _, s in ipairs(samples) do
        sT  = sT + s.t
        sV  = sV + s.v
        sTT = sTT + s.t * s.t
        sTV = sTV + s.t * s.v
    end
    local den = n * sTT - sT * sT
    if math.abs(den) < 1e-9 then return nil end
    -- least-squares slope = dv/dt in m/s^2: POSITIVE while accelerating,
    -- NEGATIVE while braking. Callers must handle the sign.
    return (n * sTV - sT * sV) / den
end

-- Least-squares fit of a(v) = a0 + a1*v over (t,v) samples.
--
-- The model is the physics of this bogey: driveMag is proportional to
-- (targetSpeed - v), so acceleration falls off linearly with speed and hits
-- zero at the bogey's target speed. a1 is therefore expected to be NEGATIVE.
--
-- Raw per-tick slopes are NOT used directly: at 20 Hz the speed change per
-- tick is tiny near the top speed (where the fall-off is) and sensor
-- quantisation would dominate. Instead the samples are binned by speed and
-- each bin contributes ONE point - the average rate over that bin's time span,
-- placed at the mean speed. Long spans (which is exactly what the near-top
-- bins have) give a much better rate estimate than a single 0.05 s interval.
--
-- sign = +1 for the accel run, -1 for the brake run (deceleration positive).
-- Returns a table { a0, a1, v0, rms, r2, n } or nil:
--   v0  = speed where a(v) = 0 (the predicted traction ceiling)
--   rms = residual RMS of the fit (m/s^2), r2 = coefficient of determination
local function fitLinear(samples, sign, binWidth)
    binWidth = binWidth or 1.0
    local bins = {}
    for _, s in ipairs(samples) do
        local key = math.floor(s.v / binWidth)
        local b = bins[key]
        if b then
            b.t1, b.v1, b.n = s.t, s.v, b.n + 1
        else
            bins[key] = { t0 = s.t, t1 = s.t, v0 = s.v, v1 = s.v, n = 1 }
        end
    end
    local pts = {}
    for _, b in pairs(bins) do
        local dt = b.t1 - b.t0
        local v = (b.v0 + b.v1) / 2
        if b.n >= 2 and dt >= 0.25 and v >= 0.5 then
            pts[#pts + 1] = { v = v, a = sign * (b.v1 - b.v0) / dt }
        end
    end
    local m = #pts
    if m < 4 then return nil end

    local sV, sA, sVV, sVA = 0, 0, 0, 0
    for _, p in ipairs(pts) do
        sV, sA = sV + p.v, sA + p.a
        sVV, sVA = sVV + p.v * p.v, sVA + p.v * p.a
    end
    local den = m * sVV - sV * sV
    local a0, a1
    if math.abs(den) < 1e-9 then
        a0, a1 = sA / m, 0          -- speeds nearly constant: flat line
    else
        a1 = (m * sVA - sV * sA) / den
        a0 = (sA - a1 * sV) / m
    end

    -- Fit quality and the zero-acceleration speed.
    local ssRes, ssTot, aMean = 0, 0, sA / m
    for _, p in ipairs(pts) do
        local e = p.a - (a0 + a1 * p.v)
        ssRes = ssRes + e * e
        ssTot = ssTot + (p.a - aMean) * (p.a - aMean)
    end
    local v0 = (a1 < -1e-6 and a0 > 0) and (-a0 / a1) or nil
    return {
        a0 = a0, a1 = a1, v0 = v0, n = m,
        rms = math.sqrt(ssRes / m),
        r2 = ssTot > 1e-9 and (1 - ssRes / ssTot) or nil,
    }
end

local function saveCalib()
    if not calibAccelRate or not calibBrakeRate then return false end
    local strength = CALIB_BRAKE_STR
    -- Brake force is linear in brakeStrength in the bogey physics, so the
    -- full-brake rate is the measured rate divided by the strength used.
    local full = calibBrakeRate / strength
    local function r3(x) return math.floor((x or 0) * 1000 + 0.5) / 1000 end

    -- Fitted curves (fall back to a flat line at the average rate).
    local acc = calibAccelFit or { a0 = calibAccelRate, a1 = 0 }
    local brk = { a0 = full, a1 = 0 }
    if calibBrakeFit then
        brk = {
            a0 = calibBrakeFit.a0 / strength,
            a1 = calibBrakeFit.a1 / strength,
            rms = (calibBrakeFit.rms or 0) / strength,
            r2 = calibBrakeFit.r2, n = calibBrakeFit.n,
        }
    end

    -- Sampled profile for external consumers (LKJ/tcc): step 2 m/s up to top.
    local step = 2.0
    local vTop = calibTopSpeed or 0
    local vTab, aTab, dTab = {}, {}, {}
    for v = 0, math.ceil(vTop / step) * step, step do
        vTab[#vTab + 1] = r3(v)
        aTab[#aTab + 1] = r3(math.max(0, acc.a0 + acc.a1 * v))
        dTab[#dTab + 1] = r3(math.max(0, brk.a0 + brk.a1 * v))
    end

    local data = {
        version = 3,
        savedAt = os.date("%Y-%m-%dT%H:%M:%S"),
        topMps = r3(vTop),
        accel = {
            mps2 = r3(calibAccelRate),   -- average over the measurement window
            a0 = r3(acc.a0), a1 = r3(acc.a1),
            vmax = r3((acc.a0 > 0 and acc.a1 < 0) and (-acc.a0 / acc.a1) or 0),
            rms = r3(acc.rms), r2 = r3(acc.r2), bins = acc.n or 0,
        },
        brake = {
            mps2 = r3(calibBrakeRate),   -- measured at the strength below
            strength = strength,
            mps2Full = r3(full),
            d0 = r3(brk.a0), d1 = r3(brk.a1),   -- full-brake curve
            rms = r3(brk.rms), r2 = r3(brk.r2), bins = brk.n or 0,
        },
        profile = { step = step, v = vTab, accel = aTab, brake = dTab },
    }
    local f = fs.open(CALIB_FILE, "w")
    if not f then return false end
    f.write(textutils.serializeJSON(data, true))
    f.close()
    -- Apply the fresh curve immediately (no reboot needed).
    loadPerf()
    printPerf()
    return true
end

-- Advance the calibration state machine. Returns drive, brake, next (nil = end).
-- Profile: full throttle until the speed plateaus (full traction can no longer
-- raise it) or MAX_SPEED (the set-speed ceiling) is reached, whichever comes
-- first; then coast briefly and brake at CALIB_BRAKE_STR to a standstill.
local function calibStep(c, dt, v, now)
    if c.step == "accel_warmup" then
        -- Full throttle on; wait CALIB_SETTLE so the output has taken effect
        if now - c.t0 >= CALIB_SETTLE then
            c.step, c.t0, c.samples = "accel_meas", now, {}
            c.samplesT0 = now          -- time base shared with the climb
            c.maxSeen, c.lastGainAt = v, now
        end
        return DRIVE_STRESS_MAX, 0, c
    elseif c.step == "accel_meas" then
        c.samples[#c.samples + 1] = { t = now - c.samplesT0, v = v }
        if v > c.maxSeen then c.maxSeen = v end
        if now - c.t0 >= CALIB_ACCEL_DUR then
            local a = calibFit(c.samples)
            if a and a > 0.05 then
                calibAccelRate = a
                print(string.format("CALIB accel: %.3f m/s^2 (%.1f km/h/s, %d samples)", a, a * 3.6, #c.samples))
                c.step, c.t0 = "run_up", now
                c.lastGainAt = now
            else
                print("CALIB FAILED: accel fit invalid" ..
                    (a and " (speed did not rise)" or " (need >= 5 samples)"))
                return 0, 1.0, nil
            end
        end
        return DRIVE_STRESS_MAX, 0, c
    elseif c.step == "run_up" then
        -- Keep sampling through the whole climb: this series is what the
        -- a(v) = a0 + a1*v curve is fitted from (traction fades with speed).
        c.samples[#c.samples + 1] = { t = now - c.samplesT0, v = v }
        -- Climb at full throttle until the top speed is found: the speed stops
        -- gaining more than CALIB_PLATEAU_EPS for CALIB_PLATEAU_TIME (it
        -- hovers around a value) or the configured ceiling MAX_SPEED is hit.
        if v > c.maxSeen + CALIB_PLATEAU_EPS then
            c.maxSeen = v
            c.lastGainAt = now
        end
        local plateau = now - c.lastGainAt >= CALIB_PLATEAU_TIME
        local capped = c.maxSeen >= MAX_SPEED
        if plateau or capped then
            local vTop = math.min(c.maxSeen, MAX_SPEED)
            if vTop < CALIB_MIN_TOP then
                print(string.format("CALIB FAILED: top speed only %.1f km/h - check traction/gearbox",
                    vTop * 3.6))
                return 0, 1.0, nil
            end
            print(string.format("CALIB top speed: %.1f km/h (%s)", vTop * 3.6,
                capped and "set-speed ceiling" or "traction limit"))
            c.vTop = vTop
            calibTopSpeed = vTop
            local fit = fitLinear(c.samples, 1)
            if fit then
                calibAccelFit = fit
                print(string.format("CALIB accel curve: a(v) = %.3f%+.4f*v m/s^2 | zero at %s | %d bins, rms %.3f%s",
                    fit.a0, fit.a1, fit.v0 and string.format("%.1f m/s", fit.v0) or "n/a",
                    fit.n, fit.rms, fit.r2 and string.format(", r2 %.3f", fit.r2) or ""))
                if fit.a1 > 0 then
                    print("WARN: accel rises with speed - curve looks wrong (check traction/sensor)")
                end
            else
                print("CALIB: accel curve needs more bins - using the average rate")
            end
            c.brakeTimeout = math.max(CALIB_BRAKE_TIMEOUT, vTop / CALIB_BRAKE_MIN_DECEL)
            c.step, c.t0, c.samples = "brake_settle", now, {}
        elseif now - c.t0 > CALIB_RUN_TIMEOUT then
            print("CALIB FAILED: no stable top speed within " .. CALIB_RUN_TIMEOUT .. "s")
            return 0, 1.0, nil
        end
        return DRIVE_STRESS_MAX, 0, c
    elseif c.step == "brake_settle" then
        -- Coast a moment, then apply the calibration brake with a stable output
        if now - c.t0 >= CALIB_SETTLE then
            c.step, c.t0, c.samples = "brake_meas", now, {}
            print(string.format("CALIB: braking at %.0f%% from %.1f km/h", CALIB_BRAKE_STR * 100, v * 3.6))
        end
        return 0, 0, c
    elseif c.step == "brake_meas" then
        c.samples[#c.samples + 1] = { t = now - c.t0, v = v }
        local stopped = v <= CALIB_STOP
        if stopped or now - c.t0 >= (c.brakeTimeout or CALIB_BRAKE_TIMEOUT) then
            local b = calibFit(c.samples)
            -- calibFit returns dv/dt, which is NEGATIVE while braking, so the
            -- deceleration is -b. (An older version tested b > 0, which no
            -- real brake run can ever satisfy - calibration then always
            -- reported "brake fit invalid" and never saved anything.)
            if b and b < -0.05 then
                calibBrakeRate = -b
                print(string.format("CALIB brake: %.3f m/s^2 at %.0f%% (%.1f km/h/s, %d samples)",
                    calibBrakeRate, CALIB_BRAKE_STR * 100, calibBrakeRate * 3.6, #c.samples))
                -- Speed-dependent brake curve, normalised to full brake.
                local fit = fitLinear(c.samples, -1)
                if fit then
                    calibBrakeFit = fit
                    print(string.format("CALIB brake curve: d(v) = %.3f%+.4f*v m/s^2 at full brake | %d bins, rms %.3f%s",
                        fit.a0 / CALIB_BRAKE_STR, fit.a1 / CALIB_BRAKE_STR, fit.n, fit.rms / CALIB_BRAKE_STR,
                        fit.r2 and string.format(", r2 %.3f", fit.r2) or ""))
                else
                    print("CALIB: brake curve needs more bins - using the average rate")
                end
                local ok = saveCalib()
                print(ok and ("CALIB: saved to " .. CALIB_FILE) or ("CALIB: FAILED to write " .. CALIB_FILE))
            elseif b and b > 0.05 then
                print("CALIB FAILED: speed rose during the brake run (brake not effective?)")
            else
                print("CALIB FAILED: brake fit invalid" .. (stopped and "" or " (timeout)"))
            end
            return 0, 1.0, nil
        end
        return 0, CALIB_BRAKE_STR, c
    end
    return 0, 1.0, nil   -- unknown step: bail out with full brake
end

-- Called from the main loop when armed ("Calibrate" at EB) and the RHI handle
-- is at N (signal 10). Keeps calibArmed on failure (refusal printed once) so
-- the driver can retry once conditions are met. On success sets calib.
local lastRefuse = ""
local function refuse(msg)
    if msg ~= lastRefuse then
        lastRefuse = msg
        print("CALIB: " .. msg)
    end
end

local function startCalibration(role, fault, redDist, actualSpeed)
    if not sensor then
        refuse("no velocity sensor - cannot calibrate")
        return
    end
    if role ~= "master" then
        refuse("lever must be in a master zone (0-4 fwd / 11-15 rev)")
        return
    end
    if fault then
        refuse("consist network fault - cannot calibrate")
        return
    end
    if actualSpeed > CALIB_STOP then
        refuse("train must be stopped (now " .. string.format("%.1f", actualSpeed * 3.6) .. " km/h)")
        return
    end
    -- The run-up needs a clear stretch: refuse if a red signal is already
    -- closer than CALIB_START_CLEAR. The exact top speed is unknown up front,
    -- so the mid-run check aborts as soon as the red is about to trip.
    if redDist and not visualDriving and redDist < CALIB_START_CLEAR then
        refuse(string.format("red signal %.0f blocks ahead - cannot calibrate", redDist))
        return
    end
    calib = { step = "accel_warmup", phase = "accel", t0 = os.clock(), dur = CALIB_SETTLE }
    calibHold = false
    calibArmed = false
    lastRefuse = ""
    calibAccelRate, calibBrakeRate, calibTopSpeed = nil, nil, nil
    calibAccelFit, calibBrakeFit = nil, nil
    print(string.format("CALIB: running - full throttle to top speed (max %.0f km/h), then brake at %.0f%%",
        MAX_SPEED * 3.6, CALIB_BRAKE_STR * 100))
end

-- ============================================================
-- 8. Main loop
-- ============================================================
print("Locomotive program started: " .. locoName)
print("Max speed: " .. MAX_SPEED .. " m/s | Ctrl+T to stop")
print("Commands: VisualDriving (vd) | Calibrate (calib) | help")
print(string.format("Red protection: probe %s axle, window %.0f blocks, EB inside %.0f blocks",
    RED_PROBE_FRONT and "front" or "back", RED_WINDOW, RED_EB_DIST))

-- Ensure all outputs are off at startup
setBrake(0)
setThrottleOutput(0)
setReverseGearbox(false)

local prevSetSpeed = -1
local lastTick = os.clock()
local prevFault = false
local prevLeverSig = -1
local lastStatusPrint = 0
local ctrlLostWarned = false
local foreignWarned = false
local lastDisplayAt = 0

while true do
    -- Measure the real loop period; ramp and PID scale by it so the set
    -- speed rates (5/1 km/h/s) and PID integration stay exact regardless
    -- of pidDt or per-tick overhead. Clamp dt so a long stall (chunk lag)
    -- does not jump the set speed.
    local dt = os.clock() - lastTick
    lastTick = os.clock()
    if dt <= 0 then dt = 0.001 end
    if dt > 0.5 then dt = 0.5 end

    -- Lever mode (re-read every tick; can change while running)
    local leverSig = redstone.getAnalogInput(SIDE_REVERSE) or 0
    local role, masterReverse = leverMode(leverSig)

    -- Red signal ahead, from the bogey probe (blocks to the nearest red-for-us
    -- signal). Only the master evaluates it, and only when running forward:
    -- the probe axle is FIXED to one end of the bogey, so when reversing it
    -- looks the wrong way and reverse stays exempt (the driver backs by
    -- sight). Slaves follow the broadcast ctrl and must not read it.
    local redDist = nil
    if role == "master" and not masterReverse then
        redDist = redSignalAhead()
    end
    -- Visual driving exempts the whole red-signal protection.
    local redActive = redDist ~= nil and not visualDriving
    if leverSig ~= prevLeverSig then
        print("Lever: " .. leverSig .. " -> " .. role .. (masterReverse and " REV" or ""))
        prevLeverSig = leverSig
    end

    -- Collect statuses, master control and keyboard commands. Unfiltered
    -- event dispatch (receiveWithInput) so nothing is discarded; protocol
    -- isolation is done in code below (and foreign traffic logged once).
    -- The blocking wait also paces the loop (no sleep(), which would eat
    -- modem events and break reception) and it is used even without a modem
    -- so terminal commands (VisualDriving / Calibrate) still work.
    local sender, msg, proto = receiveWithInput(PID_DT)
    if sender and proto ~= MU_PROTOCOL then
        if not foreignWarned then
            foreignWarned = true
            print("Foreign protocol '" .. tostring(proto) .. "' ignored (ours '" .. MU_PROTOCOL .. "')")
        end
        msg = nil
    end
    if sender and type(msg) == "table" then
        if msg.role == "master" or msg.role == "slave" then
            local old = seen[sender]
            if not old then
                print("Heard '" .. (msg.label or ("#" .. sender)) .. "' as " .. msg.role)
            elseif old.mode ~= msg.role then
                print("'" .. (msg.label or ("#" .. sender)) .. "' changed: " .. old.mode .. " -> " .. msg.role)
            end
            seen[sender] = { mode = msg.role, label = msg.label, t = os.clock() }
            rxCount = rxCount + 1
        end
        if msg.role == "master" and msg.ctrl then
            lastCtrl   = msg.ctrl
            lastCtrlRx = os.clock()
            ctrlMaster = msg.label
        end
    end

    -- Own status counts too
    local now = os.clock()
    seen[selfID] = { mode = role, label = locoName, t = now }

    -- Purge stale senders and count masters
    local masters = 0
    for id, s in pairs(seen) do
        if now - s.t > MU_TTL then
            seen[id] = nil
        elseif s.mode == "master" then
            masters = masters + 1
        end
    end
    local fault = (masters ~= 1)
    if fault ~= prevFault then
        if fault then
            print("FAULT: " .. masters .. " master(s) (lever=" .. leverSig .. "), EB engaged")
        else
            print("OK: 1 master on network (lever=" .. leverSig .. ")")
        end
        prevFault = fault
    end

    -- Periodic network status line (every 10s) for diagnostics
    if now - lastStatusPrint > 10 then
        lastStatusPrint = now
        local parts = {}
        for id, s in pairs(seen) do
            parts[#parts + 1] = (s.label or ("#" .. id)) .. "=" .. s.mode
        end
        print("STATUS: " .. masters .. " master(s) | TX=" .. txCount .. " RX=" .. rxCount .. " | " .. table.concat(parts, " "))
    end

    local actualSpeed = getActualSpeed() or 0

    -- Calibration trigger: armed at EB, pull the RHI handle to N (signal 10)
    -- to start. Full pre-checks run here with current loop state; on refusal
    -- the calibration stays armed so the driver can retry from N.
    if calibArmed and redstone.getAnalogInput(SIDE_SETSPEED) == 10 then
        startCalibration(role, fault, redDist, actualSpeed)
    end

    local driveOut, brakeOut, revOut = 0, 0, false
    local setSpeed, level = 0, "?"

    if fault then
        -- Network fault: cut traction, apply EB (also aborts any calibration)
        calib = nil
        driveOut, brakeOut = 0, 1.0
        lastDriveOut, lastBrakeOut = 0, 1.0
        revOut = masterReverse
        if role == "master" then
            broadcastState(role, {
                throttle = 0, brake = 1.0, reverse = revOut,
                level = "EB", setSpeed = 0,
            })
        else
            broadcastState(role, nil)
        end
    elseif calib then
        -- Performance calibration takes over: direct full-throttle / full-brake
        -- runs (no PID, no ramp) so the velocity samples measure raw physics.
        -- Abort if the lever leaves a master zone: a slave must never command
        -- traction, and the network would otherwise see a phantom master.
        -- Abort on a red signal only when it is actually too close for the
        -- current speed (a distant red must not block a calibration run).
        local redTooClose = redDist ~= nil and redDist <= RED_EB_DIST
        if role ~= "master" then
            print("CALIB ABORTED: lever left the master zone")
            calib = nil
            calibHold = true
        elseif redTooClose or not sensor then
            print("CALIB ABORTED: " .. (not sensor and "velocity sensor lost"
                or string.format("red signal %.0f blocks ahead", redDist)))
            calib = nil
            calibHold = true
        end
        if calib then
            driveOut, brakeOut, calib = calibStep(calib, dt, actualSpeed, now)
            if not calib then
                calibHold = true
                print("CALIB: finished, holding brake until stopped")
            end
            lastDriveOut, lastBrakeOut = driveOut, brakeOut
        else
            driveOut, brakeOut = 0, 1.0
            lastDriveOut, lastBrakeOut = 0, 1.0
        end
        revOut = masterReverse
        level = "CAL"
        setSpeed = 0
        broadcastState(role, {
            throttle = driveOut, brake = brakeOut, reverse = revOut,
            level = level, setSpeed = 0,
        })
    elseif calibHold then
        -- Calibration just finished/aborted: hold full brake until really
        -- stopped (broadcast EB so slaves hold too), then normal control resumes
        driveOut, brakeOut = 0, 1.0
        lastDriveOut, lastBrakeOut = 0, 1.0
        revOut = masterReverse
        level = "EB"
        setSpeed = 0
        if actualSpeed <= CALIB_STOP then
            calibHold = false
        end
        broadcastState(role, {
            throttle = 0, brake = 1.0, reverse = revOut,
            level = "EB", setSpeed = 0,
        })
    elseif role == "master" then
        -- Master: RHI + PID + ramp
        updateRHI(dt, actualSpeed)
        setSpeed = getSetSpeed()
        -- Visual driving caps the allowed set speed (red signals ignored)
        if visualDriving and setSpeed > VISUAL_MAX then
            setSpeed = VISUAL_MAX
        end
        -- Red-signal protection (probe, forward only). No approach braking:
        -- the train drives normally until the red is inside RED_EB_DIST
        -- blocks, i.e. the axle has effectively reached the signal -> EB
        -- latch (full brake, set speed zero). The driver clears the latch by
        -- pulling the RHI handle to EB (signal 0). Exempt in visual driving.
        local handleSig = redstone.getAnalogInput(SIDE_SETSPEED) or 0
        if redLatch and handleSig == 0 then
            redLatch = false
        end
        if redActive and redDist <= RED_EB_DIST then
            redLatch = true
            rhi_setSpeed = 0
        end
        if redLatch then
            driveOut, brakeOut = 0, 1.0
            lastDriveOut, lastBrakeOut = 0, 1.0
            setSpeed = 0
        elseif masterCut then
            driveOut, brakeOut = 0, 1.0
            lastDriveOut, lastBrakeOut = 0, 1.0
        elseif notchBrake > 0 then
            -- B9..B1: direct brake signal 10-sig, set speed zero
            driveOut, brakeOut = 0, notchBrake
            lastDriveOut, lastBrakeOut = 0, notchBrake
        elseif notchNeutral then
            -- N: no traction, no brake
            driveOut, brakeOut = 0, 0
            lastDriveOut, lastBrakeOut = 0, 0
        else
            -- Reset PID integral on large setpoint step changes
            if math.abs(setSpeed - prevSetSpeed) > 1.0 then
                pidReset()
            end
            prevSetSpeed = setSpeed

            -- Unified PID: single output splits into throttle and brake
            local d, b = pidCompute(setSpeed, actualSpeed, dt)

            -- Smooth output transitions: ramp toward PID target, never jump.
            -- Delta is scaled by dt so the sweep rate stays constant at any
            -- loop rate (MAX_OUT_DELTA was tuned for a 0.1s tick).
            local rampDelta = MAX_OUT_DELTA * dt * 10
            driveOut = rampOut(d, lastDriveOut, rampDelta)
            brakeOut = rampOut(b, lastBrakeOut, rampDelta)
            lastDriveOut, lastBrakeOut = driveOut, brakeOut
        end
        revOut = masterReverse
        level  = notchLevel
        broadcastState(role, {
            throttle = driveOut, brake = brakeOut, reverse = revOut,
            level = level, setSpeed = setSpeed,
        })
    else
        -- Slave: replicate last master control, flip direction per consist config
        if lastCtrl then
            driveOut = lastCtrl.throttle or 0
            brakeOut = lastCtrl.brake   or 0
            revOut   = lastCtrl.reverse == true
            level    = lastCtrl.level or "?"
            setSpeed = lastCtrl.setSpeed or 0
        end
        if now - lastCtrlRx > MU_CTRL_TTL then
            -- No fresh master control: EB
            driveOut, brakeOut = 0, 1.0
            if not ctrlLostWarned then
                ctrlLostWarned = true
                print("CTRL LOST: no master control for " .. MU_CTRL_TTL .. "s, EB")
            end
        else
            ctrlLostWarned = false
        end
        local masterRel = (mu.others or {})[ctrlMaster]
        local flip = masterRel and masterRel.reverse == true or false
        revOut = revOut ~= flip
        lastDriveOut, lastBrakeOut = driveOut, brakeOut
        broadcastState(role, nil)
    end

    setReverseGearbox(revOut)
    setThrottleOutput(driveOut)
    setBrake(brakeOut)

    -- Throttle the monitor redraw (~4 Hz) so the fast loop does not flicker
    if now - lastDisplayAt >= 0.25 then
        lastDisplayAt = now
        updateDisplay(setSpeed, actualSpeed, driveOut, brakeOut, revOut, level, role, fault, redDist)
    end
end
