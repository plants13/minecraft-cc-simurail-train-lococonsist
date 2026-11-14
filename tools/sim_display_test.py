"""Smoke test for the display-terminal feature (lupa = embedded Lua 5.1).

Runs the REAL locos/startup.lua against a mocked CC:Tweaked environment, so
nil-handling / wrong-field / dead-branch bugs that luaparse cannot see show up
before the script ever reaches a computer:
  A) displayMode = true  -> terminal only draws, never touches outputs
  B) displayMode = false -> driver path, publishes snapshots on <mu>-disp,
                            silently drops incoming display traffic
  C) displayInterval = false -> publishing can be switched off

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
keys = { enter = 28, backspace = 14, tab = 15 }

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
    getNames = function() return {} end,
    getType = function(name) return nil end,
    wrap = function(side) if side == "left" then return monitor end return nil end,
    call = function() return nil end,
}
redstone = { getAnalogInput = function(side) return __py_analog(side) end }
fs = {
    exists = function(p) return false end,
    open = function(p, m) return nil end,
}
textutils = {
    serializeJSON = function(t, pretty) return "{}" end,
    unserializeJSON = function(s) return nil end,
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


class Harness:
    def __init__(self, display_mode, protocol="TEST-MU"):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.logs = []
        self.prints = []
        self.broadcasts = []
        self.events = []
        self.clock = 100.0
        self.timer_id = 0
        self.analog = {"top": 0, "right": 0, "left": 0, "front": 0, "back": 0}
        self.display_mode = display_mode
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
        ]:
            g[name] = fn
        self.lua.execute(PRELUDE)
        cfg = self.lua.table(
            displayMode=display_mode,
            sideSetSpeed="top", sideReverse="right", sideMonitor="left",
            sideModem="front", maxSpeed=50.0, visualMaxSpeed=10.0,
            bogeyDriveMax=128.0, pidDt=0.05,
            calibAccelDur=3.0, calibBrakeStrength=0.5, calibPlateauTime=2.0,
            calibPlateauEps=0.1, calibMinTopSpeed=5.0, calibStartClearance=64.0,
            calibRunTimeout=120.0, calibBrakeTimeout=60.0, calibSettle=0.5,
            displayInterval=0.25, displayStale=2.0,
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


class Stop(Exception):
    pass


def snapshot(lua, **fields):
    t = lua.table()
    for k, v in fields.items():
        t[k] = v
    return t


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
    joined = "\n".join(h.logs)
    print("A) prints:")
    for p in h.prints:
        print("   |", p)
    print("A) display writes:")
    for line in h.logs:
        if line.startswith("write:"):
            print("   |", line)
    checks = [
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
    ]
    for name, good in checks:
        print(("   PASS  " if good else "   FAIL  ") + name)
        ok = ok and good

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
    disp = [(p, m) for (p, m) in h2.broadcasts if p == "TEST-MU-disp"]
    ctrl = [(p, m) for (p, m) in h2.broadcasts if p == "TEST-MU"]
    print("\nB) prints:")
    for p in h2.prints:
        print("   |", p)
    checks2 = [
        ("driver started", any("Locomotive program started: LOCO1" in p for p in h2.prints)),
        ("published on display protocol", len(disp) >= 1),
        ("control protocol still used", len(ctrl) >= 1),
        ("display traffic not warned as foreign",
         not any("Foreign protocol" in p for p in h2.prints)),
        ("snapshot has label", disp and disp[0][1].label == "LOCO1"),
        ("snapshot has setSpeed field", disp and disp[0][1].setSpeed is not None),
        ("snapshot has consist list", disp and disp[0][1].cars is not None),
        ("snapshot has maxSpeed", disp and disp[0][1].maxSpeed == 50.0),
    ]
    for name, good in checks2:
        print(("   PASS  " if good else "   FAIL  ") + name)
        ok = ok and good

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
    disp3 = [(p, m) for (p, m) in h3.broadcasts if p == "TEST-MU-disp"]
    ctrl3 = [(p, m) for (p, m) in h3.broadcasts if p == "TEST-MU"]
    checks3 = [
        ("displayInterval=false publishes nothing", len(disp3) == 0),
        ("control protocol unaffected", len(ctrl3) >= 1),
    ]
    print("\nC) displayInterval = false:")
    for name, good in checks3:
        print(("   PASS  " if good else "   FAIL  ") + name)
        ok = ok and good

    print("\nRESULT:", "ALL PASS" if ok else "FAILURES ABOVE")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
