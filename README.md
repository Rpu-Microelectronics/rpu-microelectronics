# RPU — Reflexive Processing Unit

**A 2,960-gate synthesizable hardware IP block that keeps your processor asleep until something real happens.**

[![Patent](https://img.shields.io/badge/Patent-PCT%2FIB2026%2F053070-blue)](https://www.wipo.int)
[![Silicon](https://img.shields.io/badge/Silicon-TSMC%2065nm%20%7C%20SKY130-green)](https://rpu-micro.com)
[![License](https://img.shields.io/badge/License-Apache%202.0%20(non--commercial)-orange)](LICENSE)

---

## What the RPU does — one paragraph

Your processor right now wakes up on every clock cycle to check if sensor data has changed. Most of the time it has not. The RPU sits in parallel — it does not touch your data path — and monitors the incoming data stream in hardware. When nothing meaningful has changed, it keeps the CPU in deep sleep. When something actually changes, it fires a standard external interrupt. The CPU wakes in exactly 2 clock cycles and runs its existing ISR. Nothing in your existing RTL changes. No firmware changes. No pipeline modifications. Two read-only input taps. One interrupt output.

**Measured result on lowRISC Ibex RISC-V over 5,000,004 simulation cycles: 99.998% reduction in active CPU cycles on stable data. 2-cycle wake-up latency. Zero false wake-ups. Zero missed events.**

---

## The problem this solves

Every processor continuously burns energy confirming that data has not changed. A radar system confirming empty sky. A medical implant confirming a stable heartbeat. An edge AI camera confirming a static scene. An IoT sensor confirming an unchanged temperature reading. The processor wakes, checks, finds nothing, sleeps, wakes again. Millions of times per second.

This is not a firmware bug. It is the way Von Neumann architecture works — a processor cannot know whether data has changed without first waking up to check. Software PMUs, DVFS, and WFI+interrupt approaches reduce the waste at the margins, but none of them break the fundamental loop: the processor is still in the decision path.

The RPU removes the processor from the decision entirely. The decision happens in hardware, in a single combinational clock cycle, before any instruction executes.

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

No configuration needed. No parameters to change. The testbench has correct defaults. Pick your simulator and run.

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

| Scenario | Without RPU | With RPU | Reduction |
|----------|-------------|----------|-----------|
| Stable sensor data (IoT idle, radar empty sky, static scene) | 5,000,000 cycles | 125 cycles | **99.998%** |
| Single anomaly in stable stream | 5,000,000 cycles | 338 cycles | **99.993%** |
| Slow drift followed by large anomaly | 5,000,000 cycles | 1,487,143 cycles | **70.3%** |

Wake-up latency across all scenarios: **2 clock cycles. Always. No jitter.**
False wake-ups: **0** in scenarios 1 and 2.
Missed events: **0** in any scenario.

Platform: [lowRISC Ibex](https://github.com/lowRISC/ibex) RISC-V (RV32IMC) · Verilator · 5,000,004 total cycles.

---

## Silicon proof

| Parameter | TSMC 65nm GP | SkyWater SKY130 |
|-----------|-------------|-----------------|
| Frequency | 625 MHz | 100 MHz |
| Worst Negative Slack | 0 ps | 0 ps |
| Total power | 1.70 mW | 3.876 mW |
| Leakage power | 0.178 mW | 0.014 mW |
| Gate count | 2,960 | equivalent |
| Synthesis tool | Cadence Genus | Cadence Genus |

Both nodes: full timing closure, zero violations. Same RTL file.

---

## Top-level interface

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `clk` | In | 1 | System clock |
| `rst_n` | In | 1 | Active-low async reset |
| `scan_en` | In | 1 | DFT scan enable. Tie to `0` if not used. |
| `in_data` | In | 12 | Read-only tap from existing sensor or ADC output. Nothing upstream changes. |
| `in_valid` | In | 1 | Read-only tap from existing data valid strobe. Nothing upstream changes. |
| `wake_en` | Out | 1 | **The only output you need.** Pulses high for 1 cycle when data change exceeds threshold. Connect to your interrupt controller. CPU exits WFI in 2 cycles. |
| `rpu_event_pulse` | Out | 1 | Same as wake_en. Leave unconnected on first integration. |
| `rpu_state` | Out | 1 | Toggle FF, flips on every event. Debug use only. |
| `gclk_out` | Out | 1 | Gated clock output. Leave unconnected on first integration. |
| `full_status` | Out | 1 | High when ring buffer is full. Debug use only. |
| `delta_abs_dbg` | Out | 12 | Current `\|avg_new − avg_old\|`. Debug use only. |
| `threshold_dbg` | Out | 12 | Current active threshold. Debug use only. |
| `guardian_alert` | Out | 1 | 1-cycle pulse on threshold crossing. Runs on ungated clock. |
| `guardian_last_data` | Out | 12 | Last captured input sample. |
| `guardian_last_delta` | Out | 12 | Last captured delta value. |
| `guardian_last_th` | Out | 12 | Last captured threshold value. |

**For simulation:** the testbench wires everything up automatically.
**For integration:** you only need `wake_en`. Everything else can be left unconnected.

---

## RTL instantiation

```systemverilog
rpu_ultimate_final #(
  .DATA_WIDTH     (12),    // change to match your sensor or ADC output width
  .DEPTH          (32),    // sliding window depth — must be power-of-two and even
  .USE_DYNAMIC_TH (1'b1),  // adaptive threshold — recommended for real sensors
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
  // Custom: any level-triggered interrupt input
  .wake_en  (rpu_wake),

  // Leave unconnected on first integration
  .rpu_event_pulse (),
  .rpu_state       (),
  .gclk_out        (),
  .full_status     (),
  .delta_abs_dbg   (),
  .threshold_dbg   (),
  .guardian_alert      (),
  .guardian_last_data  (),
  .guardian_last_delta (),
  .guardian_last_th    ()
);
```

**Fail-safe:** Disconnect `wake_en` or remove the instantiation entirely. The system reverts to conventional polling with zero latency added and zero data lost. The RPU is strictly parallel and not in your data path.

---

## How it works internally

1. Maintains a circular ring buffer of the last 32 input samples.
2. Splits the buffer into two halves. Computes a running average of each half using bit-shifts only — no hardware divider, no multiplier.
3. Calculates `delta = |avg_new − avg_old|`.
4. If `delta > threshold`: asserts `wake_en` for one clock cycle.
5. Adaptive threshold engine adjusts automatically — rises in noisy environments, drops in quiet ones.

The entire decision path (steps 2–4) is fully combinational. No program counter. No instruction memory. No bus transaction. Decision completes within one clock cycle.

---

## Parameters

| Parameter | Default | When to change |
|-----------|---------|----------------|
| `DATA_WIDTH` | 12 | Match to your sensor output width. 8-bit ADC → set to 8. |
| `DEPTH` | 32 | Larger = more smoothing, slower drift response. Must be power-of-two and even. **If increasing DEPTH beyond 32, verify that SUM_W (DATA_WIDTH + log₂(DEPTH)) does not overflow the accumulator registers.** |
| `USE_DYNAMIC_TH` | 1 | Set to 0 for fixed threshold (safety-critical paths). |
| `FIXED_TH` | 100 | Used only when USE_DYNAMIC_TH = 0. |
| `MIN_TH_P` | 10 | Threshold floor. |
| `MAX_TH_P` | 2000 | Threshold ceiling. |
| `STEP_UP_P` | 5 | Threshold rise aggressiveness in noisy environments. |
| `STEP_DN_P` | 5 | Threshold drop aggressiveness in quiet environments. |
| `HI_DELTA_P` | 200 | Delta level above which threshold starts stepping up. |
| `LO_DELTA_P` | 20 | Delta level below which threshold starts stepping down. |

---

## Notes on Guardian Sideband

The Guardian Sideband (Module 107) runs on an **ungated clock** by design — this is intentional. Its purpose is to remain observable even when the main clock is fully gated, which is essential for watchdog compliance in safety-critical applications (defense, automotive, medical).

This means the Guardian continuously consumes a small amount of static power regardless of main clock state. For applications where Guardian observability is not required, the module can be excluded from synthesis by removing the instantiation — the core wake_en functionality is unaffected.

## What is not in this repository

**C-HAL library (`rpu.c` / `rpu.h`):** Available on request — email ozcan.demirkiran@rpu-micro.com with subject "C-HAL request". Enables runtime threshold tuning via memory-mapped registers without re-synthesis. Runs the same ΔC/Δt logic on any microcontroller — STM32, ESP32, ARM Cortex-M, RISC-V.

**Full ASIC PPA reports:** Available on request. Cadence Genus synthesis at TSMC 65nm and SkyWater SKY130.

**RISC-V Ibex SoC testbench:** Available on request. Complete lowRISC SoC environment where the 99.998% cycle reduction was measured.

---

## Frequently asked questions

**"We already use WFI and interrupts — isn't that the same thing?"**

WFI + interrupt is a good system and sufficient for many applications. The RPU addresses three specific gaps: (1) Standard interrupts fire on every signal transition including noise and drift — the RPU applies a rate-of-change threshold in hardware so false wake-ups are suppressed before they reach the interrupt pin. (2) ARM Cortex-M NVIC entry takes 15–20 cycles minimum. The RPU decision is combinational — always 2 cycles, guaranteed. (3) Interrupt timing is non-deterministic if the CPU is executing another task. The RPU is hardware-native so 2 cycles is constant regardless of CPU state.

**"We already have smart sensors and DMA controllers."**

Smart sensors and DMA reduce CPU involvement but do not eliminate switching activity. When a smart sensor detects activity it raises an interrupt, DMA moves data to memory, and eventually the CPU processes it. Even during stagnant periods, the clock tree is still running, the bus is still toggling, and buffers are still switching. The RPU operates before data reaches the bus — when data is unchanged, downstream switching activity is suppressed at the source, not just CPU wake-ups.

**"We already use DVFS and PMU."**

DVFS and PMU operate through software layers with millisecond-scale latency and no data-change awareness. They reduce power when the OS decides to reduce it. The RPU reduces power when the data is actually stagnant — in hardware, before any software is involved. The two approaches are complementary, not competing.

**"Can't a simple comparator do this?"**

A fixed-threshold comparator wakes the CPU whenever the signal crosses a threshold — including noise, drift, and meaningless fluctuations. The RPU measures the rate of change over a sliding window, so a single noisy spike looks different from a genuine sustained change. The adaptive threshold engine automatically adjusts — rising in noisy environments, falling in quiet ones — without software involvement.

**"What if I need to remove it later?"**

Disconnect wake_en or remove the instantiation entirely. The system reverts to conventional polling with zero latency difference and zero data loss. The RPU is strictly parallel and not in the critical data path. There is no failure mode where removing the RPU makes your system worse than it was before.

**"Does DEPTH affect wake-up latency?"**

No. DEPTH only controls the sliding window size — how many samples are used to compute the delta. Regardless of DEPTH (32, 64, 128, or any valid value), the combinational decision path is identical and the processor always wakes in exactly 2 clock cycles.

**"Does it work with ARM Cortex-M?"**

Yes. Connect wake_en to any NVIC line. The CPU sees a standard level-triggered external interrupt and runs the existing ISR unchanged. No firmware modifications required.

**"Is the 99.998% number real or modeled?"**

It is a physical measurement. lowRISC Ibex RISC-V core, Verilator simulator, 5,000,004 clock cycles, stable sensor data scenario. 5,000,000 baseline active cycles reduced to 125 with the RPU connected. The testbench is in this repository — run it yourself and see the same output.

**"What about multi-bit or wide data buses?"**

Set DATA_WIDTH to match your bus width. The architecture scales automatically — the delta computation uses bit-shift operations that are width-independent. Verify SUM_W headroom when DATA_WIDTH exceeds 12.

## Advanced integration notes

**SRAM macro substitution:** The ring buffer (Module 102) is implemented as flip-flop registers by default. At tape-out, replacing the register array with an SRAM macro reduces sequential cell area proportionally — the RTL interface is unchanged, only the state store implementation is swapped. This is particularly beneficial at DEPTH ≥ 64.

**DATA_WIDTH:** Default is 12-bit (matching a 12-bit ADC). Set to 8 for 8-bit sensors, 16 for 16-bit ADCs. The entire datapath scales automatically. SUM_W adjusts accordingly — verify accumulator headroom when widening.

**Multi-clock domain:** The RPU operates in a single clock domain. If your sensor interface and processor run on different clocks, add a standard 2-FF synchronizer on in_data/in_valid before the RPU input. wake_en output to the interrupt controller is a level signal and can be synchronized similarly.

**Reset synchronization:** rst_n is asynchronous active-low. In systems with a synchronous reset domain, add a reset synchronizer cell before driving rst_n. This is standard practice and does not affect functionality.

**DFT / scan:** scan_en is provided for full-scan insertion. Tie to 0 in functional mode. Connect to your scan chain enable in DFT mode — no special handling required beyond standard scan methodology.

**Power gating:** The wake_en output can drive a sleep transistor gate directly (header or footer) in addition to the interrupt controller. When delta is below threshold, wake_en = 0 and the sleep transistor physically cuts power to downstream logic. This is the full power gating path described in the patent.

**Area scaling at advanced nodes:** At 28nm and below, the same RTL synthesizes to significantly smaller area while maintaining functional equivalence. The 2,960-gate figure is specific to TSMC 65nm. Expect roughly 40-50% area reduction per node generation.

## Known design trade-offs

> **Note on DEPTH and wake-up latency:** The DEPTH parameter only affects the sliding window size — how many samples are used to compute the delta. It does not affect the wake-up latency. Regardless of DEPTH (32, 64, 128, or any valid value), the combinational decision path is identical and the processor always wakes in exactly 2 clock cycles.

| Trade-off | Detail | Impact |
|-----------|--------|--------|
| Guardian ungated clock | Runs continuously for watchdog compliance | Small static power overhead |
| 2-stage pipeline | Stage-A captures, Stage-B computes delta | 2-cycle latency by design (not a bug) |
| Accumulator width | SUM_W = DATA_WIDTH + log₂(DEPTH/2) | Must be verified when DEPTH > 32 |
| Dead zone in adaptive threshold | No adjustment when LO_DELTA < delta < HI_DELTA | Intentional stability band — prevents threshold oscillation on borderline signals |

**Tuning for slow drift applications (Scenario 3 optimization):** The default parameters (HI_DELTA=200, LO_DELTA=20) create a wide dead zone that prioritizes stability over sensitivity. In applications with gradual environmental drift — temperature sensors, pressure monitors, slowly varying signals — narrowing the dead zone improves suppression:

```systemverilog
// Default (stable environments, noise-heavy signals)
.HI_DELTA_P (200),
.LO_DELTA_P (20),

// Optimized for slow drift detection
.HI_DELTA_P (80),   // Threshold steps up sooner in noisy conditions
.LO_DELTA_P (40),   // Threshold steps down sooner when signal quiets
.STEP_UP_P  (10),   // Faster desensitization
.STEP_DN_P  (3),    // Slower resensitization (conservative)
```

This trades some stability for faster adaptation to drifting baselines. The 70.3% result in Scenario 3 (slow drift + large anomaly) reflects the default conservative tuning — with narrow dead zone parameters, this scenario improves significantly.

## License

This RTL is released for **research and evaluation purposes only**.

This is **not** a standard Apache 2.0 license. The LICENSE file in this repository is Apache 2.0 with a commercial use restriction added.

- Research, academic, and evaluation use: **free**
- Commercial use (SoC integration, tape-out, product deployment): **requires a written license agreement**

Contact ozcan.demirkiran@rpu-micro.com for commercial licensing.

The underlying architecture is protected by international patent PCT/IB2026/053070 (153 WIPO member countries). The patent covers the architectural principle — using temporal rate of change (ΔC/Δt) as the primary signal for autonomous hardware gating decisions. Reimplementing the same concept in a different HDL, topology, or process node does not circumvent the patent.

For commercial licensing inquiries: ozcan.demirkiran@rpu-micro.com

---

## Contact

**Özcan Demirkıran** — Founder & Principal Architect  
RPU Microelectronics · Kocaeli, Turkey  
ozcan.demirkiran@rpu-micro.com  
+90 536 636 10 72  
[rpu-micro.com](https://rpu-micro.com)  

Patent: PCT/IB2026/053070 · TR 2025/012696  
TÜRKPATENT confirmed novel over HP US8450711B2 and IBM US11144718B2.  
GitHub: [github.com/Rpu-Microelectronics/rpu-microelectronics](https://github.com/Rpu-Microelectronics/rpu-microelectronics)
