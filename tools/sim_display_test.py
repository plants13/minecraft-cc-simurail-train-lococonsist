"""Smoke test for the cab features (lupa = embedded Lua 5.1).

Runs the REAL locos/startup.lua against a mocked CC:Tweaked environment, so
nil-handling / wrong-field / dead-branch bugs that luaparse cannot see show up
before the script ever reaches a computer:

  A) displayMode = true   -> terminal only draws, never touches outputs
  B) displayMode = false  -> driver path, publishes snapshots on <mu>-disp,
                             silently drops incoming display traffic
  C) displayInterval = false -> publishing can be switched off
  D) displayMode + linked_typewriter -> desk keys latch a notch, a held A/D
                             becomes a steer request, SPACE bumps the ack
  E) loco + "Manual"      -> the desk notch replaces the lever, A/D writes the
                             steer override, the display snapshot follows
  F) loco, desk silent    -> link timeout fails safe (traction cut + EB)
  G) loco, vigilance on   -> no SPACE for vigilancePeriod cuts traction and
                             applies the service brake

Usage (needs lupa, which bundles Lua 5.1 - same generation as CC's Cobalt):
    python -m pip install --only-binary :all: lupa
    python tools/sim_display_test.py

Run from the repository root; exits non-zero on any failed assertion.
"""
import sys
import lupa
from lupa.lua51 import LuaRuntime

PRELUDE = r'''
-- ---- CC:Tweaked mock environment (only what startup.lua touches) ----
colors = {
    white = 1, orange = 2, magenta = 4, lightBlue = 8, yellow = 16, lime = 32,
    pink = 64, gray = 128, lightGray = 256, cyan = 512, purple = 1024, blue = 2048,
    brown = 4096, green = 8192, red = 16384, black = 32768,
}
-- GLFW key codes, same values CC uses in the keys table
keys = {
    enter = 257, backspace = 259, tab = 258,
    w = 87, s = 83, a = 65, d = 68, space = 32,
    leftShift = 340, rightShift = 344,
}

__written = {}
local function sink(fmt, ...) __py_log(string.format(fmt, ...)) end
monitor = {
    clear = function() sink("clear") end,
    setCursorPos = function(x, y) sink("pos:%d,%d", x, y) end,
    setTextColor = function(c) sink("color:%d", c) end,
    setTextScale = function(s) sink("scale:%s", tostring(s)) end,
    setBackgroundColor = function(c) sink("bg:%d", c) end,
    write = function(s) sink("write:%s", tostring(s)) end,
    getSize = function() return 29, 10 end,
}
peripheral = {
    getNames = function() return __py_periph_names() end,
    getType = function(name) return __py_periph_type(name) end,
    wrap = function(name) return __py_wrap(name) end,
    call = function() return nil end,
}
redstone = { getAnalogInput = function(side) return __py_analog(side) end }
fs = {
    exists = function(p) return __py_fs_exists(p) end,
    open = function(p, mode)
        if mode == "r" then
            local text = __py_fs_read(p)
            if text == nil then return nil end
            local pos = 1
            return {
                readAll = function() return text end,
                readLine = function()
                    if pos > #text then return nil end
                    local nl = string.find(text, "\n", pos, true) or (#text + 1)
                    local line = string.sub(text, pos, nl - 1)
                    pos = nl + 1
                    return line
                end,
                close = function() end,
            }
        elseif mode == "w" then
            local buf = {}
            return {
                write = function(s) buf[#buf + 1] = tostring(s) end,
                writeLine = function(s) buf[#buf + 1] = tostring(s) .. "\n" end,
                close = function() __py_fs_write(p, table.concat(buf)) end,
            }
        end
        return nil
    end,
    delete = function(p) __py_fs_delete(p) end,
    list = function(p) return nil end,
}
-- Just enough JSON for the state file the script writes: a flat table of
-- booleans/numbers/strings. Corrupt input yields an empty table, which the
-- script treats as "no persisted state".
textutils = {
    serializeJSON = function(t, pretty)
        local parts = {}
        for k, v in pairs(t) do
            local enc = tostring(v)
            if type(v) == "string" then enc = '"' .. v .. '"' end
            parts[#parts + 1] = '"' .. tostring(k) .. '":' .. enc
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end,
    unserializeJSON = function(s)
        local out = {}
        local k, v = string.match(tostring(s), '"([%w_]+)"%s*:%s*"([^"]*)"')
        if k then out[k] = v end
        local bk, bv = string.match(tostring(s), '"([%w_]+)"%s*:%s*(%a+)')
        if bk and bv == "true" then out[bk] = true end
        if bk and bv == "false" then out[bk] = false end
        return out
    end,
}
rednet = {
    open = function(side) return true end,
    close = function(side) end,
    broadcast = function(msg, protocol) __py_broadcast(msg, protocol) end,
    receive = function(protocol, timeout) return nil end,
    CHANNEL_BROADCAST = 65535,
}
os.startTimer = function(t) return __py_startTimer(t) end
os.pullEvent = function() return __py_pullEvent() end
os.clock = function() return __py_clock() end
os.getComputerLabel = function() return __py_label() end
os.getComputerID = function() return __py_id() end
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    __py_print(table.concat(parts, " "))
end
dofile = function(name)
    if name == "config_locomodel.lua" then return __cfg end
    error("mock: no file " .. tostring(name))
end
'''


class Stop(Exception):
    pass


class Harness:
    def __init__(self, display_mode, protocol="TEST-MU", bogeys=0, typewriter=False):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.logs = []
        self.prints = []
        self.broadcasts = []
        self.events = []
        self.calls = []              # (peripheral method, args) from the bogey mock
        self.files = {}              # mock filesystem: path -> text
        self.clock = 100.0
        self.timer_id = 0
        self.analog = {"top": 0, "right": 0, "left": 0, "front": 0, "back": 0}
        self.display_mode = display_mode
        self.periph_names = []
        self.periph_types = {}
        if bogeys:
            self.periph_names.append("bog1")
            self.periph_types["bog1"] = "Simurail_PhysicsBogey"
        if typewriter:
            self.periph_names.append("tw1")
            self.periph_types["tw1"] = "linked_typewriter"
        g = self.lua.globals()
        for name, fn in [
            ("__py_log", self.logs.append),
            ("__py_print", self.prints.append),
            ("__py_broadcast", self.on_broadcast),
            ("__py_startTimer", self.on_timer),
            ("__py_pullEvent", self.pull_event),
            ("__py_clock", lambda: self.clock),
            ("__py_label", lambda: "CAB1" if display_mode else "LOCO1"),
            ("__py_id", lambda: 7 if display_mode else 3),
            ("__py_analog", lambda side: self.analog.get(side, 0)),
            ("__py_periph_names", self.on_periph_names),
            ("__py_periph_type", lambda name: self.periph_types.get(name)),
            ("__py_wrap", self.on_wrap),
            ("__py_fs_exists", lambda p: p in self.files),
            ("__py_fs_read", lambda p: self.files.get(p)),
            ("__py_fs_write", self.on_fs_write),
            ("__py_fs_delete", lambda p: self.files.pop(p, None) and None),
        ]:
            g[name] = fn
        self.lua.execute(PRELUDE)
        # A permissive bogey: every method exists, calls are recorded, getters
        # answer nil (the script type-checks probe results).
        make = self.lua.eval(
            "function(cb) return setmetatable({}, {__index = function(t, m) "
            "return function(...) return cb(m, ...) end end}) end")
        self.bogey_tbl = make(self.on_bogey)
        self.tw_tbl = self.lua.table()
        cfg = self.lua.table(
            displayMode=display_mode,
            sideSetSpeed="top", sideReverse="right", sideMonitor="left",
            sideModem="front", maxSpeed=50.0, visualMaxSpeed=10.0,
            bogeyDriveMax=128.0, pidDt=0.05,
            calibAccelDur=3.0, calibBrakeStrength=0.5, calibPlateauTime=2.0,
            calibPlateauEps=0.1, calibMinTopSpeed=5.0, calibStartClearance=64.0,
            calibRunTimeout=120.0, calibBrakeTimeout=60.0, calibSettle=0.5,
            displayInterval=0.25, displayStale=2.0,
            manualTimeout=2.5, manualHoldSpeedOnLoss=True,
            vigilanceEnabled=False, vigilancePeriod=30.0, vigilanceGrace=15.0,
            vigilanceBrake=0.5,
            # controller tuning: only reached once the PID path is exercised
            brakeScale=1.0, pidDeadband=0.05, noBrakeWindow=0.2,
            pidKpNear=6.8, pidKpMid=10.2, pidKpFar=21.3,
            pidKi=4.3, pidKd=4.3, nearThreshold=0.8, farThreshold=5.0,
            maxOutputDelta=17.0, emergencyBrakeKp=0.1,
            redProbeFront=True, redProbeWindow=128.0, redEbDistance=4.0,
            stressGuardMargin=0.95, stressGuardReleaseRatio=0.85,
            stressGuardRelease=8.0, stressGuardCalibAbort=True,
            slipGuardEnabled=False, slipGuardRatio=0.45, slipGuardMinSpeed=2.0,
            slipGuardMinStress=24.0, slipGuardCut=0.55, slipGuardFloor=32.0,
            slipGuardRelease=10.0, slipGuardHold=0.4, slipGuardFilter=0.30,
        )
        g["__cfg"] = cfg
        g["__mu"] = self.lua.table(protocol=protocol)
        # mu_config: pcall(dofile, ...) -> our dofile errors for it, so patch it
        g.dofile = self.lua.eval(
            "function(name) if name == 'config_locomodel.lua' then return __cfg "
            "elseif name == 'mu_config.lua' then return __mu end "
            "error('mock: no file ' .. tostring(name)) end")

    # ---- mock callbacks ----
    def on_broadcast(self, msg, protocol):
        self.broadcasts.append((protocol, msg))

    def on_periph_names(self):
        t = self.lua.table()
        for i, n in enumerate(self.periph_names, 1):
            t[i] = n
        return t

    def on_wrap(self, name):
        if name == "bog1":
            return self.bogey_tbl
        if name == "tw1":
            return self.tw_tbl
        if name == "left":
            return self.lua.globals().monitor
        return None

    def on_bogey(self, method, *args):
        self.calls.append((method, args))
        return None

    def on_fs_write(self, path, text):
        self.files[path] = text
        return True

    def bogey_values(self, method):
        return [a[0] for (m, a) in self.calls if m == method and a]

    def on_timer(self, seconds):
        self.timer_id += 1
        return self.timer_id

    def pull_event(self):
        if not self.events:
            raise Stop("no more scripted events")
        ev = self.events.pop(0)
        if isinstance(ev[-1], float):
            self.clock += ev[-1]
            ev = ev[:-1]
        return tuple(ev)

    def run(self, events):
        self.events = list(events)
        src = open("locos/startup.lua", encoding="utf-8").read()
        try:
            self.lua.execute(src)
        except Stop:
            pass                       # scripted event list exhausted
        except lupa.lua51.LuaError as e:
            if "Terminated" not in str(e) and "Stop" not in str(e):
                raise                  # a real Lua error in the script
        return self

    def display_broadcasts(self):
        return [m for (p, m) in self.broadcasts if p == "TEST-MU-disp"]

    def manual_broadcasts(self):
        return [m for (p, m) in self.broadcasts if p == "TEST-MU-manual"]


def snapshot(lua, **fields):
    t = lua.table()
    for k, v in fields.items():
        t[k] = v
    return t


def desk_packet(lua, notch, steer, ack, consist="TEST-MU"):
    return snapshot(lua, desk=True, label="CAB1", consist=consist,
                    notch=notch, steer=steer, ack=ack)


def type_command(h, cmd):
    """Feed a terminal command the way CC delivers it: char events + Enter."""
    evs = [("char", ch, 0.01) for ch in cmd]
    evs.append(("key", 257, 0.01))      # keys.enter
    return evs


def report(title, checks):
    print("\n" + title)
    ok = True
    for name, good in checks:
        print(("   PASS  " if good else "   FAIL  ") + name)
        ok = ok and good
    return ok


def main():
    ok = True

    # ---------- A) display terminal ----------
    h = Harness(display_mode=True)
    snap = snapshot(
        h.lua, role="master", label="LOCO1", setSpeed=10.0, speed=8.0,
        throttle=64, brake=0.0, reverse=False, level="C", fault=False,
        redDist=42, maxSpeed=50.0)
    h.run([
        ("rednet_message", 3, snap, "TEST-MU-disp", 0.30),
        ("timer", 1, 0.30),          # draws the live snapshot
        ("timer", 2, 3.00),          # 3 s later -> LINK LOST
        ("terminate", 0.0),
    ])
    ok = report("A) display terminal", [
        ("terminal started on derived protocol",
         any("Display terminal started: protocol 'TEST-MU-disp'" in p for p in h.prints)),
        ("no bogey error in display mode",
         not any("no Simurail_PhysicsBogey" in p for p in h.prints)),
        ("set speed drawn", "write:Set:36.0" in h.logs),
        ("actual speed drawn", "write:Spd:28.8 " in h.logs),
        ("drive stress drawn", "write:T: +64" in h.logs),
        ("notch/role drawn", "write:M:C" in h.logs),
        ("red distance drawn", any("R:42" in x for x in h.logs)),
        ("LINK LOST after stale", "write:LINK LOST" in h.logs),
        ("unknown values drawn as -- not 0",
         "write:T:  --" in h.logs and "write:DIR:   --" in h.logs),
        ("terminal never broadcast", len(h.broadcasts) == 0),
    ]) and ok

    # ---------- B) driver publishes snapshots ----------
    h2 = Harness(display_mode=False)
    h2.analog["right"] = 0    # mode lever -> master (forward)
    h2.analog["top"] = 10     # RHI handle -> N
    h2.run([
        ("timer", 1, 0.06),
        ("rednet_message", 99, snapshot(h2.lua, role="slave", label="CAR2"),
         "TEST-MU-disp", 0.06),     # must be dropped silently
        ("timer", 2, 0.06),
        ("timer", 3, 0.30),         # > displayInterval -> publish
        ("terminate", 0.0),
    ])
    disp = h2.display_broadcasts()
    ctrl = [(p, m) for (p, m) in h2.broadcasts if p == "TEST-MU"]
    ok = report("B) driver publishes", [
        ("driver started", any("Locomotive program started: LOCO1" in p for p in h2.prints)),
        ("published on display protocol", len(disp) >= 1),
        ("control protocol still used", len(ctrl) >= 1),
        ("display traffic not warned as foreign",
         not any("Foreign protocol" in p for p in h2.prints)),
        ("snapshot has label", disp and disp[0].label == "LOCO1"),
        ("snapshot has setSpeed field", disp and disp[0].setSpeed is not None),
        ("snapshot has consist list", disp and disp[0].cars is not None),
        ("snapshot has maxSpeed", disp and disp[0].maxSpeed == 50.0),
    ]) and ok

    # ---------- C) displayInterval = false turns publishing off ----------
    h3 = Harness(display_mode=False)
    h3.analog["right"] = 0
    h3.analog["top"] = 10
    h3.lua.globals()["__cfg"].displayInterval = False
    h3.run([
        ("timer", 1, 0.06),
        ("timer", 2, 0.30),
        ("terminate", 0.0),
    ])
    ok = report("C) displayInterval = false", [
        ("displayInterval=false publishes nothing", len(h3.display_broadcasts()) == 0),
        ("control protocol unaffected",
         len([1 for (p, m) in h3.broadcasts if p == "TEST-MU"]) >= 1),
    ]) and ok

    # ---------- D) typewriter desk ----------
    hd = Harness(display_mode=True, typewriter=True)
    hd.run([
        ("key", 87, 0.02),              # W -> notch 10 -> 11
        ("key", 87, 0.02),              # W -> 12
        ("key", 65, 0.02),              # A held -> steer -1
        ("key", 32, 0.02),              # SPACE -> ack 1
        ("timer", 1, 0.30),             # heartbeat -> manual packet + draw
        ("terminate", 0.0),
    ])
    desks = hd.manual_broadcasts()
    last = desks[-1] if desks else None
    ok = report("D) typewriter desk", [
        ("desk announced", any("Desk: linked_typewriter on 'tw1'" in p for p in hd.prints)),
        ("manual packet sent", len(desks) >= 1),
        ("notch latched to 12", last is not None and last.notch == 12),
        ("A held -> steer -1", last is not None and last.steer == -1),
        ("SPACE counted as ack", last is not None and last.ack == 1),
        ("desk state drawn", any("DSK12L" in x for x in hd.logs)),
        ("desk never touches the control protocol",
         len([1 for (p, m) in hd.broadcasts if p == "TEST-MU"]) == 0),
    ]) and ok

    # ---------- E) manual mode on the loco ----------
    he = Harness(display_mode=False, bogeys=1)
    he.analog["right"] = 0
    he.analog["top"] = 10
    evs = type_command(he, "man")                       # enter manual mode
    evs += [
        ("timer", 1, 0.06),
        ("rednet_message", 5, desk_packet(he.lua, 15, -1, 1), "TEST-MU-manual", 0.06),
        ("timer", 2, 0.06),
        ("timer", 3, 0.30),                             # publish + redraw window
        ("timer", 4, 0.06),
        ("terminate", 0.0),
    ]
    he.run(evs)
    steers = [v for v in he.bogey_values("setSteerValueOverride")]
    snapshots = he.display_broadcasts()
    ok = report("E) manual mode", [
        ("manual mode entered", any("MANUAL: on" in p for p in he.prints)),
        ("steer override written for the desk", any(abs(v + 1) < 1e-6 for v in steers)),
        ("desk notch drove the RHI notch",
         any(m.level == "K4" for m in snapshots)),
        ("snapshot marked manual", any(m.manual is True for m in snapshots)),
    ]) and ok

    # ---------- F) desk link lost -> brake, set speed kept ----------
    hf = Harness(display_mode=False, bogeys=1)
    hf.analog["right"] = 0
    hf.analog["top"] = 10
    evs = type_command(hf, "man")
    evs += [
        ("timer", 1, 0.06),
        ("rednet_message", 5, desk_packet(hf.lua, 15, -1, 1), "TEST-MU-manual", 0.06),
        ("timer", 2, 0.06),
        ("timer", 3, 0.06),
        ("timer", 4, 3.00),        # > manualTimeout with no further packet
        ("timer", 5, 0.06),
        ("terminate", 0.0),
    ]
    hf.run(evs)
    brakes = hf.bogey_values("setBrakeStrengthOverride")
    ok = report("F) desk link lost", [
        ("timeout reported", any("no desk packet" in p for p in hf.prints)),
        ("full brake applied", any(abs(v - 1.0) < 1e-6 for v in brakes)),
        ("steer released on timeout",
         any(m == "disableSteerValueOverride" for (m, a) in hf.calls)),
        ("set speed kept (not zeroed)",
         not any("SETSPD->0" in p for p in hf.prints)),
    ]) and ok

    # ---------- K) link lost with manualHoldSpeedOnLoss = false ----------
    hk = Harness(display_mode=False, bogeys=1)
    hk.lua.globals()["__cfg"].manualHoldSpeedOnLoss = False
    hk.analog["right"] = 0
    hk.analog["top"] = 10
    evs = type_command(hk, "man")
    evs += [
        ("timer", 1, 0.06),
        ("rednet_message", 5, desk_packet(hk.lua, 15, 0, 1), "TEST-MU-manual", 0.06),
        ("timer", 2, 0.06),
        ("timer", 3, 0.06),
        ("timer", 4, 3.00),
        ("timer", 5, 0.06),
        ("terminate", 0.0),
    ]
    hk.run(evs)
    ok = report("K) link lost, old behaviour", [
        ("set speed cleared", any("SETSPD->0 by desk-lost" in p for p in hk.prints)),
        ("braking reported", any("set speed cleared" in p for p in hk.prints)),
    ]) and ok

    # ---------- G) vigilance ----------
    hg = Harness(display_mode=False, bogeys=1)
    hg.analog["right"] = 0
    hg.analog["top"] = 10
    hg.lua.globals()["__cfg"].vigilanceEnabled = True
    hg.lua.globals()["__cfg"].vigilancePeriod = 0.30
    hg.lua.globals()["__cfg"].vigilanceGrace = 0.15
    hg.lua.globals()["__cfg"].vigilanceBrake = 0.5
    evs = type_command(hg, "man")
    evs += [("timer", 1, 0.06)]
    # heartbeat every 0.1 s but only ONE ack: the vigilance clock runs out
    for i in range(8):
        evs.append(("rednet_message", 5, desk_packet(hg.lua, 10, 0, 1),
                    "TEST-MU-manual", 0.10))
        evs.append(("timer", 10 + i, 0.01))
    evs.append(("terminate", 0.0))
    hg.run(evs)
    brakes = hg.bogey_values("setBrakeStrengthOverride")
    ok = report("G) vigilance", [
        ("warning window announced",
         any("VIGILANCE: SPACE due within" in p for p in hg.prints)),
        ("timeout reported",
         any("VIGILANCE: no SPACE" in p for p in hg.prints)),
        ("service brake (0.5) applied",
         any(abs(v - 0.5) < 1e-6 for v in brakes)),
    ]) and ok

    # ---------- H) persisted manual mode ----------
    hp = Harness(display_mode=False, bogeys=1)
    hp.files["manual.json"] = '{"manual": true}'
    hp.analog["right"] = 0
    hp.analog["top"] = 10
    hp.run([
        ("timer", 1, 0.06),
        ("timer", 2, 0.06),
        ("timer", 3, 0.30),
        ("terminate", 0.0),
    ])
    brakes = hp.bogey_values("setBrakeStrengthOverride")
    snaps = hp.display_broadcasts()
    ok = report("H) persisted manual mode", [
        ("state restored at boot",
         any("MANUAL: mode restored from manual.json" in p for p in hp.prints)),
        ("manual armed in the snapshot", any(m.manual is True for m in snaps)),
        ("EB until the desk talks", any(abs(v - 1.0) < 1e-6 for v in brakes)),
    ]) and ok

    # ---------- I) the console command persists the mode ----------
    hi = Harness(display_mode=False, bogeys=1)
    hi.analog["right"] = 0
    hi.analog["top"] = 10
    evs = type_command(hi, "man") + [("timer", 1, 0.06)]
    evs += type_command(hi, "man") + [("timer", 2, 0.06), ("terminate", 0.0)]
    hi.run(evs)
    ok = report("I) command persists the mode", [
        ("turned on", any("MANUAL: on" in p for p in hi.prints)),
        ("turned off", any("MANUAL: off" in p for p in hi.prints)),
        ("state file written", "manual.json" in hi.files),
        ("file ends up false", '"manual":false' in hi.files.get("manual.json", "")),
    ]) and ok

    # ---------- J) manualDefault config, no state file ----------
    hj = Harness(display_mode=False, bogeys=1)
    hj.lua.globals()["__cfg"].manualDefault = True
    hj.analog["right"] = 0
    hj.analog["top"] = 10
    hj.run([
        ("timer", 1, 0.06),
        ("timer", 2, 0.30),
        ("terminate", 0.0),
    ])
    snaps = hj.display_broadcasts()
    ok = report("J) manualDefault config", [
        ("starts in manual", any(m.manual is True for m in snaps)),
        ("no restore message without a state file",
         not any("mode restored" in p for p in hj.prints)),
    ]) and ok

    print("\nRESULT:", "ALL PASS" if ok else "FAILURES ABOVE")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
