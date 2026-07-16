# RPU — Reflexive Processing Unit

**A 2,960-gate synthesizable hardware IP block that keeps your processor asleep until something real happens.**

[![Patent](https://img.shields.io/badge/Patent-PCT%2FIB2026%2F053070-blue)](https://www.wipo.int)
[![Silicon](https://img.shields.io/badge/Silicon-TSMC%2065nm%20%7C%20SKY130-green)](https://rpu-micro.com)
[![License](https://img.shields.io/badge/License-Apache%202.0%20(non--commercial)-orange)](LICENSE)

---

> ### 📋 Open issues affecting published results — read before citing any number
>
> We audit our own benchmarks and publish what we find.
>
> - **[Issue #1](#known-issues)** — The adaptive threshold does not engage with the default parameters. In our own Ibex benchmark the threshold pinned at `MIN_TH_P` and never moved (`th_min = th_max = 10` over 200k samples). Every published cycle figure below was produced in that state. **See [Threshold tuning](#threshold-tuning) before you integrate.**
> - **[Issue #2](#known-issues)** — The published reductions use a *polling* baseline (CPU never sleeps) against a *WFI* RPU arm. Two variables differ. A fair control (WFI + comparator) is being measured.
>
> Full detail: **[Known issues](#known-issues)**. Corrected figures will be published whether or not they favour the RPU.

---

## What the RPU does — one paragraph

Your processor right now wakes up on every clock cycle to check if sensor data has changed. Most of the time it has not. The RPU sits in parallel — it does not touch your data path — and monitors the incoming data stream in hardware. When nothing meaningful has changed, it keeps the CPU in deep sleep. When something actually changes, it fires a standard external interrupt. The CPU wakes in exactly 2 clock cycles and runs its existing ISR. Nothing in your existing RTL changes. No firmware changes. No pipeline modifications. Two read-only input taps. One interrupt output.

**Measured on lowRISC Ibex RISC-V over 5,000,004 simulation cycles: active CPU cycles reduced from 5,000,000 to 125 on stable data — a 99.998% reduction against a polling baseline.** See [Measured results](#measured-results) for what that figure does and does not include, and [Known issues](#known-issues) for the two known caveats.

---

## The problem this solves

Every processor continuously burns energy confirming that data has not changed. A medical implant confirming a stable heartbeat. An IoT sensor confirming an unchanged temperature reading. A perimeter geophone confirming that nothing is walking past. The processor wakes, checks, finds nothing, sleeps, wakes again.

Software PMUs, DVFS, and WFI+interrupt approaches reduce the waste, but none of them remove the processor from the decision path. The RPU does: the decision happens in hardware, in a single combinational clock cycle, before any instruction executes.

**Where this actually pays off.** The RPU's decisive advantage over a plain fixed-threshold comparator is narrow and specific: **it is worth its area and power when the ambient noise floor varies over time.** A comparator calibrated for a quiet night either storms with false interrupts or goes blind when the wind picks up. If your noise floor is stable, a comparator with hysteresis is cheaper and just as good — use that instead. We would rather you know this up front than discover it after integration.

---

## Files in this repository

| File | Purpose |
|------|---------|
| `rpu_ultimate_final.sv` | The RPU RTL. 560 lines. SystemVerilog IEEE 1800-2017. No external libraries, no macros, no dependencies. |
| `tb_rpu_ultimate_final.sv` | Self-checking testbench. Run this. It does everything automatically. |
| `tb_rpu_ultimate_final_synthesis.sv` | Post-synthesis testbench with SDF annotation. Only needed after synthesis against a netlist. |

Start with the first two files.

**Why only 560 lines?** This is intentional. The RPU is a combinational hardware primitive — there is no firmware, no state machine, no protocol stack, no bus interface. The entire decision chain (temporal change computation → threshold comparison → gate control) is pure combinational logic that completes within a single clock cycle. Fewer lines means fewer failure modes and a smaller attack surface. The 2,960-gate count at TSMC 65nm confirms the architecture is compact by design, not by omission.

---

## Run the simulation — copy and paste one of these

No configuration needed. The testbench has correct defaults. Pick your simulator and run.

**Verilator (open source):**
```bash
verilator --binary --sv -Wall \
  rpu_ultimate_final.sv \
  tb_rpu_ultimate_final.sv \
  -o sim_rpu && ./obj_dir/sim_rpu
```

**Icarus Verilog (open source):**
```bash
iverilog -g2012 -o sim_rpu \
  rpu_ultimate_final.sv \
  tb_rpu_ultimate_final.sv && ./sim_rpu
```

**Synopsys VCS:**
```bash
vcs -sverilog -R \
  rpu_ultimate_final.sv \
  tb_rpu_ultimate_final.sv
```

**Questa / ModelSim:**
```bash
vlog rpu_ultimate_final.sv tb_rpu_ultimate_final.sv
vsim -c tb_rpu_ultimate_final -do "run -all; quit"
```

**Cadence Xcelium:**
```bash
xrun -sv \
  rpu_ultimate_final.sv \
  tb_rpu_ultimate_final.sv
```

---

## What you will see when it passes

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

---

## Measured results

| Scenario | Baseline: polling firmware ¹ | With RPU | Reduction |
|----------|------------------------------|----------|-----------|
| Stable sensor data | 5,000,000 cycles | 125 cycles | **99.998%** |
| Single anomaly in stable stream | 5,000,000 cycles | 338 cycles | **99.993%** |
| Slow drift followed by large anomaly | 5,000,000 cycles | 1,487,143 cycles | **70.3%** |

Platform: [lowRISC Ibex](https://github.com/lowRISC/ibex) RISC-V (RV32IMC) · Verilator · 5,000,004 total cycles.

**¹ The baseline is a polling loop — the CPU never sleeps. The RPU arm uses WFI.** Two variables differ, so these figures include the contribution of WFI itself, which is substantial: any Ibex entering WFI reaches roughly 99% on stable data with an ordinary comparator driving the interrupt. **Treat these numbers as an upper bound on the RPU's contribution, not as the RPU's contribution.** A fair control arm (WFI + fixed-threshold comparator, in three competitor modes) is being measured now — [Issue #2](#known-issues).

**² These runs used the default parameters, under which the threshold pinned at `MIN_TH_P = 10` and never adapted** (`th_min = th_max = 10` across the run). So they measure a *fixed* threshold of 10 against a signal whose half-window delta never exceeds 6.31. See [Issue #1](#known-issues) and [Threshold tuning](#threshold-tuning).

**³ The 70.3% has the same root cause** — the drift produces a half-window delta of ≈ 8 against a threshold pinned at 10, so it chatters on the boundary. It is not a marginal case; it is the adaptation failing to engage.

**Wake-up latency: 2 clock cycles for the *decision*.** This is the RPU's decision latency. It is not system wake-up: the core's WFI exit and any power-gate rail settling are separate and not controlled by the RPU. Note also that an analog comparator decides in *zero* cycles — faster than the RPU. The RPU's advantage here is not speed but **determinism**: it bypasses the NVIC, so the decision latency is fixed rather than variable (15–20+ cycles, load-dependent, for a Cortex-M NVIC entry).

**False wake-ups: 0 in scenarios 1 and 2 — with the bounded uniform test noise used.** The stimulus uses `$urandom_range`, which is bounded and therefore has no tails, so the delta is mathematically capped. Real sensor noise is Gaussian. With Gaussian noise of σ = 8 and the same parameters we measure **209 false triggers**. Stimuli are being regenerated as Gaussian — [Issue #2](#known-issues).

**Missed events: 0 in these scenarios.** Note that a missed-event count is only meaningful when the threshold is *below* the event delta. A threshold that ratchets above your events will report zero interrupts, which looks perfect and is a total false-negative. See the `MAX_TH_P` rule in [Threshold tuning](#threshold-tuning).

---

## Silicon proof

| Parameter | TSMC 65nm GP | SkyWater SKY130 |
|-----------|-------------|-----------------|
| Frequency | 625 MHz | 100 MHz |
| Worst Negative Slack | 0 ps | 0 ps |
| Total power | 1.702 mW ¹ | 3.876 mW |
| Leakage power | 0.178 mW | 0.014 mW |
| Total cell area | 18,062 µm² ² | — |
| Gate count | 2,960 | equivalent |
| Synthesis tool | Cadence Genus | Cadence Genus |

Both nodes: full timing closure, zero violations. Same RTL file.

**¹ 1.702 mW is measured at 625 MHz.** In a sensor-rate deployment the dynamic component scales down roughly with frequency and only leakage remains, so the realistic standing cost is closer to **~0.18 mW**. This matters for the break-even condition below. A frequency sweep (625 MHz / 10 MHz / 1 MHz / 100 kHz) is being measured — [Issue #5](#known-issues).

**² 18,062 µm² is the total cell area** (12,989.52 combinational + 5,072.60 sequential). Earlier documents quoted 12,990 µm², which is a component and not the total.

### Break-even

The RPU is not free. It is profitable when:

```
S  >  P_R / (P_F − P_idle)
```

where `S` is sparsity (the fraction of time your data is stationary), `P_R` is the RPU's own power, and `P_F` is the active power of the block it gates.

| RPU clock | P_R | Break-even sparsity |
|---|---|---|
| 625 MHz | 1.702 mW | S > 0.36 |
| 1 MHz | ~0.18 mW | **S > 0.04** |

**If your data changes on most samples (S ≈ 0), the RPU is a net energy loss.** It will find nothing to gate while still burning its own power. Continuous video, servo control loops, batch tensor streams, and scrambled serial links all fall in this regime. Don't use it there.

---

## Top-level interface

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `clk` | In | 1 | System clock |
| `rst_n` | In | 1 | Active-low async reset |
| `scan_en` | In | 1 | DFT scan enable. Tie to `0` if not used. |
| `in_data` | In | 12 | Read-only tap from existing sensor or ADC output. Nothing upstream changes. |
| `in_valid` | In | 1 | Read-only tap from existing data valid strobe. Nothing upstream changes. |
| `wake_en` | Out | 1 | **The only output you need.** Pulses high for 1 cycle when data change exceeds threshold. Connect to your interrupt controller. |
| `rpu_event_pulse` | Out | 1 | Same as wake_en. Leave unconnected on first integration. |
| `rpu_state` | Out | 1 | Toggle FF, flips on every event. Debug use only. |
| `gclk_out` | Out | 1 | Gated clock output. Leave unconnected on first integration. |
| `full_status` | Out | 1 | High when ring buffer is full. Debug use only. |
| `delta_abs_dbg` | Out | 12 | Current `\|avg_new − avg_old\|`. **Log this during bring-up.** |
| `threshold_dbg` | Out | 12 | Current active threshold. **Log this during bring-up — see [Step 4](#step-4-verify-adaptation-actually-engaged).** |
| `guardian_alert` | Out | 1 | 1-cycle pulse on threshold crossing. Runs on ungated clock. |
| `guardian_last_data` | Out | 12 | Last captured input sample. |
| `guardian_last_delta` | Out | 12 | Last captured delta value. |
| `guardian_last_th` | Out | 12 | Last captured threshold value. |

**For simulation:** the testbench wires everything up automatically.
**For integration:** you only need `wake_en` — but log `delta_abs_dbg` and `threshold_dbg` on your first run. They are how you find out whether your parameters are right.

---

## RTL instantiation

> ### ⚠️ Do not copy these parameters without reading [Threshold tuning](#threshold-tuning)
>
> **The defaults do not engage the adaptive threshold for most real signals.** If your signal's half-window delta falls below `LO_DELTA_P`, the threshold decrements on every sample and pins at `MIN_TH_P`, where it stays for the rest of the run. You get a fixed threshold while believing you have an adaptive one.
>
> We measured exactly this on our own Ibex benchmark: with the values below and a signal whose half-window delta averages 1.30, `threshold_dbg` reported `th_min = th_max = 10` across 200,000 samples. It never moved.
>
> The defaults assume a delta range of roughly 20–200. Averaging over `DEPTH/2 = 16` samples means **most sensor signals produce a delta of 1–10.** Compute yours first.

```systemverilog
rpu_ultimate_final #(
  .DATA_WIDTH     (12),    // match your ADC width
  .DEPTH          (32),    // sliding window depth — must be power-of-two and even
  .USE_DYNAMIC_TH (1'b1),  // adaptive threshold — requires tuning, see below

  // These values MUST be computed from your signal. See Threshold tuning.
  // The values below are the historical defaults and are NOT a starting point.
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

  // Read-only taps — nothing upstream changes
  .in_data  (sensor_data),
  .in_valid (data_valid),

  // Connect to your interrupt controller
  // RISC-V: irq_external_i or any PLIC source line
  // ARM Cortex-M: any NVIC line
  .wake_en  (rpu_wake),

  // Log these two on your first run — they tell you if your tuning is right
  .delta_abs_dbg   (dbg_delta),
  .threshold_dbg   (dbg_th),

  // Leave unconnected on first integration
  .rpu_event_pulse (),
  .rpu_state       (),
  .gclk_out        (),
  .full_status     (),
  .guardian_alert      (),
  .guardian_last_data  (),
  .guardian_last_delta (),
  .guardian_last_th    ()
);
```

**Fail-safe:** Disconnect `wake_en` or remove the instantiation entirely. The system reverts to conventional polling with zero latency added and zero data lost. The RPU is strictly parallel and not in your data path.

---

## How it works internally

1. Maintains a circular ring buffer of the last `DEPTH` input samples.
2. Splits the buffer into two halves. Maintains a running sum of each half, so the average of each half is available in **O(1)** — constant time regardless of `DEPTH`, using bit-shifts only. No divider, no multiplier.
3. Calculates `delta = |avg_new − avg_old|`.
4. If `delta > threshold`: asserts `wake_en` for one clock cycle.
5. The policy engine adjusts the threshold: it steps **up** when `delta > HI_DELTA_P` and **down** when `delta < LO_DELTA_P`.

The decision path (steps 2–4) is fully combinational. No program counter. No instruction memory. No bus transaction.

**Understand step 5 before you rely on it.** `HI_DELTA_P` and `LO_DELTA_P` are **fixed constants**, and the threshold does not feed back into the delta. The loop is therefore **open** and has no equilibrium. It has exactly three behaviours:

| Condition | Behaviour |
|---|---|
| `delta < LO_DELTA_P` | decrements **every sample** → pins at `MIN_TH_P` |
| `LO_DELTA_P < delta < HI_DELTA_P` | frozen — **no adaptation at all** |
| `delta > HI_DELTA_P` | increments **every sample** → pins at `MAX_TH_P` |

For the threshold to be usefully adaptive, **your delta must live inside the `[LO_DELTA_P, HI_DELTA_P]` band and move around within it.** If it sits permanently on one side, the threshold rails and stops adapting. This is the single most important thing to understand about tuning this block, and it is why the next section exists.

---

## Threshold tuning

**Read this before integrating.** The RPU compares `|avg(newer half) − avg(older half)|` against its threshold. With `DEPTH = 32`, each half is 16 samples. The averaging suppresses noise heavily, so **the delta your RPU sees is much smaller than your raw signal noise.** This is the most common tuning mistake and it is the one we made ourselves.

### Step 1 — compute your signal's delta range

For white noise of standard deviation σ:

```
δ_noise ≈ 1.6 × σ / √DEPTH
```

For an event of amplitude A lasting L samples (L ≤ DEPTH/2):

```
δ_event ≈ 2 × A × L / DEPTH
```

**Worked example — our own Ibex Case-1 stimulus** (`in_data = 70 + urandom_range(0,15) - 5`, i.e. uniform 65–80, σ = 4.61, DEPTH = 32):

```
δ_noise ≈ 1.6 × 4.61 / 5.657 = 1.30      (measured: 1.30 — the formula holds)
```

The defaults set `LO_DELTA_P = 20`. Since 1.30 < 20 on every single sample, the threshold decremented continuously and pinned at `MIN_TH_P = 10`. **That is [Issue #1](#known-issues), and it is why every figure in our results table measures a fixed threshold.**

### Step 2 — check the problem is solvable at all

```
δ_event / δ_noise   must be  > ~3
```

Below that ratio, the event is buried in the noise floor and **no threshold detector can separate them** — not this one, not a comparator, not CFAR. That is physics, not an implementation limit. If your ratio is under 3 you need a different front end (matched filter, correlation, longer integration), and the RPU's premise — *decide before processing* — does not apply to your problem.

### Step 3 — set the parameters

| Parameter | Rule | Why |
|---|---|---|
| `LO_DELTA_P` | `≈ 0.5 × δ_noise` | Must be **below** your typical delta, or the threshold ratchets down and pins at `MIN_TH_P` |
| `HI_DELTA_P` | `≈ 2 × δ_noise` | Must be **reachable** by your noise delta, or the threshold never rises |
| `MIN_TH_P` | `≈ 3 × δ_noise` | Floor. Keeps the noise from triggering |
| `MAX_TH_P` | `≈ 0.5 × δ_event` | **Ceiling. Critical — see below.** |
| `STEP_UP_P` / `STEP_DN_P` | 1–3 | `STEP_UP > STEP_DN` gives fast-attack / slow-decay — good for bursty noise |

**`MAX_TH_P` is the trap in the other direction.** If the threshold can rise above `δ_event`, it will ratchet up during noisy periods and **go blind to real events.** We measured a parameter set that produced **zero interrupts** on a rising-noise stimulus — which looks perfect until you check `th_avg = 465` against an event delta of 150. The threshold had climbed above the signal and missed every genuine event. **Zero interrupts on a stimulus containing events is a total false-negative, not a success.**

**Worked example, continued.** For δ_noise = 1.30:

```systemverilog
.MIN_TH_P   (5),     // ≈ 3 × 1.30
.MAX_TH_P   (100),   // ≈ 0.5 × your δ_event
.STEP_UP_P  (1),
.STEP_DN_P  (1),
.HI_DELTA_P (3),     // ≈ 2 × 1.30
.LO_DELTA_P (1)      // ≈ 0.5 × 1.30
```

Measured on the same stimulus: `th_min = 5, th_max = 100` — **the threshold is alive and tracking.** Compare with the defaults on identical data: `th_min = th_max = 10`.

### Step 4 — verify adaptation actually engaged

**Log `threshold_dbg` min / avg / max over your run. Every time.**

```
th_min == th_max   →   the adaptation NEVER ENGAGED.
                       You are measuring a fixed threshold.
                       Go back to Step 1.
```

This one check is how we found [Issue #1](#known-issues) in our own benchmark. It costs one line of testbench code and it will save you from publishing a number that means something other than what you think it means.

### Known limitation — noise floors that move a lot

Because `HI_DELTA_P` and `LO_DELTA_P` are fixed, the usable adaptation range is bounded by the dead band you configure. If your noise floor varies by more than roughly **4×** over time, your delta will leave the band and the threshold will rail to `MIN_TH_P` or `MAX_TH_P`.

This is worth stating plainly because it collides with the RPU's own selling point: the case where an adaptive threshold beats a comparator is *precisely* the case where the noise floor moves. **In its current form the block is calibration-sensitive, not calibration-free, for exactly that scenario.**

**Work in progress.** A proportional-setpoint variant closes the loop:

```
hi_ref = threshold × K_HI / 16     (K_HI = 24 → 1.5×)
lo_ref = threshold × K_LO / 16     (K_LO = 8  → 0.5×)
```

Shift-only, no divider, ~30 gates. Implemented and measured: the threshold now **tracks** (`th_min = 20 → th_max = 138`) where the fixed version pinned or railed. **It is not a complete fix yet** — the loop settles at `delta ≈ threshold`, so the threshold sits *at* the noise rather than above it, and a separate α margin (as CFAR uses, α ≈ 2–4) is still needed. Progress: [Issue #1](#known-issues).

**Prior-art note, stated plainly:** proportional thresholding against a local noise estimate is what CFAR has done in radar since 1968. The principle is not novel and we do not claim it. What is specific to this design is the O(1) split-window arithmetic that fits it into 2,960 gates **ahead of the processor**, rather than in a DSP after the ADC.

---

## Parameters

| Parameter | Default | Notes |
|-----------|---------|-------|
| `DATA_WIDTH` | 12 | Match to your sensor output width. 8-bit ADC → set to 8. |
| `DEPTH` | 32 | Larger = more smoothing, slower drift response, **smaller delta**. Must be power-of-two and even. If increasing beyond 32, verify `SUM_W` (`DATA_WIDTH + log₂(DEPTH)`) does not overflow the accumulators. |
| `USE_DYNAMIC_TH` | 1 | Set to 0 for a fixed threshold. **Note: if your parameters are wrong, `1` behaves like `0` anyway** — see [Issue #1](#known-issues). |
| `FIXED_TH` | 100 | Used only when `USE_DYNAMIC_TH = 0`. |
| `MIN_TH_P` | 10 | Threshold floor. **Set to ≈ 3 × δ_noise.** |
| `MAX_TH_P` | 2000 | Threshold ceiling. **Set to ≈ 0.5 × δ_event.** If this exceeds your event delta, the threshold can ratchet above real events and miss them. |
| `STEP_UP_P` | 5 | Rise aggressiveness. |
| `STEP_DN_P` | 5 | Decay aggressiveness. |
| `HI_DELTA_P` | 200 | Delta above which the threshold steps up. **Must be reachable by your noise delta (≈ 2 × δ_noise) or the threshold never rises.** |
| `LO_DELTA_P` | 20 | Delta below which the threshold steps down. **Must be below your typical delta (≈ 0.5 × δ_noise) or the threshold pins at `MIN_TH_P`.** |

> **The defaults are not a starting point for real signals.** They assume a delta range of 20–200. See [Threshold tuning](#threshold-tuning).

---

## Notes on Guardian Sideband

The Guardian Sideband (Module 107) runs on an **ungated clock** by design. Its purpose is to remain observable even when the main clock is fully gated, which is essential for watchdog compliance in safety-critical applications (defense, automotive, medical).

This means the Guardian continuously consumes a small amount of static power regardless of main clock state. For applications where Guardian observability is not required, the module can be excluded from synthesis by removing the instantiation — the core `wake_en` functionality is unaffected.

**Note on scope:** the Guardian observes the *RPU*. It does not detect a dead or frozen *sensor* — that requires a separate inactivity check (`delta < floor` sustained over N samples), which is not implemented in this release.

---

## What is not in this repository

**C-HAL library (`rpu.c` / `rpu.h`):** Available on request — email ozcan.demirkiran@rpu-micro.com with subject "C-HAL request". Enables runtime threshold tuning via memory-mapped registers without re-synthesis. Runs the same ΔC/Δt logic on any microcontroller — STM32, ESP32, ARM Cortex-M, RISC-V.

**Full ASIC PPA reports:** Available on request. Cadence Genus synthesis at TSMC 65nm and SkyWater SKY130.

**RISC-V Ibex SoC testbench:** Available on request. Complete lowRISC SoC environment where the cycle reductions were measured. **Note the two caveats in [Known issues](#known-issues) before using those numbers.**

---

## Frequently asked questions

**"We already use WFI and interrupts — isn't that the same thing?"**

Largely, yes — and honestly, for many applications WFI + a comparator is sufficient and cheaper. The RPU addresses three specific gaps. (1) **Determinism:** Cortex-M NVIC entry takes 15–20 cycles minimum and is load-dependent; the RPU decision is combinational and fixed. For DO-254 / ISO 26262 work, a fixed latency you can prove beats a variable one you have to bound. (2) **Rate-of-change instead of level:** a single noisy spike looks different from a sustained change, because the decision uses a sliding window rather than an instantaneous value. (3) **Adaptive threshold:** the threshold can track a changing noise floor, where a fixed comparator either storms or goes blind.

Be aware that (3) is [Issue #1](#known-issues) — in its current form the adaptation is bounded by the dead band you configure, and it rails outside it. Read [Threshold tuning](#threshold-tuning). And note that gap (3) is also the only one that makes the RPU decisively better than a good comparator, so it matters.

**"Can't a simple comparator do this?"**

For a stable noise floor: **yes, and it is cheaper.** A comparator with Schmitt hysteresis is a handful of transistors and will match the RPU on stationary data, on spikes, and — if you give it an EWMA baseline tracker — on slow drift too. We have measured this against our own block and we are not going to pretend otherwise.

The comparator fails in one specific place: when the **ambient noise amplitude changes over time.** A level-triggered comparator then asserts continuously (interrupt storm); an edge-triggered one fires once and goes blind to the new regime. An EWMA tracks the signal *mean*, not the *noise floor*, so it does not save you. That is the case the RPU is for. If your noise floor is stable, use the comparator.

**"We already have smart sensors and DMA controllers."**

Smart sensors (ADXL362, LIS2DH, BMA400 and similar) have threshold registers and will keep your CPU asleep for months. If one exists for your transducer, **use it — it costs a dollar and it works.** Their thresholds are fixed registers, so they need software recalibration when the environment shifts; that is the gap. The RPU's real territory is transducers for which no smart part exists: geophones, hydrophones, FBG strain sensors, custom piezo.

**"We already use DVFS and PMU."**

DVFS and PMU operate through software layers with millisecond-scale latency and no data-change awareness. They reduce power when the OS decides to. The RPU reduces power when the data is actually stagnant, in hardware, before any software is involved. Complementary, not competing.

**"What if I need to remove it later?"**

Disconnect `wake_en` or remove the instantiation. The system reverts to conventional polling with zero latency difference and zero data loss. The RPU is strictly parallel and not in the critical data path.

**"Does DEPTH affect wake-up latency?"**

No. `DEPTH` only controls the sliding window size. The combinational decision path is identical for any valid `DEPTH`. It does, however, affect your **delta magnitude** (`δ ∝ 1/√DEPTH` for noise) — so if you change `DEPTH`, you must retune `HI_DELTA_P` / `LO_DELTA_P`.

**"Does it work with ARM Cortex-M?"**

Yes. Connect `wake_en` to any NVIC line. The CPU sees a standard external interrupt and runs the existing ISR unchanged.

**"Is the 99.998% number real or modeled?"**

It is a real simulation measurement — lowRISC Ibex, Verilator, 5,000,004 cycles, 5,000,000 baseline active cycles reduced to 125. **But read what it measures.** The baseline is a polling loop that never sleeps, and the RPU arm uses WFI, so the figure includes WFI's contribution ([Issue #2](#known-issues)). And the run used default parameters under which the threshold pinned at 10 and never adapted ([Issue #1](#known-issues)) — so it measures a fixed threshold of 10 against a signal whose delta never exceeds 6.31.

A fair control arm is being measured now, with Gaussian stimuli and a properly calibrated threshold. **The corrected number will be smaller, and we will publish it.**

**"Why are you telling me all this?"**

Because the repository is public, the reproduction takes an afternoon, and a number that means something other than what you think it means is worse than no number. We would rather you find our caveats in our own README than in your own bring-up lab.

---

## Advanced integration notes

**SRAM macro substitution:** The ring buffer (Module 102) is implemented as flip-flop registers by default and accounts for roughly 60% of the gate count. At tape-out, replacing it with an SRAM macro reduces sequential cell area proportionally — the RTL interface is unchanged. Particularly beneficial at `DEPTH ≥ 64`.

**DATA_WIDTH:** Default 12-bit. The datapath scales automatically; verify `SUM_W` headroom when widening beyond 12.

**Multi-clock domain:** Single clock domain. If your sensor interface and processor run on different clocks, add a standard 2-FF synchronizer on `in_data` / `in_valid`.

**Reset synchronization:** `rst_n` is asynchronous active-low. Add a reset synchronizer cell in a synchronous reset domain.

**DFT / scan:** `scan_en` is provided for full-scan insertion. Tie to 0 in functional mode.

**Power gating:** `wake_en` can drive a sleep transistor gate directly in addition to the interrupt controller. Note that power-gate exit costs 10–100 ns of rail settling, which is separate from and much larger than the RPU's 2-cycle decision latency — budget for it.

**Area scaling at advanced nodes:** The 18,062 µm² / 2,960-gate figure is specific to TSMC 65nm.

---

## Known design trade-offs

| Trade-off | Detail | Impact |
|-----------|--------|--------|
| **Dead band in the policy engine** | No adjustment when `LO_DELTA_P < delta < HI_DELTA_P` | **This is where the threshold holds — and also where it stops adapting.** The band must bracket your delta range: too narrow and the threshold rails; wide enough to never rail and it never adapts. See [Issue #1](#known-issues). Previously documented as an "intentional stability band"; that framing was too generous. |
| Guardian ungated clock | Runs continuously for watchdog compliance | Small static power overhead |
| 2-stage pipeline | Stage-A captures, Stage-B computes delta | 2-cycle decision latency by design |
| Accumulator width | `SUM_W = DATA_WIDTH + log₂(DEPTH/2)` | Verify when `DEPTH > 32` |
| Area | 18,062 µm² against an Ibex at ~20k gates | **≈ 13–15% area increase.** Small in absolute terms, not negligible relative to the core it protects |
| Standing power | 1.702 mW at 625 MHz | Scales down to ~0.18 mW at sensor rates. **Below the break-even sparsity it is a net loss** |

**Correction — previous tuning advice was wrong.** An earlier revision of this README recommended `HI_DELTA_P = 80, LO_DELTA_P = 40` as an optimization for slow-drift applications. **We tested it: it produces exactly the same result as the defaults** (`th_min = th_max = 10`), because the signal's delta of 1.30 is still far below `LO_DELTA_P = 40`. The threshold still pins. That advice has been removed and replaced by [Threshold tuning](#threshold-tuning), which computes the parameters from your actual signal instead of guessing.

---

---

## Known issues

We audit our own benchmarks and publish what we find. These affect the numbers in [Measured results](#measured-results). Corrected figures will be published whether or not they favour the RPU.

### Issue #1 — Adaptive threshold does not engage with the default parameters

**Status:** confirmed, root-caused, fix in progress.
**Severity:** affects every published cycle-reduction figure.

`HI_DELTA_P` and `LO_DELTA_P` are fixed constants and the threshold does not feed back into the delta, so the policy engine is an **open-loop integrator with a constant reference.** It has no equilibrium and only three behaviours:

1. `delta < LO_DELTA_P` → decrements every sample → pins at `MIN_TH_P`
2. `LO_DELTA_P < delta < HI_DELTA_P` → frozen (dead band), no adaptation
3. `delta > HI_DELTA_P` → increments every sample → pins at `MAX_TH_P`

**Measured** (200k samples, defaults, `in_data = 70 + urandom_range(0,15) - 5`):

```
half-window delta:   mean = 1.30   max = 6.31
threshold:           th_min = 10   th_max = 10     <-- never moves
```

**Workaround:** tune `LO_DELTA_P < δ_noise < HI_DELTA_P` — see [Threshold tuning](#threshold-tuning). Verified: `MIN_TH_P=5, HI_DELTA_P=3, LO_DELTA_P=1` on the same stimulus gives `th_min=5, th_max=100`.

**Proposed fix:** proportional setpoints, `hi_ref = threshold × K_HI / 16`, `lo_ref = threshold × K_LO / 16`. Shift-only, ~30 gates, no divider. Implemented and measured: the threshold now tracks (`th_min=20 → th_max=138`) where the fixed version pinned or railed. **Not a complete fix yet** — the loop settles at `delta ≈ threshold`, so the threshold sits *at* the noise rather than above it. A separate α margin (as CFAR uses, α ≈ 2–4) is needed.

### Issue #2 — Published cycle reductions use a polling baseline

**Status:** confirmed, re-measurement in progress.

The baseline firmware never sleeps; the RPU arm uses WFI. Two variables changed at once, so the published figures include WFI's contribution. Any Ibex entering WFI reaches ~99% on stable data with an ordinary comparator driving the interrupt.

A fair control arm — **Ibex + WFI + fixed-threshold comparator with hysteresis** — is being built and measured, in three competitor modes (absolute, simple delta, and EWMA baseline-tracking) and both trigger styles (edge and level).

### Issue #3 — Test noise is uniform, so it has no tails

`$urandom_range` is bounded, so the delta is mathematically capped. Real sensor noise is Gaussian. With Gaussian σ = 8 and the same parameters the RPU produces **209 false triggers** on stationary data, where an EWMA comparator produces zero. Stimuli are being regenerated as Gaussian.

### Issue #4 — Area figure was understated

Earlier documents quoted 12,990 µm² (TSMC 65nm). The PPA report's total is **18,062.12 µm²** (12,989.52 combinational + 5,072.60 sequential). The lower figure is a component, not the total. Corrected above.

### Issue #5 — Standing power is quoted at maximum frequency

1.702 mW is measured at 625 MHz. In a sensor-rate deployment the dynamic component scales down with frequency and only leakage (0.178 mW) remains, so the realistic standing cost is closer to **~0.18 mW** — roughly 10× better than we have been reporting. A frequency sweep (625 MHz / 10 MHz / 1 MHz / 100 kHz) is being measured. See [Break-even](#break-even) for why this matters.

---

## License

This RTL is released for **research and evaluation purposes only**.

This is **not** a standard Apache 2.0 license. The LICENSE file in this repository is Apache 2.0 with a commercial use restriction added.

- Research, academic, and evaluation use: **free**
- Commercial use (SoC integration, tape-out, product deployment): **requires a written license agreement**

Contact ozcan.demirkiran@rpu-micro.com for commercial licensing.

The underlying architecture is the subject of international patent application PCT/IB2026/053070 (pending). The application covers the architectural principle — using temporal rate of change (ΔC/Δt) as the primary signal for autonomous hardware gating decisions.

---

## Contact

**Özcan Demirkıran** — Founder & Principal Architect
RPU Microelectronics · Kocaeli, Turkey
ozcan.demirkiran@rpu-micro.com
+90 536 636 10 72
[rpu-micro.com](https://rpu-micro.com)

Patent: PCT/IB2026/053070 (pending) · TR 2025/012696 (pending)
GitHub: [github.com/Rpu-Microelectronics/rpu-microelectronics](https://github.com/Rpu-Microelectronics/rpu-microelectronics)
