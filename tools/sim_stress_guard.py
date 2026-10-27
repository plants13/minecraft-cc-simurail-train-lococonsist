"""Compare guard designs for locos/startup.lua (overstress -> cap the drive).

Model: used_stress = N_bogeys * applied_drive * rpm_per_bogey
The stressometer reports the network's cached value, so readings lag the
command by a few ticks (the interesting failure mode).

1 cut+release   : cut by cap/used, release at a fixed rate when headroom shows
2 target-track  : drive the ceiling toward margin*cap/k every tick
4 band+hysteresis: cut by cap/used, hold, then release SLOWLY and only while
                  used/capacity is inside a wide safe band (release ratio),
                  so the lag cannot pump the loop
"""

MARGIN = 0.95        # cap target used by the cut
BAND = 0.85          # release only while used/cap < BAND
RELEASE = 8.0        # units/s of ceiling recovery
HOLD = 0.3           # s frozen after a cut
MAX_OUT = 128.0


class Sim:
    def __init__(self, design, capacity, rpm, n_bogeys, lag=0, dt=0.05,
                 want=MAX_OUT, cap_after=None, change_at=1000):
        self.design = design
        self.cap = capacity
        self.rpm = rpm
        self.n = n_bogeys
        self.dt = dt
        self.lag = lag
        self.want = want
        self.history = []
        self.limit = MAX_OUT
        self.last = 0.0
        self.active = False
        self.hold = 0.0
        self.overstress_ticks = 0
        self.k = None
        self.cap_after = cap_after
        self.change_at = change_at

    def used_of(self, applied):
        return self.n * applied * self.rpm

    def gauge(self):
        idx = len(self.history) - 1 - self.lag
        return self.history[idx] if idx >= 0 else (0.0, self.cap)

    def guard(self):
        used, cap = self.gauge()
        r = (used / cap) if cap > 0 else (float('inf') if used > 0 else 0.0)

        if self.design == 2:
            if self.last <= 1e-9:
                if used > cap:
                    self.limit, self.active = 0.0, True
                return
            k = used / self.last
            target = MAX_OUT if k <= 0 else max(0.0, min(MAX_OUT, MARGIN * cap / k))
            if target < self.limit:
                self.limit = target
                self.active = self.active or (used > cap)
            else:
                self.limit = min(target, self.limit + RELEASE * 20 * self.dt)
            return

        if used > cap:
            s = (cap / used) if cap > 0 else 0.0
            target = self.last * s * MARGIN
            if target < self.limit:
                self.limit = target
            self.active = True
            self.hold = HOLD
            return
        if self.hold > 0:
            self.hold -= self.dt
            return
        self.active = False
        if self.design == 1:
            if r < MARGIN and self.limit < MAX_OUT:
                self.limit = min(MAX_OUT, self.limit + RELEASE * 20 * self.dt)
        else:  # design 4
            if r < BAND and self.limit < MAX_OUT:
                self.limit = min(MAX_OUT, self.limit + RELEASE * self.dt)

    def step(self, i):
        if self.cap_after is not None and i == self.change_at:
            self.cap = self.cap_after
        self.guard()
        applied = max(0.0, min(MAX_OUT, self.want))
        if applied > self.limit:
            applied = self.limit
        self.last = applied
        self.history.append((self.used_of(applied), self.cap))
        if self.used_of(applied) > self.cap:
            self.overstress_ticks += 1
        return applied


def run(design, cap, rpm, n, lag, want=MAX_OUT, ticks=2000, cap_after=None):
    sim = Sim(design, cap, rpm, n, lag=lag, want=want, cap_after=cap_after)
    out = [sim.step(i) for i in range(ticks)]
    return sim, out


def block(label, cases):
    print(label)
    for case in cases:
        cap, rpm, n, lag, want, cap_after = case
        for design in (1, 4):
            sim, out = run(design, cap, rpm, n, lag, want, cap_after=cap_after)
            tail = out[-40:]
            safe = cap / (n * rpm) if rpm and n and cap else 0.0
            tag = 'cut+release' if design == 1 else 'band+hyst'
            print(f'  cap={cap:<7} rpm={rpm:<3} N={n} lag={lag} want={want:<5} {tag:<12} '
                  f'safe={safe:7.2f} out={min(tail):6.2f}..{max(tail):6.2f} '
                  f'overstress={sim.overstress_ticks:4d}/{len(out)}')
    print()


block('A. no lag', [(1000, 32, 2, 0, MAX_OUT, None)])
block('B. gauge lag 1/2/4/8 ticks', [(1000, 32, 2, 1, MAX_OUT, None),
                                    (1000, 32, 2, 2, MAX_OUT, None),
                                    (1000, 32, 2, 4, MAX_OUT, None),
                                    (1000, 32, 2, 8, MAX_OUT, None)])
block('C. plenty of headroom', [(100000, 32, 2, 2, MAX_OUT, None)])
block('D. network at rest 0/0', [(0, 0, 2, 2, MAX_OUT, None)])
block('E. PID below the ceiling', [(1000, 32, 2, 2, 20, None)])
block('G. capacity doubles at tick 1000', [(1000, 32, 2, 2, MAX_OUT, 2000)])
