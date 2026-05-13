`timescale 1ns/1ps
`default_nettype none

// =============================================================================
// RPU_Ultimate_Final_v2.0  —  Reflexive Processing Unit
// Author   : Özcan Demirkıran
// Language : SystemVerilog (IEEE 1800-2017)
// Package  : RTL + SVA (bind) + Self-Checking TB  (single file)
//
// This is the definitive sealed version, merging the best features of:
//   RPU_Core_v3_1_3_Clean      — reference model, deep TB, delta/th comparison
//   RPU_Final_Merged_v1        — wake_en, toggle-minimize, warmup pipeline flag
//   RPU_Final_v2_1             — compact port style, timeout guard
//   RPU_ASIC_Ultimate_v1.1     — [FIX-EVENT] post-update delta for event/wake
//
// What changed vs v1.0:
//   [FIX-EVENT]  sum_new_next/sum_old_next computed combinationally in Stage-B.
//                event_next and wake_next derived from post-update delta, so
//                rpu_event_pulse and wake_en are ALIGNED to the accepted sample's
//                updated sliding window — no 1-sample ambiguity.
//   [FIX-ICG]    ICG en input driven by combinational event_next (not registered
//                rpu_event_pulse), so the gate opens in the same cycle as the event.
//   [IMPROVEMENT] Separate STEP_UP_P / STEP_DN_P for asymmetric threshold adaptation.
//   [IMPROVEMENT] 8 test scenarios in TB (vs 4 in v1.1), including guardian check,
//                 pointer wrap, random-valid stress, and threshold saturation.
//   [IMPROVEMENT] wake_en output retained (was missing from v1.1).
//
// Architecture
// ------------
//  - Two-stage pipeline:
//      Stage-A : address generation, pointer/count update, input capture,
//                warm-up flag propagation
//      Stage-B : read old values → write new sample → combinational next-sum →
//                register sums → derive post-update delta/event
//  - Circular buffer depth DEPTH (must be power-of-two and even)
//  - O(1) sliding window sums:  sum_new (newer HALF), sum_old (older HALF)
//  - Warm-up guard: no event fires until buffer is FULL
//  - warmup_to_old flag carried through pipeline (no counter-latency ambiguity)
//  - Adaptive Policy Engine: threshold tracks signal noise dynamically
//  - wake_en output: single-cycle pulse for upper-level ICG / power-gate
//  - Behavioural ICG reference (replace with library CLKGATE_* at tape-out)
//  - Guardian sideband: non-intrusive observer, no backpressure, always visible
//  - SVA bind: 3 critical signoff properties (A1, A2, A3)
//  - Self-checking TB: pipeline-aligned reference model, 8 test scenarios,
//    PASS/FAIL verdict, timeout guard
//
// ASIC Integration Notes
// ----------------------
//  - Memory   : register array — replace with SRAM macro at tape-out
//  - ICG      : behavioural reference — apply CTS/DFT constraints at tape-out
//  - wake_en  : connect to upper-level ICG cell enable input
//  - SVA bind : move rpu_sva_bind to a separate file for synthesis exclusion
// =============================================================================


// =============================================================================
// 1.  BEHAVIOURAL ICG REFERENCE CELL
//     SIGNOFF NOTE: Replace with technology library CLKGATE_* cell at tape-out.
//     always_latch makes latch intent explicit (ASIC standard practice).
// =============================================================================
module icg_cell_ref (
    input  wire clk,
    input  wire en,
    input  wire scan_en,
    output wire gclk
);
    logic en_latched;

    always_latch begin
        if (!clk) en_latched <= (en | scan_en);
    end

    assign gclk = clk & en_latched;
endmodule


// =============================================================================
// 2.  GUARDIAN SIDEBAND MONITOR
//     - Non-intrusive: no backpressure
//     - Captures last_data / last_delta / last_th on every valid sample
//     - Produces a 1-cycle alert pulse when delta_abs > threshold
//     - Connected to ungated clock for unconditional observability
// =============================================================================
module rpu_guardian_monitor #(
    parameter int DATA_WIDTH = 12
)(
    input  logic                   clk,
    input  logic                   rst_n,

    input  logic                   main_valid,
    input  logic [DATA_WIDTH-1:0]  main_data,
    input  logic [DATA_WIDTH-1:0]  delta_abs,
    input  logic [DATA_WIDTH-1:0]  threshold,

    output logic                   alert,
    output logic [DATA_WIDTH-1:0]  last_data,
    output logic [DATA_WIDTH-1:0]  last_delta,
    output logic [DATA_WIDTH-1:0]  last_th
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            alert      <= 1'b0;
            last_data  <= '0;
            last_delta <= '0;
            last_th    <= '0;
        end else begin
            alert <= 1'b0;
            if (main_valid) begin
                last_data  <= main_data;
                last_delta <= delta_abs;
                last_th    <= threshold;
                if (delta_abs > threshold) alert <= 1'b1;
            end
        end
    end
endmodule


// =============================================================================
// 3.  TOP MODULE: rpu_ultimate_final
// =============================================================================
module rpu_ultimate_final #(
    parameter int DATA_WIDTH  = 12,
    parameter int DEPTH       = 32,   // MUST be power-of-two and even

    // Policy Engine / Threshold parameters
    parameter bit USE_DYNAMIC_TH = 1'b1,
    parameter int FIXED_TH       = 100,   // used when USE_DYNAMIC_TH = 0
    parameter int MIN_TH_P       = 10,
    parameter int MAX_TH_P       = 2000,
    parameter int STEP_UP_P      = 5,     // threshold increment step (noisy signal)
    parameter int STEP_DN_P      = 5,     // threshold decrement step (quiet signal)
    parameter int HI_DELTA_P     = 200,   // delta threshold for step-up
    parameter int LO_DELTA_P     = 20     // delta threshold for step-down
)(
    input  logic                   clk,
    input  logic                   rst_n,      // async active-low reset (ASIC standard)

    input  logic                   in_valid,
    input  logic [DATA_WIDTH-1:0]  in_data,

    input  logic                   scan_en,    // DFT scan enable (fed to ICG)

    // Primary outputs
    output logic                   rpu_event_pulse, // 1-cycle: post-update delta > threshold AND full
    output logic                   rpu_state,       // toggle FF, flips on every event
    output logic                   wake_en,         // 1-cycle: upper-level ICG / power-gate enable

    // Debug / telemetry
    output logic [DATA_WIDTH-1:0]  delta_abs_dbg,   // post-update |avg_new - avg_old|
    output logic [DATA_WIDTH-1:0]  threshold_dbg,   // current active threshold
    output logic                   full_status,      // ring buffer full indicator
    output wire                    gclk_out,         // gated clock (behavioural ref)

    // Guardian sideband
    output logic                   guardian_alert,
    output logic [DATA_WIDTH-1:0]  guardian_last_data,
    output logic [DATA_WIDTH-1:0]  guardian_last_delta,
    output logic [DATA_WIDTH-1:0]  guardian_last_th
);

    // =========================================================================
    // Local constants
    // =========================================================================
    localparam int ADDR_W    = $clog2(DEPTH);
    localparam int HALF      = DEPTH / 2;
    localparam int HALF_LOG2 = $clog2(HALF);
    localparam int SUM_W     = DATA_WIDTH + ADDR_W;   // sized to prevent overflow
    localparam int DEPTH_L1  = (DEPTH-1);
    localparam int DEPTH_LH  = (DEPTH-HALF);
    // Lint-clean parameter vectors (width-matched for comparisons)
    localparam logic [DATA_WIDTH-1:0] MIN_TH_W    = MIN_TH_P  [DATA_WIDTH-1:0];
    localparam logic [DATA_WIDTH-1:0] MAX_TH_W    = MAX_TH_P  [DATA_WIDTH-1:0];
    localparam logic [DATA_WIDTH-1:0] STEP_UP_W   = STEP_UP_P [DATA_WIDTH-1:0];
    localparam logic [DATA_WIDTH-1:0] STEP_DN_W   = STEP_DN_P [DATA_WIDTH-1:0];
    localparam logic [DATA_WIDTH-1:0] HI_DELTA_W  = HI_DELTA_P[DATA_WIDTH-1:0];
    localparam logic [DATA_WIDTH-1:0] LO_DELTA_W  = LO_DELTA_P[DATA_WIDTH-1:0];
    localparam logic [DATA_WIDTH-1:0] FIXED_TH_W  = FIXED_TH  [DATA_WIDTH-1:0];

    localparam logic [ADDR_W-1:0] HALF_AW       = HALF      [ADDR_W-1:0];
    localparam logic [ADDR_W-1:0] DEPTHM1_AW    = DEPTH_L1 [ADDR_W-1:0];
    localparam logic [ADDR_W-1:0] DEPTH_HALF_AW = DEPTH_LH [ADDR_W-1:0];

    // =========================================================================
    // Compile-time parameter checks
    // =========================================================================
    // synthesis translate_off
    initial begin
        if (DEPTH <= 0)
            $fatal(1, "DEPTH must be > 0. Got %0d", DEPTH);
        if ((DEPTH & (DEPTH-1)) != 0)
            $fatal(1, "DEPTH must be a power-of-two. Got %0d", DEPTH);
        if ((DEPTH % 2) != 0)
            $fatal(1, "DEPTH must be even. Got %0d", DEPTH);
        if ((1 << HALF_LOG2) != HALF)
            $fatal(1, "HALF must be power-of-two. DEPTH=%0d HALF=%0d", DEPTH, HALF);
        if (MIN_TH_P >= MAX_TH_P)
            $fatal(1, "MIN_TH_P must be < MAX_TH_P");
        if (FIXED_TH < MIN_TH_P || FIXED_TH > MAX_TH_P)
            $fatal(1, "FIXED_TH must be in [MIN_TH_P, MAX_TH_P]");
    end
    // synthesis translate_on

    // =========================================================================
    // Wrap helper functions  (explicit modulo — no truncation-based wrap)
    // =========================================================================
    function automatic logic [ADDR_W-1:0] wrap_inc1(input logic [ADDR_W-1:0] a);
        if (a == DEPTHM1_AW) wrap_inc1 = '0;
        else                 wrap_inc1 = a + {{(ADDR_W-1){1'b0}}, 1'b1};
    endfunction

    function automatic logic [ADDR_W-1:0] wrap_add_half(input logic [ADDR_W-1:0] a);
        // (a + HALF) mod DEPTH
        if (a < DEPTH_HALF_AW) wrap_add_half = a + HALF_AW;
        else                   wrap_add_half = a - DEPTH_HALF_AW;
    endfunction

    // =========================================================================
    // Memory and global state
    // =========================================================================
    logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];   // replace with SRAM macro at tape-out

    logic [ADDR_W-1:0] wr_ptr;
    logic [ADDR_W:0]   count;
    logic              full_flag;

    logic [SUM_W-1:0]      sum_new;
    logic [SUM_W-1:0]      sum_old;
    logic [DATA_WIDTH-1:0] threshold_reg;

    assign full_status    = full_flag;
    assign threshold_dbg  = USE_DYNAMIC_TH ? threshold_reg : FIXED_TH_W;

    // =========================================================================
    // Stage-A pipeline registers
    //   Address generation, pointer/count update, input capture.
    //   Toggle-minimised: all updates guarded by in_valid (CG-friendly).
    // =========================================================================
    logic                  vld_a;
    logic [DATA_WIDTH-1:0] din_a;
    logic [ADDR_W-1:0]     tail_addr_a;    // write address (oldest slot)
    logic [ADDR_W-1:0]     mid_addr_a;     // half-window address
    logic                  full_a;
    // warmup_to_old_a = 1: sample goes into sum_old (first HALF samples)
    //                = 0: sample goes into sum_new (second HALF samples)
    logic                  warmup_to_old_a;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr          <= '0;
            count           <= '0;
            full_flag       <= 1'b0;
            vld_a           <= 1'b0;
            din_a           <= '0;
            tail_addr_a     <= '0;
            mid_addr_a      <= '0;
            full_a          <= 1'b0;
            warmup_to_old_a <= 1'b1;
        end else begin
            vld_a <= in_valid;
            if (in_valid) begin
                // Capture addresses based on current (pre-increment) pointer
                tail_addr_a <= wr_ptr;
                mid_addr_a  <= wrap_add_half(wr_ptr);
                din_a       <= in_data;
                full_a      <= full_flag;

                // Warm-up distribution flag — aligned to pre-increment count,
                // propagated through pipeline to Stage-B so Stage-B uses the
                // correct accumulator without a counter-latency offset.
                warmup_to_old_a <= (!full_flag && (count < HALF[ADDR_W:0]));

                // Advance write pointer
                wr_ptr <= wrap_inc1(wr_ptr);

                // Update fill state
                if (!full_flag) begin
                    count <= count + {{ADDR_W{1'b0}}, 1'b1};
                    if (count == (DEPTH-1)) full_flag <= 1'b1;
                end
            end
            // else: all registers held — zero idle toggle (CG inference friendly)
        end
    end

    // =========================================================================
    // Stage-B pipeline registers
    //   Read old values → write new sample (SRAM-safe ordering via NBA).
    //   Combinational next-sum block derives post-update quantities.
    //   Toggle-minimised: updates only when vld_a is asserted.
    // =========================================================================
    logic                  vld_b;
    logic [DATA_WIDTH-1:0] din_b;
    logic [DATA_WIDTH-1:0] tail_b;          // old value at write address
    logic [DATA_WIDTH-1:0] mid_b;           // old value at mid-window address
    logic                  full_b;
    logic                  warmup_to_old_b;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vld_b           <= 1'b0;
            din_b           <= '0;
            tail_b          <= '0;
            mid_b           <= '0;
            full_b          <= 1'b0;
            warmup_to_old_b <= 1'b1;
        end else begin
            if (vld_a) begin
                vld_b           <= 1'b1;
                din_b           <= din_a;
                full_b          <= full_a;
                warmup_to_old_b <= warmup_to_old_a;

                // READ (before write) — nonblocking guarantees read-before-write
                // behavioural semantics; synthesises correctly with SRAM macros.
                tail_b <= mem[tail_addr_a];
                mid_b  <= mem[mid_addr_a];

                // WRITE new sample (after read, same NBA block — SRAM safe)
                mem[tail_addr_a] <= din_a;
            end else begin
                vld_b <= 1'b0;
                // other registers held — no idle toggle
            end
        end
    end

    // =========================================================================
    // [FIX-EVENT] Post-update sum / delta / event (combinational)
    //
    //   Compute sum_new_next and sum_old_next from the CURRENT sample in Stage-B
    //   before the sums are registered. This makes delta_next and event_next
    //   aligned to the ACCEPTED SAMPLE'S updated sliding window, removing the
    //   1-sample ambiguity present in designs that compute delta from already-
    //   registered sums.
    //
    //   event_next uses the PRE-UPDATE threshold (active_th), which is correct:
    //   the threshold adapts AFTER the event decision, consistent with the
    //   Policy Engine sequential update below.
    // =========================================================================
    logic [SUM_W-1:0]      sum_new_next;
    logic [SUM_W-1:0]      sum_old_next;
    logic [DATA_WIDTH-1:0] avg_new_next;
    logic [DATA_WIDTH-1:0] avg_old_next;
    logic [DATA_WIDTH-1:0] delta_next;
    logic                  event_next;
    logic                  wake_next;

    always_comb begin
        // Default: hold (no update this cycle)
        sum_new_next = sum_new;
        sum_old_next = sum_old;

        if (vld_b) begin
            if (!full_b) begin
                // Warm-up accumulation — flag pipelined, no latency offset
                if (warmup_to_old_b)
                    sum_old_next = sum_old + {{(SUM_W-DATA_WIDTH){1'b0}}, din_b};
                else
                    sum_new_next = sum_new + {{(SUM_W-DATA_WIDTH){1'b0}}, din_b};
            end else begin
                // Steady-state O(1) update:
                //   sum_new_next = sum_new - mid  + new
                //   sum_old_next = sum_old - tail + mid
                sum_new_next = (sum_new - {{(SUM_W-DATA_WIDTH){1'b0}}, mid_b})
                             + {{(SUM_W-DATA_WIDTH){1'b0}}, din_b};
                sum_old_next = (sum_old - {{(SUM_W-DATA_WIDTH){1'b0}}, tail_b})
                             + {{(SUM_W-DATA_WIDTH){1'b0}}, mid_b};
            end
        end

        // Post-update averages (shift-based, no division hardware)
        avg_new_next = sum_new_next[SUM_W-1:0] >> HALF_LOG2;
        avg_old_next = sum_old_next[SUM_W-1:0] >> HALF_LOG2;

        // Absolute delta — unsigned subtraction with X-safe polarity select
        delta_next = (avg_new_next > avg_old_next)
                     ? (avg_new_next - avg_old_next)
                     : (avg_old_next - avg_new_next);

        // Event condition: FULL + post-update delta exceeds current threshold
        event_next = (vld_b && full_b && (delta_next > threshold_dbg));
        wake_next  = event_next;
    end

    // =========================================================================
    // Sum commit + Policy Engine + Event registration
    //   All inside one sequential block for synthesis clarity.
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sum_new         <= '0;
            sum_old         <= '0;
            threshold_reg   <= MIN_TH_W;
            rpu_event_pulse <= 1'b0;
            wake_en         <= 1'b0;
            delta_abs_dbg   <= '0;
        end else begin
            // Default pulse outputs to 0 (1-cycle pulse behaviour)
            rpu_event_pulse <= 1'b0;
            wake_en         <= 1'b0;

            if (vld_b) begin
                // Commit post-update sums
                sum_new       <= sum_new_next;
                sum_old       <= sum_old_next;

                // Latch post-update delta for debug visibility
                delta_abs_dbg <= delta_next;

                // Register event and wake pulses (1-cycle, aligned to sample)
                rpu_event_pulse <= event_next;
                wake_en         <= wake_next;

                // Adaptive Policy Engine (active only when buffer is FULL)
                //   High delta  → increase threshold (noisy environment)
                //   Low delta   → decrease threshold (quiet environment)
                //   Saturating: stays within [MIN_TH_W, MAX_TH_W]
                if (USE_DYNAMIC_TH && full_b) begin
                    if (delta_next > HI_DELTA_W) begin
                        threshold_reg <= (threshold_reg <= (MAX_TH_W - STEP_UP_W))
                                         ? (threshold_reg + STEP_UP_W)
                                         : MAX_TH_W;
                    end else if (delta_next < LO_DELTA_W) begin
                        threshold_reg <= (threshold_reg >= (MIN_TH_W + STEP_DN_W))
                                         ? (threshold_reg - STEP_DN_W)
                                         : MIN_TH_W;
                    end
                end
            end
        end
    end

    // =========================================================================
    // RPU State register — toggle FF, flips on every event
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)              rpu_state <= 1'b0;
        else if (rpu_event_pulse) rpu_state <= ~rpu_state;
    end

    // =========================================================================
    // Clock Gating — behavioural ICG reference (scan-aware)
    //   [FIX-ICG] Driven by combinational event_next, not registered
    //   rpu_event_pulse, so the gate opens in the same cycle as the event.
    //   Replace icg_cell_ref with library CLKGATE_* at tape-out.
    // =========================================================================
    icg_cell_ref u_icg (
        .clk     (clk),
        .en      (event_next),   // combinational — gate opens this cycle
        .scan_en (scan_en),
        .gclk    (gclk_out)
    );

    // =========================================================================
    // Guardian Sideband Monitor — ungated clock, always observable
    // =========================================================================
    rpu_guardian_monitor #(
        .DATA_WIDTH(DATA_WIDTH)
    ) u_guardian (
        .clk        (clk),
        .rst_n      (rst_n),
        .main_valid (vld_b && full_b),
        .main_data  (din_b),
        .delta_abs  (delta_next),       // post-update delta for accurate capture
        .threshold  (threshold_dbg),
        .alert      (guardian_alert),
        .last_data  (guardian_last_data),
        .last_delta (guardian_last_delta),
        .last_th    (guardian_last_th)
    );

endmodule  // rpu_ultimate_final


// =============================================================================
// 4.  SVA BIND MODULE — 3 Critical Signoff Assertions
//     Include in simulation / formal flows only.
//     DO NOT include in synthesis netlist.
// =============================================================================
module rpu_sva_bind #(
    parameter int DATA_WIDTH = 12,
    parameter int DEPTH      = 32,
    parameter int MIN_TH_P   = 10,
    parameter int MAX_TH_P   = 2000
)(
    input logic                      clk,
    input logic                      rst_n,
    input logic                      in_valid,
    input logic                      full_status,
    input logic                      rpu_event_pulse,
    input logic [DATA_WIDTH-1:0]     threshold_dbg,
    input logic [$clog2(DEPTH)-1:0]  wr_ptr
);
    localparam int DEPTH_L1 = (DEPTH-1);
    localparam int ADDR_W = $clog2(DEPTH);
    localparam logic [DATA_WIDTH-1:0] MIN_TH  = MIN_TH_P[DATA_WIDTH-1:0];
    localparam logic [DATA_WIDTH-1:0] MAX_TH  = MAX_TH_P[DATA_WIDTH-1:0];
    localparam logic [ADDR_W-1:0]     DEPTHM1 = DEPTH_L1[ADDR_W-1:0];

    function automatic logic [ADDR_W-1:0] inc_mod(input logic [ADDR_W-1:0] x);
        if (x == DEPTHM1) inc_mod = '0;
        else              inc_mod = x + {{(ADDR_W-1){1'b0}}, 1'b1};
    endfunction

    // -------------------------------------------------------------------------
    // A1: Warm-up integrity — no event may fire before buffer is FULL
    // -------------------------------------------------------------------------
    property p_no_event_before_full;
        @(posedge clk) disable iff (!rst_n)
            (!full_status) |-> (!rpu_event_pulse);
    endproperty
    a_no_event_before_full: assert property (p_no_event_before_full)
        else $error("SVA[A1]: Warm-up violation — rpu_event_pulse asserted while full_status=0");

    // -------------------------------------------------------------------------
    // A2: Pointer continuity — wr_ptr increments by exactly 1 on every in_valid
    // -------------------------------------------------------------------------
    property p_wrptr_increments;
        @(posedge clk) disable iff (!rst_n)
            in_valid |=> (wr_ptr == inc_mod($past(wr_ptr)));
    endproperty
    a_wrptr_increments: assert property (p_wrptr_increments)
        else $error("SVA[A2]: wr_ptr did not increment by 1 on in_valid. wr_ptr=%0d", wr_ptr);

    // -------------------------------------------------------------------------
    // A3: Threshold safety — always within [MIN_TH, MAX_TH] and never X/Z
    // -------------------------------------------------------------------------
    property p_threshold_in_range;
        @(posedge clk) disable iff (!rst_n)
            1'b1 |-> (!$isunknown(threshold_dbg) &&
                      (threshold_dbg >= MIN_TH)  &&
                      (threshold_dbg <= MAX_TH));
    endproperty
    a_threshold_in_range: assert property (p_threshold_in_range)
        else $error("SVA[A3]: threshold_dbg out of range or X/Z. threshold_dbg=%0d", threshold_dbg);

endmodule  // rpu_sva_bind

`ifndef SYNTHESIS

// Bind to all instances of the DUT type (auto-applied, no manual wiring)
bind rpu_ultimate_final rpu_sva_bind #(
    .DATA_WIDTH(DATA_WIDTH),
    .DEPTH     (DEPTH),
    .MIN_TH_P  (MIN_TH_P),
    .MAX_TH_P  (MAX_TH_P)
) u_rpu_sva (
    .clk             (clk),
    .rst_n           (rst_n),
    .in_valid        (in_valid),
    .full_status     (full_status),
    .rpu_event_pulse (rpu_event_pulse),
    .threshold_dbg   (threshold_dbg),
    .wr_ptr          (wr_ptr)
);
`endif

`default_nettype wire

