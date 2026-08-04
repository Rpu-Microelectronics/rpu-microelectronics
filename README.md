# RPU — Reflexive Processing Unit

**A 2,960-gate synthesizable hardware IP block that keeps your processor asleep until something real happens.**

[![Patent pending](https://img.shields.io/badge/Patent%20pending-PCT%2FIB2026%2F053070-blue)](https://patentscope.wipo.int)
[![Silicon](https://img.shields.io/badge/Silicon-TSMC%2065nm%20%7C%20SKY130-green)](https://rpu-micro.com)
[![License](https://img.shields.io/badge/License-Source--Available%20(evaluation%20free)-orange)](LICENSE)

---

## What the RPU does — one paragraph

Your processor right now wakes up on every clock cycle to check if sensor data has changed. Most of the time it has not. The RPU sits in parallel — it does not touch your data path — and monitors the incoming data stream in hardware. When nothing meaningful has changed, it keeps the CPU in deep sleep. When something actually changes, it fires a standard external interrupt. The CPU wakes in exactly 2 clock cycles and runs its existing ISR. Nothing in your existing RTL changes. No firmware changes. No pipeline modifications. Two read-only input taps. One interrupt output.

**Measured on lowRISC Ibex RISC-V over 5,000,004 simulation cycles: active CPU cycles reduced from 5,000,000 to 125 on stable data.**

---

## The problem this solves

Every processor continuously burns energy confirming that data has not changed. A medical implant confirming a stable heartbeat. An IoT sensor confirming an unchanged temperature reading. A perimeter geophone confirming that nothing is walking past. The processor wakes, checks, finds nothing, sleeps, wakes again.

Software PMUs, DVFS, and WFI+interrupt approaches reduce the waste, but none of them remove the processor from the decision path. The RPU does: the decision happens in hardware, in a single combinational clock cycle, before any instruction executes.

**Where the RPU is decisively better than a plain comparator.** A fixed-threshold comparator with hysteresis is cheap and works well — as long as your ambient noise floor stays put. When it does not, the comparator either storms with false interrupts (level-triggered) or goes blind to the new regime (edge-triggered). The RPU's adaptive threshold tracks the noise floor instead. **If your noise floor is stable, use a comparator — it is cheaper.** If it moves, this block exists for you.

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

| Scenario | Baseline ¹ | With RPU | Reduction |
|----------|-----------|----------|-----------|
| Stable sensor data | 5,000,000 cycles | 125 cycles | **99.998%** |
| Single anomaly in stable stream | 5,000,000 cycles | 338 cycles | **99.993%** |
| Slow drift followed by large anomaly ² | 5,000,000 cycles | 1,487,143 cycles | 70.3% ² |

Wake-up latency across all scenarios: **2 clock cycles for the decision.** Note that this is the RPU's decision latency, not system wake-up — the core's WFI exit and any power-gate rail settling are separate and not controlled by the RPU.

False wake-ups: **0** in scenarios 1 and 2 with the test stimulus used. Missed events: **0**.

Platform: [lowRISC Ibex](https://github.com/lowRISC/ibex) RISC-V (RV32IMC) · Verilator · 5,000,004 total cycles.

**¹ Baseline is a polling firmware loop — the CPU never sleeps.** The RPU arm uses WFI, so part of the reduction is attributable to WFI itself. A control arm using WFI plus a fixed-threshold comparator is being measured; treat these figures as an upper bound on the RPU's own contribution until that lands.

**² The 70.3% is a stimulus artifact, not an RPU limitation.** The Case-3 drift generator increments a 12-bit signal by ~0.5/cycle, so it wraps at 4096 roughly 122 times over the run. Each wrap is a full-scale 4095 → 0 discontinuity, which the RPU correctly detects as a genuine step. Measured on a 200k-sample reproduction: **394 interrupts with the wrap present, 0 with it removed and nothing else changed** — the drift itself never triggers once. Being re-measured with a bounded stimulus; the figure is expected to improve substantially.

---

## Silicon proof

| Parameter | TSMC 65nm GP | SkyWater SKY130 |
|-----------|-------------|-----------------|
| Frequency | 625 MHz | 100 MHz |
| Worst Negative Slack | 0 ps | 0 ps |
| Total power @ max frequency | 1.702 mW | 3.876 mW |
| Leakage power | 0.178 mW | 0.014 mW |
| Total cell area | 18,062 µm² | — |
| Gate count | 2,960 | equivalent |
| Synthesis tool | Cadence Genus | Cadence Genus |

Both nodes: full timing closure, zero violations. Same RTL file.

**Power scales with clock frequency.** The 1.702 mW figure is at 625 MHz. In a sensor-rate deployment the RPU is clocked far below that, the dynamic component scales down accordingly, and standing cost approaches the leakage floor (**0.178 mW**). Clock the RPU at your sample rate, not at your system clock — this is the single largest lever on standing cost.

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

**If your data changes on most samples (S ≈ 0), the RPU is a net energy loss.** It will find nothing to gate while still burning its own power. Continuous video, servo control loops, batch tensor streams, and scrambled serial links all fall in that regime. Don't use it there.

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
| `threshold_dbg` | Out | 12 | Current active threshold. **Log this during bring-up — see [Threshold tuning](#threshold-tuning).** |
| `guardian_alert` | Out | 1 | 1-cycle pulse on threshold crossing. Runs on ungated clock. |
| `guardian_last_data` | Out | 12 | Last captured input sample. |
| `guardian_last_delta` | Out | 12 | Last captured delta value. |
| `guardian_last_th` | Out | 12 | Last captured threshold value. |

**For simulation:** the testbench wires everything up automatically.
**For integration:** you only need `wake_en` — but log `delta_abs_dbg` and `threshold_dbg` on your first run. They tell you whether your parameters fit your signal.

---

## RTL instantiation

> **Compute your parameters before you copy this block.** The RPU's threshold logic works against your signal's *delta* — the difference between two half-window averages — which is much smaller than your raw signal noise. Getting `HI_DELTA_P` / `LO_DELTA_P` wrong is the most common integration mistake and it silently disables the adaptive threshold. Five minutes in [Threshold tuning](#threshold-tuning) will save you a week.

```systemverilog
rpu_ultimate_final #(
  .DATA_WIDTH     (12),    // match your ADC width
  .DEPTH          (32),    // sliding window depth — must be power-of-two and even
  .USE_DYNAMIC_TH (1'b1),  // adaptive threshold — recommended for real sensors

  // Compute these from your signal — see Threshold tuning
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

  // Log these two on your first run
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

**Step 5 is the part you configure.** `HI_DELTA_P` and `LO_DELTA_P` are the setpoints the policy engine measures your delta against:

| Condition | Threshold behaviour |
|---|---|
| `delta < LO_DELTA_P` | steps **down** every sample → settles at `MIN_TH_P` |
| `LO_DELTA_P < delta < HI_DELTA_P` | **holds** — this is the stability band |
| `delta > HI_DELTA_P` | steps **up** every sample → settles at `MAX_TH_P` |

The threshold is adaptive **within** the band you configure. For it to track your signal, **the band must bracket your delta.** If your delta sits permanently on one side of the band, the threshold settles at a rail and stops moving. The next section shows how to size it.

---

## Threshold tuning

Read this before integrating. It is five minutes and it is the difference between an adaptive threshold and an accidental fixed one.

The RPU compares `|avg(newer half) − avg(older half)|` against its threshold. With `DEPTH = 32` each half is 16 samples. **The averaging suppresses noise heavily, so the delta the RPU sees is much smaller than your raw signal noise.** This is the point people miss.

### Step 1 — compute your signal's delta

For white noise of standard deviation σ:

```
δ_noise ≈ 1.6 × σ / √DEPTH
```

For an event of amplitude A lasting L samples (L ≤ DEPTH/2):

```
δ_event ≈ 2 × A × L / DEPTH
```

**Worked example.** A sensor with σ = 4.6 LSB at `DEPTH = 32`:

```
δ_noise ≈ 1.6 × 4.6 / 5.657 ≈ 1.3
```

That is the number your setpoints must bracket — not 4.6, and certainly not the raw signal range. A `LO_DELTA_P` of 20 against a delta of 1.3 means the threshold steps down on every sample and settles at `MIN_TH_P` for the rest of the run.

### Step 2 — check the problem is solvable

```
δ_event / δ_noise   should be  > ~3
```

Below that, the event is buried in the noise floor and **no threshold detector can separate them** — not this one, not a comparator, not CFAR. That is physics. If your ratio is under 3 you need a different front end (matched filter, correlation, longer integration), and the RPU's premise — decide before processing — does not apply to your problem.

### Step 3 — size the parameters

| Parameter | Rule | Why |
|---|---|---|
| `LO_DELTA_P` | `≈ 0.5 × δ_noise` | Must sit **below** your typical delta, or the threshold settles at `MIN_TH_P` |
| `HI_DELTA_P` | `≈ 2 × δ_noise` | Must be **reachable** by your noise delta, or the threshold never rises |
| `MIN_TH_P` | `≈ 3 × δ_noise` | Floor. Keeps ordinary noise from triggering |
| `MAX_TH_P` | `≈ 0.5 × δ_event` | **Ceiling. Get this wrong and you go blind — see below** |
| `STEP_UP_P` / `STEP_DN_P` | 1–3 | `STEP_UP > STEP_DN` gives fast-attack / slow-decay, good for bursty noise |

**`MAX_TH_P` is the trap in the other direction.** If the threshold can climb above `δ_event`, it will ratchet up during noisy stretches and **go blind to real events.** A parameter set that produces *zero interrupts* on a noisy stimulus looks perfect and may in fact be missing everything. Always check `th_avg` against your `δ_event`.

**Worked example, continued.** For δ_noise ≈ 1.3:

```systemverilog
.MIN_TH_P   (5),     // ≈ 3 × 1.3
.MAX_TH_P   (100),   // ≈ 0.5 × your δ_event
.STEP_UP_P  (1),
.STEP_DN_P  (1),
.HI_DELTA_P (3),     // ≈ 2 × 1.3
.LO_DELTA_P (1)      // ≈ 0.5 × 1.3
```

Measured on that stimulus, this set gives `th_min = 5, th_max = 100` — the threshold is alive and tracking across its full configured range.

### Step 4 — verify

**Log `threshold_dbg` min / avg / max on your first run. Every time.**

```
th_min == th_max   →   the threshold never moved.
                       Your setpoints don't bracket your delta.
                       Go back to Step 1.
```

One line of testbench code. It is the single most useful check you can run on this block.

### Bounds of the adaptive range

The stability band is defined by fixed setpoints, so the usable adaptation range is bounded by the band you configure. If your noise floor varies by more than roughly **4×** over time, your delta will leave the band and the threshold will settle at `MIN_TH_P` or `MAX_TH_P`.

For most deployments — a sensor in a reasonably consistent environment — this is not a constraint, and a correctly sized band adapts across the range you care about. For environments where the noise floor swings by orders of magnitude (a geophone between a still night and a gale), contact us — an extended-range variant is under development and not in this release.

---

## Parameters

| Parameter | Default | Notes |
|-----------|---------|-------|
| `DATA_WIDTH` | 12 | Match to your sensor output width. 8-bit ADC → set to 8. |
| `DEPTH` | 32 | Larger = more smoothing, slower drift response, **smaller delta**. Must be power-of-two and even. If increasing beyond 32, verify `SUM_W` (`DATA_WIDTH + log₂(DEPTH)`) does not overflow the accumulators. Changing `DEPTH` changes δ_noise — retune. |
| `USE_DYNAMIC_TH` | 1 | Adaptive threshold. Set to 0 for a fixed threshold (safety-critical paths, or when your noise floor is provably stable). |
| `FIXED_TH` | 100 | Used only when `USE_DYNAMIC_TH = 0`. |
| `MIN_TH_P` | 10 | Threshold floor. **Size to ≈ 3 × δ_noise.** |
| `MAX_TH_P` | 2000 | Threshold ceiling. **Size to ≈ 0.5 × δ_event.** |
| `STEP_UP_P` | 5 | Rise aggressiveness. |
| `STEP_DN_P` | 5 | Decay aggressiveness. |
| `HI_DELTA_P` | 200 | Setpoint above which the threshold steps up. **Size to ≈ 2 × δ_noise.** |
| `LO_DELTA_P` | 20 | Setpoint below which the threshold steps down. **Size to ≈ 0.5 × δ_noise.** |

The defaults assume a delta range of roughly 20–200. Averaging over `DEPTH/2 = 16` samples means most sensor signals produce a delta of 1–10. **Compute yours.** See [Threshold tuning](#threshold-tuning).

---

## Notes on Guardian Sideband

The Guardian Sideband (Module 107) runs on an **ungated clock** by design. Its purpose is to remain observable even when the main clock is fully gated, which is essential for watchdog compliance in safety-critical applications (defense, automotive, medical).

This means the Guardian continuously consumes a small amount of static power regardless of main clock state. For applications where Guardian observability is not required, the module can be excluded from synthesis by removing the instantiation — the core `wake_en` functionality is unaffected.

**Scope:** the Guardian observes the *RPU*. It does not detect a dead or frozen *sensor*; that capability is not in this release.

---

## What is not in this repository

**C-HAL library (`rpu.c` / `rpu.h`):** Available on request — email ozcan.demirkiran@rpu-micro.com with subject "C-HAL request". Enables runtime threshold tuning via memory-mapped registers without re-synthesis. Runs the same ΔC/Δt logic on any microcontroller — STM32, ESP32, ARM Cortex-M, RISC-V.

**Full ASIC PPA reports:** Available on request. Cadence Genus synthesis at TSMC 65nm and SkyWater SKY130.

**RISC-V Ibex SoC testbench:** Available on request. Complete lowRISC SoC environment where the cycle reductions were measured.

---

## Frequently asked questions

**"We already use WFI and interrupts — isn't that the same thing?"**

Partly, and for many applications WFI plus a comparator is sufficient and cheaper. The RPU addresses three specific gaps. (1) **Determinism:** Cortex-M NVIC entry takes 15–20 cycles minimum and is load-dependent; the RPU decision is combinational and fixed. For DO-254 / ISO 26262 work, a fixed latency you can prove beats a variable one you have to bound. (2) **Rate-of-change instead of level:** a single noisy spike looks different from a sustained change, because the decision uses a sliding window rather than an instantaneous value. (3) **Adaptive threshold:** the threshold tracks a changing noise floor, where a fixed comparator either storms or goes blind.

Gap (3) is the one that matters commercially — see the next answer.

**"Can't a simple comparator do this?"**

For a stable noise floor: **yes, and it is cheaper.** A comparator with Schmitt hysteresis is a handful of transistors and will match the RPU on stationary data, on spikes, and — if you give it an EWMA baseline tracker — on slow drift too. We have measured this against our own block and we are not going to pretend otherwise.

The comparator fails in one specific place: when the **ambient noise amplitude changes over time.** A level-triggered comparator then asserts continuously (interrupt storm); an edge-triggered one fires once and goes blind to the new regime. An EWMA tracks the signal *mean*, not the *noise floor*, so it does not save you. That is what the RPU is for. If your noise floor is stable, use the comparator.

**"We already have smart sensors and DMA controllers."**

Smart sensors (ADXL362, LIS2DH, BMA400 and similar) have threshold registers and will keep your CPU asleep for months. If one exists for your transducer, **use it — it costs a dollar and it works.** Their thresholds are fixed registers, so they need software recalibration when the environment shifts; that is the gap. The RPU's territory is transducers for which no smart part exists: geophones, hydrophones, FBG strain sensors, custom piezo.

**"We already use DVFS and PMU."**

DVFS and PMU operate through software layers with millisecond-scale latency and no data-change awareness. They reduce power when the OS decides to. The RPU reduces power when the data is actually stagnant, in hardware, before any software is involved. Complementary, not competing.

**"What if I need to remove it later?"**

Disconnect `wake_en` or remove the instantiation. The system reverts to conventional polling with zero latency difference and zero data loss. The RPU is strictly parallel and not in the critical data path.

**"Does DEPTH affect wake-up latency?"**

No. `DEPTH` only controls the sliding window size — the combinational decision path is identical for any valid `DEPTH`. It does affect your **delta magnitude** (`δ_noise ∝ 1/√DEPTH`), so if you change `DEPTH` you must retune `HI_DELTA_P` / `LO_DELTA_P`.

**"Does it work with ARM Cortex-M?"**

Yes. Connect `wake_en` to any NVIC line. The CPU sees a standard external interrupt and runs the existing ISR unchanged.

**"Is the 99.998% real or modeled?"**

Real simulation measurement — lowRISC Ibex, Verilator, 5,000,004 cycles, 5,000,000 baseline active cycles reduced to 125. Read the footnotes on the results table for what the baseline was and what is being re-measured.

---

## Advanced integration notes

**SRAM macro substitution:** The ring buffer (Module 102) is implemented as flip-flop registers by default and accounts for roughly 60% of the gate count. At tape-out, replacing it with an SRAM macro reduces sequential cell area proportionally — the RTL interface is unchanged. Particularly beneficial at `DEPTH ≥ 64`.

**DATA_WIDTH:** Default 12-bit. The datapath scales automatically; verify `SUM_W` headroom when widening beyond 12.

**Multi-clock domain:** Single clock domain. If your sensor interface and processor run on different clocks, add a standard 2-FF synchronizer on `in_data` / `in_valid`.

**Reset synchronization:** `rst_n` is asynchronous active-low. Add a reset synchronizer cell in a synchronous reset domain.

**DFT / scan:** `scan_en` is provided for full-scan insertion. Tie to 0 in functional mode.

**Power gating:** `wake_en` can drive a sleep transistor gate directly in addition to the interrupt controller. Note that power-gate exit costs 10–100 ns of rail settling, which is separate from and much larger than the RPU's 2-cycle decision latency — budget for it.

**Clock the RPU at your sample rate**, not at your system clock. Dynamic power scales with frequency and the RPU only needs to run as fast as data arrives.

**Area scaling at advanced nodes:** The 18,062 µm² / 2,960-gate figure is specific to TSMC 65nm.

---

## Known design trade-offs

| Trade-off | Detail | Impact |
|-----------|--------|--------|
| **Stability band** | No threshold adjustment when `LO_DELTA_P < delta < HI_DELTA_P` | Prevents oscillation on borderline signals, but bounds the adaptive range to roughly 4× of noise-floor variation. The band must bracket your delta — see [Threshold tuning](#threshold-tuning). An extended-range variant is under development and not in this release. |
| Guardian ungated clock | Runs continuously for watchdog compliance | Small static power overhead |
| 2-stage pipeline | Stage-A captures, Stage-B computes delta | 2-cycle decision latency by design |
| Accumulator width | `SUM_W = DATA_WIDTH + log₂(DEPTH/2)` | Verify when `DEPTH > 32` |
| Area | 18,062 µm² against an Ibex at ~20k gates | ≈ 13–15% area increase. Small in absolute terms, not negligible relative to the core it protects |
| Standing power | 1.702 mW at 625 MHz, ~0.18 mW at sensor rates | Below the break-even sparsity it is a net loss — see [Break-even](#break-even) |

---

## License

Released under the **RPU Source-Available License v1.1** (see [`LICENSE`](LICENSE)). This is **not** an OSI-approved open-source licence.

- Research, academic, evaluation and benchmarking use: **free**
- Redistribution with notices intact, non-commercial purposes: **permitted**
- Commercial use (SoC integration, tape-out, product deployment, resale as IP): **requires a written agreement**
- **Patent rights: not granted by this licence.** Copyright permission and patent permission are separate and independent.

### Patent status

The architecture is the subject of two pending **applications** — **TR 2025/012696** (filed 4 September 2025) and **PCT/IB2026/053070** (filed 27 March 2026, claiming that priority). **No patent has been granted.** No enforceable patent right exists in any jurisdiction until grant, and claim scope may change during examination.

The TÜRKPATENT search report for the national application cited no document in category X. International search has been carried out by the European Patent Office, which found the subject-matter of several claims — including the split-window running-sum computation, the Guardian sideband and the array architecture — to be new over the cited art, and raised objections against the remainder. The search report and written opinion will publish together with the application; anyone evaluating the RPU commercially is welcome to read them then, or to ask us for a summary now.

The claims as currently pursued are directed to a specific hardware arrangement: a decision derived from the difference between values representing two successive intervals of a sample window, maintained by running sums at a cost independent of window depth, compared without reference to the absolute magnitude of any individual sample, and applied to alter the element's own hardware operating mode with no processor, program counter, instruction memory, state machine or centralised control unit in the decision path.

The claims are drafted independently of hardware description language and process node. They are **not** independent of circuit topology: a materially different way of computing the change metric may fall outside them. If you are evaluating the RPU for a commercial product, talk to us early — evaluation is free and we will tell you plainly what is and is not covered.

For commercial licensing: <ozcan.demirkiran@rpu-micro.com>

---

## Contact

**Özcan Demirkıran** — Founder & Principal Architect
RPU Microelectronics · Kocaeli, Turkey
ozcan.demirkiran@rpu-micro.com
+90 536 636 10 72
[rpu-micro.com](https://rpu-micro.com)

Patent applications (pending, not granted): PCT/IB2026/053070 · TR 2025/012696
GitHub: [github.com/Rpu-Microelectronics/rpu-microelectronics](https://github.com/Rpu-Microelectronics/rpu-microelectronics)
