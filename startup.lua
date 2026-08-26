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
local SIDE_BRAKE      = cfg.sideBrake       -- optional in bogey mode (failback)
local SIDE_THROTTLE   = cfg.sideThrottle    -- optional: gearbox RPM feed in bogey mode
local SIDE_REVGEARBOX = cfg.sideRevGearbox  -- optional (legacy mode only)
local SIDE_RED        = cfg.sideRedSignal or "front"   -- red signal ahead (default: front)
local SIDE_MODEM      = cfg.sideModem or "front"       -- wireless modem side (rednet)
local VISUAL_MAX      = cfg.visualMaxSpeed or 10.0     -- visual driving speed cap (m/s, 36 km/h)
local CALIB_ACCEL_DUR    = cfg.calibAccelDur     or 3.0   -- s: accel measurement window
local CALIB_BRAKE_TARGET = cfg.calibBrakeTarget  or 10.0  -- m/s: cruise speed before brake run
local CALIB_RUN_TIMEOUT  = cfg.calibRunTimeout   or 20.0  -- s: max time to reach cruise speed
local CALIB_BRAKE_TIMEOUT = cfg.calibBrakeTimeout or 12.0 -- s: max time for the brake run
local CALIB_SETTLE       = cfg.calibSettle       or 0.5   -- s: output settle before sampling
local CALIB_STOP         = 0.3   -- m/s: treated as stopped
local CALIB_FILE         = "calib.json"

-- ============================================================
-- 0b. Simurail physics bogey peripheral (drive/brake/signal via CC)
-- ============================================================
-- If useBogeyPeripheral is enabled and a Simurail_PhysicsBogey peripheral is
-- reachable (attached or on a wired/wireless network), drive/brake/reverse
-- are sent to the bogey peripheral instead of the redstone output sides.
-- The red signal ahead ALWAYS comes from the sideRedSignal redstone input:
-- the bogey probe path was tried and removed (not reliably readable).
-- The redstone sides remain as failback.
local USE_BOGEY     = cfg.useBogeyPeripheral ~= false
local DRIVE_STRESS_MAX = cfg.bogeyDriveMax or 128   -- drive stress range +/-128
local bogeys        = {}     -- all reachable Simurail_PhysicsBogey peripherals
local bCallWarned   = false
local lastSentStress = {}   -- per-bogey: last drive stress sent (change-only)
local lastSentBrake  = {}   -- per-bogey: last brake strength sent (change-only)

if USE_BOGEY then
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
        print("WARNING: useBogeyPeripheral=true but no Simurail_PhysicsBogey found - falling back to redstone sides")
    end
end

-- Call one bogey peripheral method; returns ok. Callers fail back to the
-- redstone sides when every bogey call fails or none exist.
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
local redLatch      = false   -- red input at 15 latches full brake until handle EB
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
-- Legacy redstone mode maps back to the 0-15 analog scale.
-- Bogey mode only calls the (mainThread) peripheral when the value actually
-- changed, so the loop never blocks on per-tick peripheral tasks.
local revSign = 1   -- bogey mode: sign applied to the drive stress (reverse)
local function setBrake(level)
    local out = math.max(0, math.min(1, level))
    if USE_BOGEY then
        local sent = #bogeys > 0
        for _, p in ipairs(bogeys) do
            local last = lastSentBrake[p]
            if last == nil or math.abs(out - last) >= 0.01 then
                lastSentBrake[p] = out
                if not bCallOne(p, "setBrakeStrengthOverride", out) then
                    sent = false
                end
            end
        end
        if sent then return end
    end
    if SIDE_BRAKE then
        redstone.setAnalogOutput(SIDE_BRAKE, math.ceil(out * 15))
    end
end

-- Set reverse gearbox (digital HIGH = activate). Bogey mode: the reverse sign
-- is remembered here and applied to the drive stress (negative = reverse).
local function setReverseGearbox(activate)
    revSign = activate and -1 or 1
    if not USE_BOGEY and SIDE_REVGEARBOX then
        redstone.setOutput(SIDE_REVGEARBOX, activate)
    end
end

-- Set throttle output; throttleInput is drive stress 0..DRIVE_STRESS_MAX (bogey
-- setMaxStress). revSign picks the direction. Bogey mode needs kinetic RPM
-- (getSpeed) to produce force, so the gearbox redstone is held at full throttle
-- (0 after inversion) to keep the RPM source alive. Legacy redstone mode maps
-- back to the 0-15 analog scale.
local function setThrottleOutput(throttleInput)
    if USE_BOGEY then
        local out = math.max(0, math.min(DRIVE_STRESS_MAX, throttleInput))
        local sent = #bogeys > 0
        for _, p in ipairs(bogeys) do
            local last = lastSentStress[p]
            if last == nil or math.abs(out - last) >= 1 then
                lastSentStress[p] = out
                if not bCallOne(p, "setMaxStress", revSign * out) then
                    sent = false
                end
            end
        end
        if sent then
            if SIDE_THROTTLE then
                redstone.setAnalogOutput(SIDE_THROTTLE, 0)   -- keep gearbox RPM source fed
            end
            return
        end
    end
    if SIDE_THROTTLE then
        redstone.setAnalogOutput(SIDE_THROTTLE, 15 - math.ceil(throttleInput / DRIVE_STRESS_MAX * 15))
    end
end

-- ============================================================
-- 2. RHI notch mapping (master side)
-- ============================================================
-- Notch mapping (RHI handle):
--   0    : EB  - emergency brake, brake output 15, set speed = 0
--   1-9  : B9..B1 - direct brake output 10-sig (sig 1 -> brake 9, sig 9 -> brake 1), set speed = 0
--   10   : N   - neutral, no traction, no brake (coast)
--   11   : K1  - decrease set speed 5 km/h per second
--   12   : K2  - decrease set speed 1 km/h per second
--   13   : C   - keep set speed unchanged
--   14   : K3  - increase set speed 1 km/h per second
--   15   : K4  - increase set speed 5 km/h per second
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

-- Call each loop; updates rhi_setSpeed, notchLevel and mode flags from current notch signal
local function updateRHI(dt)
    local sig = redstone.getAnalogInput(SIDE_SETSPEED)

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
-- most MAX_OUT_DELTA units (0-15) per loop tick, so force never jumps.
-- EB / B / N / fault states still switch instantly.
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

if monitor then
    -- Shrink text so more info fits on a 1x1 monitor
    mCall("setTextScale", 0.5)
    mCall("setBackgroundColor", colors.black)
    mCall("clear")
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

-- updateDisplay(setSpeed, actualSpeed, driveOut, brakeOut, reverse, level, role, fault, redActive)
local function updateDisplay(setSpeed, actualSpeed, driveOut, brakeOut, reverse, level, role, fault, redActive)
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

    -- Line 7: Time + BRK / RED indicators
    mCall("setCursorPos", 1, 7)
    mCall("setTextColor", colors.lightGray)
    monitor.write(os.date("%H:%M:%S") .. (brakeOut > 0 and " BRK" or "") .. (redActive and " RED" or "") .. (visualDriving and " VIS" or "") .. (redLatch and " LAT" or "") .. (calibArmed and " ARM" or ""))

    -- Line 8: Role + notch level, or network fault
    mCall("setCursorPos", 1, 8)
    if fault then
        mCall("setTextColor", colors.red)
        monitor.write("** FAULT EB **")
    else
        mCall("setTextColor", colors.white)
        monitor.write((role == "master" and "M:" or "S:") .. (level or "?"))
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
local CHAN_BROADCAST = 65535
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

-- Pull events unfiltered so nothing is discarded: rednet messages arrive
-- either as rednet_message (from the rednet background) or modem_message
-- (direct) - handle BOTH; keyboard char/key events drive commands; the
-- timer bounds the wait and paces the loop. This replaces rednet.receive
-- and sleep(), neither of which can coexist with live keyboard input.
-- Returns sender, msg, protocol, or nil on timeout.
local function receiveWithInput(timeout)
    local timer = os.startTimer(timeout)
    while true do
        local ev, p1, p2, p3, p4 = os.pullEvent()
        if ev == "terminate" then
            error("Terminated", 0)
        elseif ev == "timer" then
            if p1 == timer then return nil end
        elseif ev == "char" then
            cmdBuffer = cmdBuffer .. p1
        elseif ev == "key" then
            handleKey(p1)
        elseif ev == "rednet_message" then
            -- background-converted message: senderID, message, protocol
            return p1, p2, p3
        elseif ev == "modem_message" then
            -- direct modem message (same wire format as rednet)
            local channel, replyChannel, message = p2, p3, p4
            if channel == CHAN_BROADCAST or channel == selfID then
                local ok, data = pcall(textutils.unserialize, message)
                if ok and type(data) == "table" then
                    return replyChannel, data.nMessage, data.nProtocol
                end
            end
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

local calibAccelRate, calibBrakeRate = nil, nil

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
    return (n * sTV - sT * sV) / den   -- least-squares slope = m/s^2
end

local function saveCalib()
    local data = {
        version = 1,
        savedAt = os.date("%Y-%m-%dT%H:%M:%S"),
        accel = { mps2 = math.floor(calibAccelRate * 1000 + 0.5) / 1000 },
        brake = { mps2 = math.floor(calibBrakeRate * 1000 + 0.5) / 1000 },
        brakeTargetMps = CALIB_BRAKE_TARGET,
    }
    local f = fs.open(CALIB_FILE, "w")
    if not f then return false end
    f.write(textutils.serializeJSON(data, true))
    f.close()
    return true
end

-- Advance the calibration state machine. Returns drive, brake, next (nil = end).
local function calibStep(c, dt, v, now)
    if c.step == "accel_warmup" then
        -- Full throttle on; wait CALIB_SETTLE so the output has taken effect
        if now - c.t0 >= CALIB_SETTLE then
            c.step, c.t0, c.samples = "accel_meas", now, {}
        end
        return DRIVE_STRESS_MAX, 0, c
    elseif c.step == "accel_meas" then
        c.samples[#c.samples + 1] = { t = now - c.t0, v = v }
        if now - c.t0 >= CALIB_ACCEL_DUR then
            local a = calibFit(c.samples)
            if a then
                calibAccelRate = a
                print(string.format("CALIB accel: %.3f m/s^2 (%.1f km/h/s, %d samples)", a, a * 3.6, #c.samples))
                c.step, c.t0 = "run_up", now
            else
                print("CALIB FAILED: accel fit invalid (need >= 5 samples)")
                return 0, 1.0, nil
            end
        end
        return DRIVE_STRESS_MAX, 0, c
    elseif c.step == "run_up" then
        -- Full throttle until the brake-test cruise speed
        if v >= CALIB_BRAKE_TARGET then
            c.step, c.t0, c.samples = "brake_settle", now, {}
        elseif now - c.t0 > CALIB_RUN_TIMEOUT then
            print("CALIB FAILED: could not reach " .. string.format("%.0f", CALIB_BRAKE_TARGET * 3.6) .. " km/h")
            return 0, 1.0, nil
        end
        return DRIVE_STRESS_MAX, 0, c
    elseif c.step == "brake_settle" then
        -- Coast a moment, then slam the brake with a stable output
        if now - c.t0 >= CALIB_SETTLE then
            c.step, c.t0, c.samples = "brake_meas", now, {}
        end
        return 0, 0, c
    elseif c.step == "brake_meas" then
        c.samples[#c.samples + 1] = { t = now - c.t0, v = v }
        local stopped = v <= CALIB_STOP
        if stopped or now - c.t0 >= CALIB_BRAKE_TIMEOUT then
            local b = calibFit(c.samples)
            if b and b > 0 then
                calibBrakeRate = b
                print(string.format("CALIB brake: %.3f m/s^2 (%.1f km/h/s, %d samples)", b, b * 3.6, #c.samples))
                local ok = saveCalib()
                print(ok and ("CALIB: saved to " .. CALIB_FILE) or ("CALIB: FAILED to write " .. CALIB_FILE))
            else
                print("CALIB FAILED: brake fit invalid" .. (stopped and "" or " (timeout)"))
            end
            return 0, 1.0, nil
        end
        return 0, 1.0, c
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

local function startCalibration(role, fault, redLevel, actualSpeed)
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
    if redLevel > 0 and not visualDriving then
        refuse("red signal ahead - cannot calibrate")
        return
    end
    calib = { step = "accel_warmup", phase = "accel", t0 = os.clock(), dur = CALIB_SETTLE }
    calibHold = false
    calibArmed = false
    lastRefuse = ""
    calibAccelRate, calibBrakeRate = nil, nil
    print("CALIB: running - full throttle " .. CALIB_ACCEL_DUR .. "s, then brake test from " ..
        string.format("%.0f", CALIB_BRAKE_TARGET * 3.6) .. " km/h")
end

-- ============================================================
-- 8. Main loop
-- ============================================================
print("Locomotive program started: " .. locoName)
print("Max speed: " .. MAX_SPEED .. " m/s | Ctrl+T to stop")
print("Commands: VisualDriving (vd) | Calibrate (calib) | help")

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

    -- Red signal ahead (analog, 0=clear, 1-15=red, higher=closer) from the
    -- sideRedSignal redstone input. Only the master evaluates it, and only
    -- when going forward: in reverse the front signal is behind the travel
    -- direction, so it must not protect (driver backs by sight). Slaves
    -- follow the broadcast ctrl and must not react to the same red input the
    -- master is already handling.
    local redLevel = 0
    if role == "master" and not masterReverse then
        redLevel = redstone.getAnalogInput(SIDE_RED) or 0
    end
    -- Protection only applies when going forward: in reverse the front
    -- signal is behind the travel direction, so it must not brake.
    -- Visual driving also exempts the red-signal brake.
    local redActive = redLevel > 0 and not masterReverse and not visualDriving
    if leverSig ~= prevLeverSig then
        print("Lever: " .. leverSig .. " -> " .. role .. (masterReverse and " REV" or ""))
        prevLeverSig = leverSig
    end

    -- Collect statuses, master control and keyboard commands. Unfiltered
    -- event dispatch (receiveWithInput) so nothing is discarded; protocol
    -- isolation is done in code below (and foreign traffic logged once).
    -- The blocking wait also paces the loop (no sleep(), which would eat
    -- modem events and break reception).
    local sender, msg, proto
    if netUp then
        sender, msg, proto = receiveWithInput(PID_DT)
        if sender and proto ~= MU_PROTOCOL then
            if not foreignWarned then
                foreignWarned = true
                print("Foreign protocol '" .. tostring(proto) .. "' ignored (ours '" .. MU_PROTOCOL .. "')")
            end
            msg = nil
        end
    else
        sleep(PID_DT)   -- no modem: just pace the loop
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
        startCalibration(role, fault, redLevel, actualSpeed)
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
        if redActive or not sensor then
            print("CALIB ABORTED: " .. (not sensor and "velocity sensor lost" or "red signal ahead"))
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
        broadcastState("master", {
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
        updateRHI(dt)
        setSpeed = getSetSpeed()
        -- Visual driving caps the allowed set speed (red signals ignored)
        if visualDriving and setSpeed > VISUAL_MAX then
            setSpeed = VISUAL_MAX
        end
        -- Red latch: red input at 15 (at the signal) holds full brake and
        -- zeroes the set speed. The driver must pull the RHI handle to EB
        -- (signal 0) to acknowledge and release the latch. Exempt in visual
        -- driving mode.
        local handleSig = redstone.getAnalogInput(SIDE_SETSPEED) or 0
        if redLatch and handleSig == 0 then
            redLatch = false
        end
        if redLevel >= 15 and not masterReverse and not visualDriving then
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
        elseif redActive then
            -- Red signal ahead (forward only): cut traction, brake strength = proximity
            driveOut, brakeOut = 0, math.min(1, redLevel / 15)
            lastDriveOut, lastBrakeOut = 0, brakeOut
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
        updateDisplay(setSpeed, actualSpeed, driveOut, brakeOut, revOut, level, role, fault, redActive)
    end
end
