# RPU — Reflexive Processing Unit

**An adaptive rate-of-change comparator with memory: a hardware block that decides when a sensor signal has really changed, two clock cycles after each sample, with no CPU instruction in the decision path.**

[![Patent pending](https://img.shields.io/badge/Patent%20pending-PCT%2FIB2026%2F053070-blue)](https://rpu-micro.com/patent)
[![Synthesized](https://img.shields.io/badge/Synthesized-TSMC%2065nm%20%7C%20SKY130-informational)](https://rpu-micro.com)
[![Board-tested](https://img.shields.io/badge/Board--tested-Nexys%20A7%20%2B%20Ibex%20RISC--V-success)](https://rpu-micro.com/#val)
[![License](https://img.shields.io/badge/License-Source--available%20(research%20%26%20evaluation%20free)-orange)](LICENSE)

Website: [rpu-micro.com](https://rpu-micro.com) · White paper: [rpu-micro.com/whitepaper](https://rpu-micro.com/whitepaper.html) · Contact: ceo@rpu-micro.com

---

## What the RPU is, in one paragraph

Every always-on system first asks one question: *has anything changed?* A level comparator answers it with no memory of the past, so it cannot tell a slow drift from a real event and cannot follow a noise floor that moves with wind, load or temperature. Firmware can, but only while a processor stays awake to run it. The RPU answers the question in hardware. It keeps the last N samples, compares the mean of the newer half of that window with the older half, and moves its own threshold with the noise floor. A constant offset cancels, slow drift stays small, an isolated spike is attenuated, and a real step or burst stands out. The decision arrives a fixed two clock cycles after the sample, with zero jitter. It sits beside your data path, not in it: two read-only input taps, one interrupt output.

**A level comparator is memoryless. The RPU is a rate-of-change comparator with memory: it adapts to its environment, and shells can be built around it without touching the core. Tuned once, it keeps working as conditions change.**

---

## Key results

Results below were measured with the RPU cores of the evaluation kits (same architecture as the reference core in this repository; kits available under NDA): the delivered V4 core, and the V4.1 core of the system kit where an option is named. Each result carries its evidence level and the comparator's setting.

| Test | Result | Level |
|---|---|---|
| Unseen recordings U1–U3 (12 events), settings frozen | **RPU 12/12 with the proportional-setpoint or two-speed option; 10/12 with the delivered default setting.** EWMA comparator at its campaign setting (threshold 850, not retuned): 8/12. The RPU never missed an event the comparator caught. Small synthetic set with event amplitudes around the comparator's threshold; with the default setting the RPU also raised 129 unmatched alarms against the comparator's 0 | FPGA board |
| Proportional threshold setpoints (V4.1 option, off by default), 8 synthetic recordings, 4 held-out folds | 57/61 events, 120 false alarms on data the setting had never seen, vs 45/61 and 122 for fixed setpoints. **Weaker on real seismic data:** STEAD 181/300 against 213/300 for fixed setpoints | Model + board (8/8 match) |
| Stress set: small events, steps, ramps, changing noise | RPU 52/64, comparator 8/64 at its campaign setting (threshold 850, not tuned on this set, which contains 300- and 700-amplitude events). Not a comparison of equally tuned designs | RTL simulation |
| Noise sweep, σ 25 → 400, both tuned once at σ 200 and frozen | The RPU never went blind (4/4 at every level); the integer comparator went blind at σ 25 (1/4). At σ 400 the RPU woke 373 times against 936, and most of those wake-ups are false alarms for both. Retuned for each level, the comparator matches the RPU | Bit-exact model |
| Real earthquake records (STEAD), P-wave arrivals, 10 h test set | RPU 213/300 at 16.4 false triggers per hour, STA/LTA 210/300 at 23.0 per hour (both tuned on a separate set for ≤ 20 per hour) | Bit-exact model |
| Real bearing faults (CWRU), rectifier front end | 25/27 with 0 false alarms; comparator and STA/LTA 27/27 at 1.5–6 false alarms per minute. Transitions made by concatenating recordings | Bit-exact model |
| Real machine sounds (MIMII: valve, pump, slider, fan) | **Negative.** Even with per-machine calibration no method is reliable; the best catch about half the events (RPU 13/24 on pumps at 4.2 false alarms per minute). These faults are a pattern-anomaly problem, not a change-detection one | Bit-exact model |
| Sensor faults: stream stop, heartbeat loss, frozen value | All reported; a persistent fault raises one interrupt (CPU active cycles 43,617 → 442); digital freeze flagged within 34 samples, analog within 290 | FPGA board 10/10 (fault-injection test build); freeze latencies from RTL simulation |
| System kit, 14 bitstreams | Board counters matched full-system simulation in 99/99 runs | FPGA board |

The comparator is an EWMA-baseline comparator; its setting is stated in each row. With equal tuning on the same data at a single noise level it does as well as the RPU; the RPU's measured advantage is that it keeps working, without retuning, when conditions change. Detection is always reported next to wake-ups, because a low wake count can also mean a blind detector. Platform: Nexys A7-100T with a [lowRISC Ibex](https://github.com/lowRISC/ibex) RISC-V core, CPU sleeping in WFI.

---

## Files in this repository

| File | Purpose |
|------|---------|
| `rpu_ultimate_final.sv` | Reference RPU core, v2.0. SystemVerilog IEEE 1800-2017, no external libraries. Includes SVA assertions. |
| `tb_rpu_ultimate_final.sv` | Self-checking testbench. Run this first. |
| `tb_rpu_ultimate_final_synthesis.sv` | Post-synthesis testbench for a netlist: give the SDF file with `+define+RPU_SDF="<path>.sdf"` (without it: zero-delay); writes a VCD for power analysis unless `+define+RPU_NO_VCD`. Same checks as the RTL testbench. |

The reference core shows the architecture and lets you reproduce its behaviour. The delivered core, the event shell, the RISC-V system kit and the calibration tool are part of the evaluation kits (see below).

---

## Run the simulation

**Icarus Verilog** (12 or later; Icarus does not support `bind` or concurrent assertions, so the SVA block is skipped there):
```bash
iverilog -g2012 -o sim_rpu rpu_ultimate_final.sv tb_rpu_ultimate_final.sv && vvp sim_rpu
```

**Verilator** (5.x; the lint warnings are width and style warnings, `-Wno-fatal` keeps them visible without stopping the build):
```bash
verilator --binary --timing --sv -Wall -Wno-fatal rpu_ultimate_final.sv tb_rpu_ultimate_final.sv --top-module tb_rpu_ultimate_final -o sim_rpu && ./obj_dir/sim_rpu
```

**Vivado xsim:** `xvlog -sv rpu_ultimate_final.sv tb_rpu_ultimate_final.sv && xelab tb_rpu_ultimate_final -s sim && xsim sim -R`
**Synopsys VCS:** `vcs -sverilog -R rpu_ultimate_final.sv tb_rpu_ultimate_final.sv`
**Questa / ModelSim:** `vlog rpu_ultimate_final.sv tb_rpu_ultimate_final.sv && vsim -c tb_rpu_ultimate_final -do "run -all; quit"`
**Cadence Xcelium:** `xrun -sv rpu_ultimate_final.sv tb_rpu_ultimate_final.sv`

Expected output:

```
==================================================
TB START: RPU_Ultimate_Final v2.0
==================================================
T1: Reset sanity...                        T1: PASS
T2: Warm-up protection...                  T2: PASS
T3: Constant signal (delta=0)...           T3: PASS
T4: Large step change...                   T4: PASS (events observed=N)
T5: Pointer wrap-around robustness...      T5: PASS
T6: Random valid stress (70% duty)...      T6: PASS
T7: Threshold saturation bounds...         T7: PASS
T8: Guardian sideband monitor...           T8: PASS
==================================================
RESULT: PASS — All tests passed. Errors=0
==================================================
```

The testbench compares the DUT with a reference model on every sample, at the clock edge where the DUT registers its outputs (two edges after the sample is captured). Eight results are listed as `NOTE`: their compare edge falls in the reset that starts the next test.

---

## Synthesis

| Parameter | TSMC 65nm GP | SkyWater SKY130 |
|-----------|-------------|-----------------|
| Target clock | 1.6 ns (625 MHz) | 10.0 ns (100 MHz) |
| Timing | Met: zero violating paths, zero TNS | Met: zero violating paths, zero TNS |
| Standard cells | 2,960 | — |
| Cell area | 12,990 µm² | 29,206 µm² |
| Total area (cell + net) | 18,062 µm² (0.018 mm²) | 47,066 µm² (0.047 mm²) |
| Total power at target clock | 1.702 mW | 3.876 mW |
| Leakage | 0.178 mW (10.5%) | 0.014 mW (0.35%) |
| Internal / switching | 1.051 mW / 0.473 mW | 2.546 mW / 1.316 mW |
| Tool | Cadence Genus, activity-based power (VCD) | Cadence Genus, activity-based power (VCD) |

Same RTL file and the same constraint method on both nodes; only the clock period differs. These are the first synthesis results, with power at the target clock.

### Power at sensor-rate clocks

A later standalone sweep of the RPU block in TSMC 65nm GP, worst-case corner (`tcbn65gpluswc`), activity-based from a VCD of a real stimulus:

| Clock | Total power |
|---|---|
| 490 MHz | 4.02 mW |
| 100 MHz | 0.859 mW |
| 10 MHz | 0.130 mW |
| **1 MHz** | **56.8 µW** (37.7 µW registers, 18.8 µW logic, 0.33 µW clock tree) |

Dynamic power scales linearly with the clock, so clock the RPU at your sample rate, not your system clock. The in-system RPU instance in the Ibex SoC agrees with the standalone figure within 1%. These are synthesis power analyses; the block has not yet been taped out.

### When it saves energy

```
S  >  P_RPU / (P_gated − P_idle)
```

`S` is the temporal sparsity, the share of time your data is quiet; `P_RPU` is the RPU's own power; `P_gated` and `P_idle` are the active and idle power of what it lets sleep. Clock the RPU at your sample rate, not your system clock. For analog sensors the ADC must stay on to feed the RPU, so quote system power with the ADC included. If your data changes on most samples (continuous video, servo loops, scrambled links), the RPU has nothing to gate.

Energy is often not the main reason to use it: a fixed, netlist-analysable decision time, a trigger that keeps working if firmware hangs, and sensor-fault reporting matter in mains-powered and certified systems too.

---

## Top-level interface

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `clk` | In | 1 | System clock |
| `rst_n` | In | 1 | Active-low async reset |
| `scan_en` | In | 1 | DFT scan enable. Tie to `0` if unused. |
| `in_data` | In | 12 | Read-only tap from the sensor or ADC output |
| `in_valid` | In | 1 | Read-only tap from the data-valid strobe |
| `wake_en` | Out | 1 | **The only output you need.** One-cycle pulse when the change exceeds the threshold. Connect to your interrupt controller. |
| `rpu_event_pulse` | Out | 1 | Same as `wake_en` |
| `rpu_state` | Out | 1 | Toggles on every event. Debug. |
| `gclk_out` | Out | 1 | Gated clock output |
| `full_status` | Out | 1 | High when the window is full. Debug. |
| `delta_abs_dbg` | Out | 12 | Current `\|mean(new half) − mean(old half)\|`. **Log this during bring-up.** |
| `threshold_dbg` | Out | 12 | Current active threshold. **Log this during bring-up.** |
| `guardian_alert` | Out | 1 | One-cycle pulse on threshold crossing, ungated clock |
| `guardian_last_data` | Out | 12 | Last captured input sample |
| `guardian_last_delta` | Out | 12 | Last captured metric value |
| `guardian_last_th` | Out | 12 | Last captured threshold |

---

## RTL instantiation

> Compute your parameters before you copy this block: see [Threshold tuning](#threshold-tuning).

```systemverilog
rpu_ultimate_final #(
  .DATA_WIDTH     (12),    // match your ADC width
  .DEPTH          (32),    // window N: power of two
  .USE_DYNAMIC_TH (1'b1),  // adaptive threshold
  .MIN_TH_P       (10),
  .MAX_TH_P       (2000),
  .STEP_UP_P      (5),
  .STEP_DN_P      (5),
  .HI_DELTA_P     (200),
  .LO_DELTA_P     (20)
) u_rpu (
  .clk      (sys_clk),
  .rst_n    (sys_rst_n),
  .scan_en  (1'b0),
  .in_data  (sensor_data),   // read-only tap
  .in_valid (data_valid),    // read-only tap
  .wake_en  (rpu_wake),      // RISC-V irq_external_i / PLIC source, or any Arm NVIC line
  .delta_abs_dbg (dbg_delta),
  .threshold_dbg (dbg_th),
  .rpu_event_pulse (), .rpu_state (), .gclk_out (), .full_status (),
  .guardian_alert (), .guardian_last_data (), .guardian_last_delta (), .guardian_last_th ()
);
```

The block has no bus-master or memory-write path. Disconnect `wake_en` and the system behaves as it did before.

---

## How it works

1. A ring buffer keeps the last `DEPTH` samples, split into an older and a newer half.
2. Two running sums give each half's mean in O(1): the same few additions per sample at any window size, bit-shifts only, no multiplier or divider.
3. The metric is `m = |mean(new half) − mean(old half)|`.
4. If `m > threshold`, `wake_en` pulses. The decision is pipelined: it arrives a fixed two clock cycles after the sample, with zero jitter, whatever the rest of the system is doing. No program counter, no instruction memory, no bus transaction is involved.
5. The policy steps the threshold **up** when `m > HI_DELTA_P` and **down** when `m < LO_DELTA_P`, within `MIN_TH_P … MAX_TH_P`.

### Predictable by design

With a window of N = 2H samples:

| Input | RPU response | What it means |
|---|---|---|
| Single spike of size B | Metric rises only to B/H | Glitches attenuated H-fold |
| Step of size A | Metric climbs to A over H samples | Detection delay ≈ H·θ/A samples |
| Ramp of slope s | Metric settles at s·H | The threshold is a slope limit θ/H |
| Interference whose period divides H | Metric stays at zero | Mains hum or rotation can be cancelled by choice of sample rate and window |
| White noise, std. dev. σ | Spread ≈ σ·√(2/H) | False-alarm rate follows from the threshold in closed form |

---

## Threshold tuning

Read this before integrating. It is the difference between an adaptive threshold and an accidental fixed one.

The RPU compares `|mean(newer half) − mean(older half)|` against its threshold. With `DEPTH = 32` each half is 16 samples. **Averaging suppresses noise heavily, so the metric the RPU sees is much smaller than your raw signal noise.**

### Step 1: compute your signal's metric

For white noise of standard deviation σ:

```
δ_noise ≈ 1.6 × σ / √DEPTH
```

For an event of amplitude A lasting L samples (L ≤ DEPTH/2):

```
δ_event ≈ 2 × A × L / DEPTH
```

Worked example: σ = 4.6 LSB at `DEPTH = 32` gives `δ_noise ≈ 1.6 × 4.6 / 5.657 ≈ 1.3`. That is the number your setpoints must bracket, not 4.6, and not the raw signal range.

### Step 2: check the problem is solvable

`δ_event / δ_noise` should be above about 3. Below that the event is buried in the noise floor and no threshold detector can separate them; you need a different front end (matched filter, correlation, longer integration).

### Step 3: size the parameters

| Parameter | Rule | Why |
|---|---|---|
| `LO_DELTA_P` | ≈ 0.5 × δ_noise | Must sit below your typical metric, or the threshold settles at `MIN_TH_P` |
| `HI_DELTA_P` | ≈ 2 × δ_noise | Must be reachable by your noise metric, or the threshold never rises |
| `MIN_TH_P` | ≈ 3 × δ_noise | Floor: keeps ordinary noise from triggering |
| `MAX_TH_P` | ≈ 0.5 × δ_event | **Ceiling. Set it too high and the detector can go blind in noisy stretches** |
| `STEP_UP_P` / `STEP_DN_P` | 1–3 | `STEP_UP > STEP_DN` gives fast attack, slow decay |

Worked example, continued (δ_noise ≈ 1.3):

```systemverilog
.MIN_TH_P (5), .MAX_TH_P (100), .STEP_UP_P (1), .STEP_DN_P (1), .HI_DELTA_P (3), .LO_DELTA_P (1)
```

### Step 4: verify

Log `threshold_dbg` min / avg / max on your first run. If `th_min == th_max`, the threshold never moved: your setpoints do not bracket your metric. Go back to Step 1.

### Wider noise ranges

With fixed setpoints, the usable adaptation range is set by the band you configure. For environments where the noise floor swings over a very wide range, the V4.1 core of the system kit offers **proportional setpoints** as an option (off by default), derived from the threshold itself; on held-out synthetic data they caught more events with fewer false alarms than fixed setpoints, but on real seismic data they were weaker (see Key results). Choose them per application, with the calibration tool, on your own recordings. Our calibration tool, which matches the RTL bit for bit, selects a profile from your own recordings.

---

## Parameters

| Parameter | Default | Notes |
|-----------|---------|-------|
| `DATA_WIDTH` | 12 | Match your sensor output width |
| `DEPTH` | 32 | Window N, power of two. Larger = more smoothing and a smaller metric. Changing it changes δ_noise: retune. Check `SUM_W = DATA_WIDTH + log₂(DEPTH)` above 32. |
| `USE_DYNAMIC_TH` | 1 | Adaptive threshold. 0 = fixed threshold |
| `FIXED_TH` | 100 | Used only when `USE_DYNAMIC_TH = 0` |
| `MIN_TH_P` | 10 | Floor. Size to ≈ 3 × δ_noise |
| `MAX_TH_P` | 2000 | Ceiling. Size to ≈ 0.5 × δ_event |
| `STEP_UP_P` | 5 | Rise step |
| `STEP_DN_P` | 5 | Decay step |
| `HI_DELTA_P` | 200 | Step-up setpoint. Size to ≈ 2 × δ_noise |
| `LO_DELTA_P` | 20 | Step-down setpoint. Size to ≈ 0.5 × δ_noise |

The defaults assume a metric of roughly 20–200. Most sensor signals produce 1–10 at `DEPTH = 32`. **Compute yours.**

---

## Guardian sideband and the event shell

The Guardian sideband in this reference core runs on an ungated clock, so the last metric, threshold and alert stay observable while the main clock is gated. It observes the RPU itself.

The **event shell** in the system evaluation kit is a separate state machine that reads only the decision stream and the CPU's acknowledgements, and never writes the core's metric or threshold. It adds interrupt coalescing, a hardware ACK, a wake budget, stream-stop and heartbeat timeouts, frozen-value detection with a report-once fault interrupt, a low-sensitivity flag, back-dated onset timestamps, an event card, a self-check of the core's metric, a configuration lock, a software-selected input conditioner (raw, envelope, difference or high-pass; raw by default) and held-alarm delivery (an alarm behind an un-ACKed event is delivered late instead of merged). Each shell function was added without changing the core. Core options (the S1 shape gate, proportional setpoints, rising-only alarms) are compile-time parameters; with them off the V4.1 core is formally equivalent to the delivered V4 core (Yosys, four parameter sets).

---

## Evaluation kits (under NDA, on request)

- **Core evaluation kit:** delivered RPU core, testbenches, assertions, Nexys A7 build, board acceptance runs.
- **System evaluation kit:** lowRISC Ibex RISC-V SoC with the RPU and event shell: source, firmware, bitstreams, board logs, acceptance scripts and four challenge tests (blindness, tampering, silencing, determinism).
- **Calibration tool:** bit-exact model of the RTL; tunes a profile on part of your recordings, freezes it, and reports detection, false alarms and CPU activity on the rest, next to a comparator tuned on the same data.
- **ASIC PPA reports** for TSMC 65nm and SKY130, and a C version of the decision logic.

Request: ceo@rpu-micro.com · [rpu-micro.com](https://rpu-micro.com)

---

## FAQ

**"Can't a simple comparator do this?"**
On a stable noise floor, a comparator with hysteresis is cheap and works. It is only as good as its last retune: when the noise amplitude changes, a level-triggered comparator storms the CPU with interrupts and an edge-triggered one goes blind. The firmware that retunes it needs an awake processor. The RPU does that adaptation itself, in about 3,000 standard cells. Tuned once at one noise level and frozen, it never went blind across a σ 25 → 400 noise sweep, while a comparator tuned the same way missed 3 of 4 events at the quiet end. Retuned for every level, a comparator does as well.

**"We already use WFI and interrupts."**
So does the RPU. The question is what raises the interrupt. A raw sensor interrupt fires on noise and drift; a firmware trigger needs the CPU awake. The RPU puts a rate-of-change decision with an adaptive threshold in front of the interrupt line, decided a fixed two clocks after the sample. The CPU's own wake-up time after that depends on the CPU.

**"We already have smart sensors."**
Some accelerometers have built-in wake logic, which shows buyers pay for it. Most sensors (geophones, strain gauges, hydrophones, current shunts, pressure probes) do not. The RPU is that logic as a licensable block for any digital stream, next to the processor or inside the sensor interface chip.

**"We already use DVFS and a PMU."**
They act through software on load, not on data change. The RPU acts on the data, in hardware, before any software runs. Complementary, not competing.

---

## License and IP

Source-available under the [RPU Source-Available License v1.1](LICENSE): free for research, evaluation, benchmarking and academic use; commercial use (SoC integration, tape-out, products) requires a written licence.

Patent pending: international application **PCT/IB2026/053070** (filed 27 March 2026), priority **TR 2025/012696** (4 September 2025). No patent has been granted yet.

**Contact:** Özcan Demirkıran, Founder & Principal Architect, RPU Microelectronics, Kocaeli, Turkey · ceo@rpu-micro.com · [rpu-micro.com](https://rpu-micro.com)
