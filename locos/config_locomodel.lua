-- config_locomodel.lua
-- Generic locomotive configuration file (one per locomotive).
-- Edit this file to change locomotive parameters.
-- The file name is up to you: startup.lua loads it with
--   local cfg = dofile("config_locomodel.lua")
-- so keep that line in sync if you rename this file.

return {
    -- ---- Maximum operating speed (m/s) ----
    maxSpeed = 50.0,

    -- ---- Input sides ----
    sideSetSpeed  = "top",    -- analog INPUT:  speed setpoint (0-15)
    sideReverse   = "right",  -- analog INPUT: mode lever 0-4 fwd / 5-10 neutral / 11-15 rev

    -- OUTPUT / peripheral (drive, brake and direction all go to the Simurail
    -- CC peripheral; the legacy redstone output sides are gone for good).
    -- sideThrottle used to feed the gearbox RPM: feed the gearbox from a
    -- constant redstone source (torch/lever) or the train will not drive.
    sideMonitor   = "left",   -- monitor peripheral side
    sideModem     = "front",  -- wireless modem side (rednet)

    -- ---- Visual driving mode ----
    -- Toggled at runtime with the "VisualDriving" command (case-insensitive).
    -- Caps the set speed at visualMaxSpeed and allows passing red signals.
    visualMaxSpeed = 10.0,   -- m/s (= 36 km/h)

    -- ---- Red-signal protection (Simurail bogey probe) ----
    -- The bogey probe reports the distance (blocks, measured along the track)
    -- to the nearest signal boundary that is RED FOR US: forced red, or its
    -- block occupied by a consist group other than ours. There is NO approach
    -- braking: the train drives normally until the red is inside
    -- redEbDistance blocks, which means the axle has effectively reached the
    -- signal -> EB latch (full brake, set speed zero, cleared by pulling the
    -- RHI handle to EB).
    -- Which axle the probe is read from is FIXED (not travel-relative):
    --   true/nil  = bogey front axle (axleFront)   <- default
    --   false     = bogey back axle  (axleBack)
    -- The axle looks out of ITS OWN end of the bogey, so this must be the end
    -- that points in the direction of travel. If the protection trips for a
    -- signal behind the train (or ignores one ahead), flip this flag.
    -- Verify with `lua bogey_probe.lua`, which prints both axles' probe data
    -- and track direction vectors.
    redProbeFront    = true,   -- true = front axle (default)
    redProbeWindow   = 128.0,  -- blocks: probe scan length forced onto every bogey
    redEbDistance    = 4.0,    -- blocks: red closer than this -> EB latch

    -- ---- Control loop interval (s) ----
    -- Loop cadence (the rednet.receive timeout drives it). 0.05 s = 20 Hz,
    -- finer than the 10 Hz redstone tick which still helps smoothness.
    -- K-rates and PID use measured dt, so this only changes responsiveness,
    -- not the 5/1 km/h/s set-speed rates.
    pidDt = 0.05,

    -- ---- Unified PID (single controller for both throttle and brake) ----
    -- Positive output [0,128] -> drive stress (throttle)
    -- Negative output         -> brake strength (0..1) (decelerate)
    -- This prevents throttle/brake fighting and eliminates oscillation at setpoint.

    -- Unified PID output is in drive-stress units 0..128 (bogey setMaxStress)
    -- with brake as strength 0..1 (bogey setBrakeStrength). Gains below were
    -- rescaled from the old 0..15 scale by x8.533 (128/15) - keep the ratio.
    pidKi = 4.3,                   -- integral (0..128 scale; old 0.5 x8.53)
    pidKd = 4.3,                   -- derivative (0..128 scale; old 0.5 x8.53)
    -- Gain zones (0..128 scale). The far gain is deliberately the most
    -- aggressive one: a large speed error must command a large drive stress.
    -- (A duplicate pidKpFar = 2.5 line used to override the 21.3 below,
    -- left over from the old 0..15 scale - do not reintroduce it.)
    pidKpNear = 6.8, pidKpMid = 10.2, pidKpFar = 21.3,
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
    -- the PID target at most this many stress units (0..128 scale) per 0.1 s.
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
    -- Profile: full throttle until the top speed is found - the speed stops
    -- gaining more than calibPlateauEps for calibPlateauTime (it hovers around
    -- a value) - or MAX_SPEED (maxSpeed above, the set-speed ceiling) is
    -- reached, whichever is lower. Then it coasts briefly and brakes at
    -- calibBrakeStrength down to a standstill. Velocity samples are fitted to
    -- get real m/s^2 rates, saved to calib.json (also used by the red-signal
    -- stop curve; the full-brake rate is extrapolated from the measured one).
    calibAccelDur       = 3.0,   -- s: full-throttle accel measurement window
    calibBrakeStrength  = 0.5,   -- brake strength used for the brake run (0.5 = 50%)
    calibPlateauTime    = 2.0,   -- s without a speed gain -> top speed reached
    calibPlateauEps     = 0.1,   -- m/s: a gain above this counts as progress
    calibMinTopSpeed    = 5.0,   -- m/s: top speed below this -> run failed (18 km/h)
    calibStartClearance = 64.0,  -- blocks: clear track (no red) needed to start
    calibRunTimeout     = 120.0, -- s: safety net for the climb (plateau ends it)
    calibBrakeTimeout   = 60.0,  -- s: floor for the brake run (scaled by top speed)
    calibSettle         = 0.5,   -- s: output settle time before sampling starts

    -- ---- Simurail bogey peripheral output (drive/brake/reverse via CC) ----
    -- Mandatory: a Simurail_PhysicsBogey peripheral must be reachable
    -- (attached directly or on a wired network). There is NO redstone output
    -- fallback any more - drive, brake and direction all go to the bogey
    -- peripheral. The red signal ahead comes from the bogey probe (see the
    -- redProbe* settings above), not from a redstone input.
    bogeyDriveMax = 128.0,       -- drive stress range: PID output 0..128 -> setMaxStress +/-128 (kinetic stress draw)

    -- ---- Overstress guard (optional Create_Stressometer peripheral) ----
    -- The drive strength (setMaxStress) IS the kinetic stress draw, so a drive
    -- command above the network's capacity makes Create mark the network
    -- overstressed: getSpeed() returns 0 and the bogeys lose ALL traction.
    -- When a stressometer reports used > capacity the script snaps the drive
    -- ceiling down by capacity/used, holds it, then releases it slowly - only
    -- while the network sits inside a wide safe band. The band matters: the
    -- stressometer reading lags the command, and a narrow release band makes
    -- the guard pump itself and the train stutter. No stressometer peripheral
    -- -> the whole guard is inactive.
    stressGuardMargin       = 0.95,  -- cut the drive to this fraction of capacity
    stressGuardReleaseRatio = 0.85,  -- release the cap only while used/capacity < this
    stressGuardRelease      = 8.0,   -- cap recovery rate (units/s on the 0..128 scale)
    stressGuardCalibAbort   = true,  -- abort a calibration run if the guard clamps (traction not full)
}
