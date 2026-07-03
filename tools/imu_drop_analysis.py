"""Throwaway analysis of IMU FIFO drops in an .idl0 log (firmware investigation).

Walks the v3 record stream, extracts per-IMU back-counted timestamps, and
reconstructs the firmware drain cadence so we can reason about WHERE and WHY
samples are lost. No app/Rust code touched. See task brief.
"""
import os, sys, struct
from collections import Counter, defaultdict

PATH = sys.argv[1] if len(sys.argv) > 1 else "session.idl0"
data = open(PATH, "rb").read()
print(f"file: {PATH}\nsize: {len(data)} bytes\n")

# ---- header (idl0_format.c) -------------------------------------------------
assert data[:4] == b"IDL0", "bad magic"
schema = data[4]
pos = 5 + 16 + 6              # uuid + device_id
start_utc = struct.unpack_from("<q", data, pos)[0]; pos += 8
crc = struct.unpack_from("<I", data, pos)[0]; pos += 4
mask = struct.unpack_from("<I", data, pos)[0]; pos += 4
imu_count = data[pos]; pos += 1
imu_rate = struct.unpack_from("<H", data, pos)[0]; pos += 2
gps_rate = data[pos]; pos += 1
reg_count = data[pos]; pos += 1
pos += reg_count * 40
endmark = struct.unpack_from("<I", data, pos)[0]; pos += 4
print(f"schema={schema} mask=0x{mask:05X} imu_count={imu_count} ODR={imu_rate}Hz "
      f"gps_rate={gps_rate} reg_count={reg_count} endmarker=0x{endmark:08X}")

ODR = imu_rate if imu_rate > 0 else 100
PERIOD = 1_000_000 // ODR     # integer, mirrors firmware
print(f"nominal PERIOD = {PERIOD} us  (ODR {ODR} Hz)\n")

# axes per IMU from mask
def axes_for(imu):
    return bin((mask >> (imu * 6)) & 0x3F).count("1")
imu_axes = {i: axes_for(i) for i in range(3)}

# ---- walk records -----------------------------------------------------------
ts = {0: [], 1: [], 2: []}    # per-IMU back-counted timestamps, in file order
gps_count = 0
other = Counter()
p = pos
n_records = 0
while p < len(data):
    rtype = data[p]
    if p + 3 > len(data): break
    plen = struct.unpack_from("<H", data, p + 1)[0]
    payload = p + 3
    if payload + plen > len(data):
        print(f"  truncated final record at {p} type=0x{rtype:02X} len={plen}")
        break
    if rtype == 0x01:
        imu = data[payload]
        t = struct.unpack_from("<q", data, payload + 1)[0]
        ts[imu].append(t)
    elif rtype == 0x02:
        gps_count += 1
    elif rtype == 0xFF:
        other["SESSION_END"] += 1
    else:
        other[f"0x{rtype:02X}"] += 1
    p = payload + plen
    n_records += 1

print(f"records={n_records} gps={gps_count} other={dict(other)}")
for i in range(3):
    print(f"  IMU{i}: {len(ts[i])} samples, {imu_axes[i]} axes")
print()

# ---- per-IMU delta + gap analysis ------------------------------------------
def analyze(imu):
    t = ts[imu]
    if len(t) < 2: return None
    n = len(t)
    span = t[-1] - t[0]
    rate_nm1 = (n - 1) / (span / 1e6)
    deltas = [t[k] - t[k-1] for k in range(1, n)]
    exact = sum(1 for d in deltas if d == PERIOD)
    # gaps: delta meaningfully > period
    missing_total = 0
    gap_sizes = []
    gap_events = []   # (index, missing, abs_time_of_gap_start)
    backsteps = []    # (index, delta)
    for k, d in enumerate(deltas):
        if d <= 0:
            backsteps.append((k, d))
        # number of grid steps this delta spans
        steps = round(d / PERIOD)
        if steps >= 2:
            miss = steps - 1
            missing_total += miss
            gap_sizes.append(miss)
            gap_events.append((k, miss, t[k]))   # gap begins after sample k (abs time t[k])
    return dict(n=n, span=span, rate_nm1=rate_nm1, deltas=deltas,
                exact=exact, missing_total=missing_total, gap_sizes=gap_sizes,
                gap_events=gap_events, backsteps=backsteps)

res = {i: analyze(i) for i in range(3)}

print("=" * 78)
print("PER-IMU SUMMARY")
print("=" * 78)
print(f"{'IMU':<5}{'recv':>9}{'missing':>9}{'drop%':>8}{'(n-1)/span':>12}"
      f"{'exact1200%':>12}{'gapsites':>10}{'backstep':>10}")
for i in range(3):
    r = res[i]
    if not r: continue
    drop = r['missing_total'] / (r['n'] + r['missing_total']) * 100
    exactpct = r['exact'] / len(r['deltas']) * 100
    print(f"{i:<5}{r['n']:>9}{r['missing_total']:>9}{drop:>7.2f}%"
          f"{r['rate_nm1']:>12.2f}{exactpct:>11.2f}%{len(r['gap_events']):>10}"
          f"{len(r['backsteps']):>10}")
print()

# ---- gap-size histogram per IMU --------------------------------------------
print("=" * 78)
print("GAP-SIZE DISTRIBUTION (missing samples per gap event)")
print("=" * 78)
for i in range(3):
    r = res[i]
    if not r: continue
    c = Counter(r['gap_sizes'])
    small = sum(v for k, v in c.items() if k <= 9)
    big = sum(v for k, v in c.items() if k >= 20)
    mid = sum(v for k, v in c.items() if 10 <= k <= 19)
    biglist = sorted([k for k in r['gap_sizes'] if k >= 20], reverse=True)
    print(f"IMU{i}: sites={len(r['gap_sizes'])}  "
          f"small(<=9)={small}  mid(10-19)={mid}  big(>=20)={big}")
    print(f"      size hist (size:count) {dict(sorted(c.items()))}"[:200])
    print(f"      big gaps (>=20): {biglist}")
print()

# ---- backstep detail --------------------------------------------------------
print("=" * 78)
print("BACKSTEPS (delta <= 0) — overlap of new drain onto previous")
print("=" * 78)
for i in range(3):
    r = res[i]
    if not r: continue
    bs = r['backsteps']
    sizes = [d for _, d in bs]
    print(f"IMU{i}: count={len(bs)}  delta range us: "
          f"{(min(sizes) if sizes else 0)}..{(max(sizes) if sizes else 0)}  "
          f"samples: {sizes[:25]}")
print()

# ---- drain-cadence reconstruction ------------------------------------------
# A "drain boundary" = any delta != PERIOD (gap, backstep, or jitter). Between
# boundaries the run length = number of pairs in that drain. The abs time at a
# boundary ~ t_read of the new drain. Cycle period for an IMU = time between
# consecutive boundaries (its own drains).
print("=" * 78)
print("DRAIN CADENCE (reconstructed from non-1200 boundaries)")
print("=" * 78)
for i in range(3):
    t = ts[i]
    if len(t) < 3: continue
    boundaries = [k for k in range(1, len(t)) if t[k] - t[k-1] != PERIOD]
    # run lengths between boundaries (pairs per drain)
    runs = []
    prev = 0
    btimes = []
    for b in boundaries:
        runs.append(b - prev)
        prev = b
        btimes.append(t[b])     # abs time of first sample of new drain (approx t_read - (n-1)*P)
    # cycle period = diff of boundary times
    cyc = [btimes[k] - btimes[k-1] for k in range(1, len(btimes))]
    import statistics as st
    if runs:
        runs_sorted = sorted(runs)
        print(f"IMU{i}: drains={len(runs)}  pairs/drain "
              f"min={min(runs)} med={st.median(runs):.0f} mean={st.mean(runs):.1f} "
              f"p95={runs_sorted[int(len(runs)*0.95)]} max={max(runs)}")
    if cyc:
        cyc_sorted = sorted(cyc)
        print(f"       cycle_us: min={min(cyc)} med={st.median(cyc):.0f} "
              f"mean={st.mean(cyc):.0f} p95={cyc_sorted[int(len(cyc)*0.95)]} "
              f"max={max(cyc)}  (drains @ ~{st.mean(cyc)/1000:.1f} ms)")
print()

# ---- coincident-stall classification ---------------------------------------
# Big gaps (>=20 missing) bucketed by absolute start time; see which IMUs
# share a stall window (+/- 25 ms). Distinguishes SD/CPU stalls (all 3) from
# I2C-bus stalls (IMU1+IMU2 only) from single-IMU FIFO overflow.
print("=" * 78)
print("COINCIDENT-STALL CLASSIFICATION (gaps >= 20 samples)")
print("=" * 78)
BIG = 20
WIN = 25_000   # 25 ms coincidence window
events = []
for i in range(3):
    r = res[i]
    if not r: continue
    for k, miss, at in r['gap_events']:
        if miss >= BIG:
            events.append((at, i, miss))
events.sort()
used = [False] * len(events)
clusters = []
for a in range(len(events)):
    if used[a]: continue
    at0, _, _ = events[a]
    grp = [events[a]]; used[a] = True
    for b in range(a + 1, len(events)):
        if used[b]: continue
        if abs(events[b][0] - at0) <= WIN:
            grp.append(events[b]); used[b] = True
    clusters.append(grp)

cls_counter = Counter()
for grp in clusters:
    imus = tuple(sorted(set(g[1] for g in grp)))
    cls_counter[imus] += 1
print(f"big-gap (>= {BIG}) clusters within {WIN/1000:.0f} ms:")
for imus, cnt in sorted(cls_counter.items()):
    label = {(0,1,2):"ALL THREE (SD/CPU stall)",
             (1,2):"IMU1+IMU2 only (I2C bus stall)",
             (0,):"IMU0 only","" :""}.get(imus, str(imus))
    print(f"   IMUs {imus}: {cnt} clusters   {label}")
print()
print("cluster detail (time_s, [(imu,miss)...]):")
for grp in sorted(clusters, key=lambda g: -max(x[2] for x in g))[:15]:
    t0 = grp[0][0] / 1e6
    print(f"   t={t0:8.2f}s  " + "  ".join(f"IMU{g[1]}:{g[2]}" for g in sorted(grp, key=lambda x:x[1])))
