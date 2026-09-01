import re, sys

# parse trace
ticks = []
for line in open('/tmp/hs-v9-trace.log'):
    m = re.match(r'([\d.]+) tick in=(-?\d+),(-?[\d.]+),(-?\d+) out=(-?\d+),(-?[\d.]+),(-?\d+) -> (\w+)', line)
    if m:
        t, l, f, p, oL, oF, oP, dec = m.groups()
        ticks.append((float(t), int(l), float(f), int(p), int(oL), dec))

t0 = ticks[0][0]

# v9 damage report
eaten = 0; eaten_events = []; dumps = []
i = 0
buf = 0
for (t, l, f, p, oL, dec) in ticks:
    if dec in ('holdStart','hold'):
        buf += l
    elif dec == 'absorb':
        if buf != 0:
            eaten += abs(buf); eaten_events.append((round(t-t0,2), buf))
        buf = 0
    elif dec == 'flip':
        dumps.append((round(t-t0,2), oL))
        buf = 0
print("=== v9 실측 피해 ===")
print(f"absorb로 먹힌 입력(라인 합): {eaten}, 건수 {len(eaten_events)}: {eaten_events}")
print(f"flip 덤프(한 번에 방출): {dumps}")

# v10 sim
guardMs, absorbMs, releaseMs = 120, 100, 100
lastDir, lastPassAt = 0, None
holdDir, holdStart, bufL = 0, None, 0
res = {'pass':0,'guardPass':0,'holdStart':0,'hold':0,'absorb':0,'flip':0}
v10_eaten = []; v10_dumps = []; v10_delayed = []
log = []
def sgn(v): return 1 if v>0 else (-1 if v<0 else 0)
for (t, l, f, p, oL, dec9) in ticks:
    d = sgn(l)
    out = None
    if holdDir != 0:
        # timer would have fired if release elapsed before this tick
        if (t - holdStart)*1000 >= releaseMs:
            # timer flip (post buffer) at holdStart+release
            v10_dumps.append((round(t-t0,2), bufL, 'timer'))
            v10_delayed.append(bufL)
            lastDir = holdDir; lastPassAt = holdStart + releaseMs/1000
            res['flip'] += 1
            holdDir, holdStart, bufL = 0, None, 0
            # fall through to process current tick fresh
        elif d == holdDir:
            bufL += l; res['hold'] += 1
            log.append((round(t-t0,2), l, 'hold'))
            continue
        else:
            # original dir returned within absorb window -> drop buffer
            v10_eaten.append((round(t-t0,2), bufL))
            res['absorb'] += 1
            holdDir, holdStart, bufL = 0, None, 0
            lastDir = d; lastPassAt = t
            log.append((round(t-t0,2), l, 'absorb-pass'))
            continue
    if lastDir == 0 or d == lastDir:
        lastDir = d; lastPassAt = t; res['pass'] += 1
        log.append((round(t-t0,2), l, 'pass'))
    else:
        gap = (t - lastPassAt)*1000
        if gap >= guardMs:
            lastDir = d; lastPassAt = t; res['guardPass'] += 1
            log.append((round(t-t0,2), l, f'REVERSE-instant (gap {gap:.0f}ms)'))
        else:
            holdDir, holdStart, bufL = d, t, l
            res['holdStart'] += 1
            log.append((round(t-t0,2), l, f'holdStart (gap {gap:.0f}ms)'))
print("\n=== v10 시뮬 (같은 트레이스) ===")
print(res)
print(f"먹힌 입력: {sum(abs(b) for _,b in v10_eaten)} 라인, 건수 {len(v10_eaten)}: {v10_eaten}")
print(f"타이머 릴리즈(지연≤{releaseMs}ms 후 방출): {v10_dumps}")
print("\n역방향 즉시통과/보류 내역:")
for e in log:
    if 'REVERSE' in e[2] or 'holdStart' in e[2]:
        print(" ", e)
