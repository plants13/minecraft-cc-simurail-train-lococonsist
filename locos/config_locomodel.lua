-- config_swd1p.lua
-- Locomotive configuration file for SWD1P
-- Edit this file to change locomotive parameters

return {
    -- Maximum operating speed (m/s)
    -- Maps redstone signal 15 -> this speed, signal 0 -> 0 (stop)
    maxSpeed = 50.0,

    -- ---- Redstone I/O sides ----
    -- INPUT sides
    sideSetSpeed  = "top",    -- analog INPUT:  speed setpoint (0-15)
    sideReverse   = "right",  -- analog INPUT: mode lever 0-4 fwd / 5-10 neutral / 11-15 rev
    sideRedSignal = "front",  -- analog INPUT: red signal ahead (0=clear, 1-15=red, higher=closer)

    -- OUTPUT / peripheral (bogey mode drives via the Simurail CC peripheral,
    -- so the legacy redstone output sides are omitted. sideThrottle used to
    -- feed the gearbox RPM: if you remove it, feed the gearbox from a
    -- constant redstone source instead or the train will not drive).
    sideMonitor   = "left",   -- monitor peripheral side
    sideModem     = "front",  -- wireless modem side (rednet)

    -- ---- Visual driving mode ----
    -- Toggled at runtime with the "VisualDriving" command (case-insensitive).
    -- Caps the set speed at visualMaxSpeed and allows passing red signals.
    visualMaxSpeed = 10.0,   -- m/s (= 36 km/h)

    -- ---- Control loop interval (s) ----
    -- Loop cadence (the rednet.receive timeout drives it). 0.05 s = 20 Hz,
    -- finer than the 10 Hz redstone tick which still helps smoothness.
    -- K-rates and PID use measured dt, so this only changes responsiveness,
    -- not the 5/1 km/h/s set-speed rates.
    pidDt = 0.05,

    -- ---- Unified PID (single controller for both throttle and brake) ----
    -- Positive output [0,15]  -> throttle (drive)
    -- Negative output [-15,0] -> brake    (decelerate)
    -- This prevents throttle/brake fighting and eliminates oscillation at setpoint.

    -- Unified PID output is in drive-stress units 0..128 (bogey setMaxStress)
    -- with brake as strength 0..1 (bogey setBrakeStrength). Gains below were
    -- rescaled from the old 0..15 scale by x8.533 (128/15) - keep the ratio.
    pidKi = 4.3,                   -- integral (0..128 scale; old 0.5 x8.53)
    pidKd = 4.3,                   -- derivative (0..128 scale; old 0.5 x8.53)
    pidKpNear = 6.8, pidKpMid = 10.2, pidKpFar = 21.3,   -- gain zones (0..128 scale)
    pidKpFar  = 2.5,    -- Kp when error is large  (aggressive catch-up)
    nearThreshold = 0.8, -- m/s: boundary between near and mid zones
    farThreshold  = 5.0, -- m/s: boundary between mid and far zones

    -- ---- Deadband ----
    -- If |error| < deadband, integral is frozen and output is zero.
    -- Prevents micro-corrections and throttle/brake toggling at setpoint.
    -- Set to 0 to disable.
    pidDeadband = 0.15, -- m/s

    -- ---- No-brake window ----
    -- When slightly over setpoint (overspeed < noBrakeWindow), coast instead of
    -- braking: throttle 0, brake 0, integral frozen. Avoids brake-tapping when
    -- barely overshooting the target speed.
    -- Larger -> more coasting, looser speed holding. Smaller -> tighter but brakes more.
    noBrakeWindow = 0.5, -- m/s

    -- ---- Output ramp (smooth transitions) ----
    -- In constant-speed mode (C / K1..K4), throttle and brake outputs ramp toward
    -- the PID target at most this many units (0-15 scale) per loop tick.
    -- Lower -> smoother but slower force changes. Higher -> snappier.
    -- EB / B / N modes switch instantly (not ramped).
    maxOutputDelta = 17.0,         -- stress change limit per 0.1s (0..128 scale; old 2.0 x8.53, full sweep ~0.75s)

    -- ---- Brake output scale ----
    -- Caps the brake strength (0..1) at this fraction of the full PID drive:
    -- full drive output produces brakeScale braking. 0.2 = max 20% brake.
    brakeScale = 0.2,

    -- ---- Emergency brake ----
    -- When setSpeed == 0, apply brake strength = emergencyBrakeKp * speed * brakeScale.
    -- Independent of PID; acts immediately without integral windup.
    emergencyBrakeKp = 0.1,        -- per m/s (0..1 brake scale; old 1.5 /15)

    -- ---- Performance calibration (runtime "Calibrate" / "calib" command) ----
    -- Runs a full-throttle accel run, then a full-brake run from a cruise
    -- speed, fits velocity samples to get real m/s^2 rates, saved to
    -- calib.json on this computer for future automatic train control (LKJ).
    calibAccelDur     = 3.0,   -- s: full-throttle accel measurement window
    calibBrakeTarget  = 10.0,  -- m/s: cruise speed before the brake run (36 km/h)
    calibRunTimeout   = 20.0,  -- s: max time to reach the brake-run cruise speed
    calibBrakeTimeout = 12.0,  -- s: max time for the brake run (stops early if faster)
    calibSettle       = 0.5,   -- s: output settle time before sampling starts

    -- ---- Simurail bogey peripheral output (drive/brake via CC) ----
    -- When enabled and a Simurail_PhysicsBogey peripheral is reachable
    -- (attached or on a wired network), drive/brake/reverse are sent to the
    -- bogey peripheral instead of the redstone output sides. The red signal
    -- ahead always comes from sideRedSignal (the bogey probe path was tried
    -- and removed). Falls back to the redstone sides if no bogey peripheral.
    useBogeyPeripheral = true,   -- false = legacy redstone-only mode
    bogeyDriveMax = 128.0,       -- drive stress range: throttle 0-15 maps to +/-128 (kinetic stress draw)
}
