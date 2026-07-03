"""IMU drain throughput / capacity budget model (firmware investigation).

Deterministic where the physics is deterministic (bus clock time = bit count /
clock), parameterised where it needs on-device measurement (per-transaction
driver overhead, SD-write latency). Calibrated against the real 833 Hz field log.

Goal: answer "what are the hard upper bounds, where's the low-hanging fruit,
can we hit 1600 Hz, and does turning off a channel actually help?"
"""

# ---- fixed facts ------------------------------------------------------------
BYTES_PER_WORD = 7          # 1 tag + 6 data (LSM6DSO32X FIFO output word)
WORDS_PER_SAMPLE = 2        # gyro word + accel word, both batched at BDR=ODR
SPI_HZ = 10_000_000         # IMU SPI clock
I2C_HZ = 1_000_000          # I2C fast-mode-plus
SPI_BITS_PER_BYTE = 8       # no ack
I2C_BITS_PER_BYTE = 9       # 8 + ack

# ---- deterministic bus-CLOCK cost per FIFO word (no driver overhead) --------
spi_word_clock_burst = BYTES_PER_WORD * SPI_BITS_PER_BYTE / SPI_HZ          # one big read
spi_word_clock_perword = (2 + BYTES_PER_WORD) * SPI_BITS_PER_BYTE / SPI_HZ  # tag txn + data txn
i2c_word_clock = BYTES_PER_WORD * I2C_BITS_PER_BYTE / I2C_HZ

print("=== Per-FIFO-word BUS CLOCK time (deterministic, excl. driver overhead) ===")
print(f"  SPI burst   : {spi_word_clock_burst*1e6:6.2f} us/word")
print(f"  SPI per-word: {spi_word_clock_perword*1e6:6.2f} us/word  (current IMU0 path)")
print(f"  I2C burst   : {i2c_word_clock*1e6:6.2f} us/word  (current IMU1/2 path)")
print()

# ---- BANDWIDTH CEILINGS (the hard upper bounds the user asked for) ----------
# Max ODR if a bus were 100% saturated with FIFO words. Real usable ~50-70%.
def ceiling_hz(words_per_sec_capacity, n_imus_on_bus):
    # capacity (words/s) / (WORDS_PER_SAMPLE per imu * n_imus) = ODR
    return words_per_sec_capacity / (WORDS_PER_SAMPLE * n_imus_on_bus)

spi_cap_burst = 1.0 / spi_word_clock_burst          # words/s the SPI clock can carry
i2c_cap = 1.0 / i2c_word_clock                       # words/s the I2C clock can carry

print("=== BUS BANDWIDTH CEILINGS (clock-limited, ignoring CPU/overhead) ===")
print(f"  SPI burst, 1 IMU  : {ceiling_hz(spi_cap_burst,1):8.0f} Hz  (100% util)  "
      f"-> ~{ceiling_hz(spi_cap_burst,1)*0.6:.0f} Hz at 60%")
print(f"  SPI burst, 3 IMU  : {ceiling_hz(spi_cap_burst,3):8.0f} Hz  (100% util)  "
      f"-> ~{ceiling_hz(spi_cap_burst,3)*0.6:.0f} Hz at 60%")
print(f"  I2C,    2 IMU/bus : {ceiling_hz(i2c_cap,2):8.0f} Hz  (100% util)  "
      f"-> ~{ceiling_hz(i2c_cap,2)*0.6:.0f} Hz at 60%  <-- the real squeeze")
print(f"  I2C,    1 IMU/bus : {ceiling_hz(i2c_cap,1):8.0f} Hz  (100% util)  "
      f"-> ~{ceiling_hz(i2c_cap,1)*0.6:.0f} Hz at 60%")
print()

# ---- per-second BUS UTILISATION at a given ODR (what fraction of wall time) --
def util(odr, word_clock, n_imus):
    words_per_sec = WORDS_PER_SAMPLE * odr * n_imus
    return words_per_sec * word_clock     # seconds of bus time per second

print("=== BUS UTILISATION by ODR (fraction of wall-clock spent clocking bits) ===")
print(f"{'ODR':>6} | {'IMU0 SPI burst':>15} | {'IMU0 SPI perword':>17} | "
      f"{'IMU1+2 shared I2C':>18}")
for odr in (104, 416, 833, 1666):
    print(f"{odr:>6} | {util(odr,spi_word_clock_burst,1)*100:13.1f} % | "
          f"{util(odr,spi_word_clock_perword,1)*100:15.1f} % | "
          f"{util(odr,i2c_word_clock,2)*100:16.1f} %")
print()

# ---- calibration against the real 833 Hz log --------------------------------
# Measured: cycle ~152 ms, vTaskDelay floor 50 ms => ~102 ms of WORK per cycle.
# Deterministic bus-clock work per cycle at 833 Hz, ~124 pairs/IMU drained:
ODR = 833
pairs = 124
words = pairs * WORDS_PER_SAMPLE
spi_perword_drain = words * spi_word_clock_perword
i2c_drain = words * i2c_word_clock
clock_work = spi_perword_drain + 2 * i2c_drain     # IMU0 perword + 2x I2C burst
measured_work = 0.102
overhead = measured_work - clock_work
n_spi_txn = words * 2                                # current per-word path
print("=== CALIBRATION vs the real 833 Hz field log (cycle 152 ms) ===")
print(f"  per-cycle pairs/IMU         : {pairs}  ({words} FIFO words)")
print(f"  bus-CLOCK work / cycle      : IMU0 perword {spi_perword_drain*1e3:.1f} ms + "
      f"2x I2C {i2c_drain*1e3:.1f} ms = {clock_work*1e3:.1f} ms")
print(f"  measured work / cycle       : ~{measured_work*1e3:.0f} ms (152 - 50 vTaskDelay)")
print(f"  => UNEXPLAINED overhead     : ~{overhead*1e3:.0f} ms  (driver per-txn + SD bus contention + sched)")
print(f"  current SPI transactions/cycle (IMU0 per-word): {n_spi_txn}")
print(f"  => implied overhead budget if all of it were SPI txns: "
      f"~{overhead/n_spi_txn*1e6:.0f} us/transaction  (plausible for blocking spi_device_transmit on a bus shared with SD)")
print()

# ---- LOW-HANGING FRUIT: cycles/time removed by each change ------------------
print("=== OPTIMISATION LEVERS (per-cycle work removed at 833 Hz) ===")
spi_burst_drain = words * spi_word_clock_burst
print(f"  L1 SPI burst+DMA on IMU0  : {n_spi_txn} txns -> 1; "
      f"clock {spi_perword_drain*1e3:.1f}->{spi_burst_drain*1e3:.2f} ms, "
      f"and removes the ~{overhead*1e3:.0f} ms per-txn overhead tax (the big one)")
print(f"  L2 SD off shared SPI path : removes SD-write bus-lock stalls on IMU0's drain")
print(f"  L3 drain @20ms not 50ms   : FIFO occupancy {pairs}->~17 pairs/drain (7x margin)")
print()

# ---- CHANNEL-DISABLE LEVERS (the user's 'turn off one channel' question) ----
print("=== 'TURN OFF A CHANNEL' — what actually reduces load ===")
print("  Mask bit off (current UI 'disable axis'): chip still BATCHES all 6 axes.")
print("     -> FIFO/bus load UNCHANGED. Only the .idl0 record shrinks. NO drain relief.")
print()
print("  Real levers (must change BATCHING / sensor, not the mask):")
for label, wps, n in [
    ("accel+gyro, 3 IMU (today)",        WORDS_PER_SAMPLE, 3),
    ("ACCEL ONLY (gyro BDR=0), 3 IMU",   1,                3),
    ("accel+gyro, 2 IMU (drop one)",     WORDS_PER_SAMPLE, 2),
    ("ACCEL ONLY, 2 IMU",                1,                2),
]:
    # total system word rate at 833 and at 1666, vs a nominal 'one drain budget'
    w833 = wps * 833 * n
    w1666 = wps * 1666 * n
    print(f"   {label:32}: {wps} word/sample x {n} IMU -> "
          f"{w833:6.0f} words/s @833,  {w1666:6.0f} words/s @1666")
print("   => dropping GYRO batching halves the word rate (==halving ODR for drain).")
print("      If suspension only needs vertical accel, this alone likely kills the drops")
print("      AND frees headroom for 1600 Hz accel.")
print()

# ---- 1600 Hz feasibility ----------------------------------------------------
print("=== 1666 Hz FEASIBILITY ===")
for label, wc, n in [("IMU0 SPI burst",spi_word_clock_burst,1),
                     ("IMU1+2 shared I2C",i2c_word_clock,2)]:
    u = util(1666, wc, n)
    print(f"  {label:20}: {u*100:5.1f}% bus util @1666 Hz "
          f"({'OK' if u<0.6 else 'TIGHT/!'} )")
print("  Verdict: SPI side trivial. The two I2C IMUs on ONE 1 MHz bus are the limit")
print("  (~42% raw util @1666 — feasible only if bursted + cycle tightened, or split buses,")
print("   or drop gyro batching, or move them back to SPI).")
