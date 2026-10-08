// =============================================================================
// 5.  SELF-CHECKING TESTBENCH
//     - Pipeline-aligned reference model (Stage-A / Stage-B)
//     - Compares delta / threshold / event / full_status on every sample
//     - 8 test scenarios covering: reset, warm-up, constant, step, wrap-around,
//       random-valid stress, threshold saturation, guardian monitor
//     - PASS / FAIL verdict + timeout guard
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_rpu_ultimate_final;

    // -------------------------------------------------------------------------
    // TB parameters — must match DUT instantiation below
    // -------------------------------------------------------------------------
    localparam int DATA_WIDTH    = 12;
    localparam int DEPTH         = 32;
    localparam int HALF          = DEPTH / 2;
    localparam int HALF_LOG2     = $clog2(HALF);
    localparam int SUM_W         = DATA_WIDTH + $clog2(DEPTH);

    localparam bit USE_DYNAMIC_TH = 1'b1;
    localparam int FIXED_TH       = 100;
    localparam int MIN_TH_P       = 10;
    localparam int MAX_TH_P       = 2000;
    localparam int STEP_UP_P      = 5;
    localparam int STEP_DN_P      = 5;
    localparam int HI_DELTA_P     = 200;
    localparam int LO_DELTA_P     = 20;

    // -------------------------------------------------------------------------
    // DUT signals
    // -------------------------------------------------------------------------
    logic clk, rst_n;
    logic in_valid, scan_en;
    logic [DATA_WIDTH-1:0] in_data;

    wire  rpu_event_pulse;
    wire  rpu_state;
    wire  wake_en;
    wire  [DATA_WIDTH-1:0] delta_abs_dbg;
    wire  [DATA_WIDTH-1:0] threshold_dbg;
    wire  full_status;
    wire  gclk_out;
    wire  guardian_alert;
    wire  [DATA_WIDTH-1:0] guardian_last_data;
    wire  [DATA_WIDTH-1:0] guardian_last_delta;
    wire  [DATA_WIDTH-1:0] guardian_last_th;

    // -------------------------------------------------------------------------
    // DUT instantiation
    // -------------------------------------------------------------------------
    rpu_ultimate_final rpu_ultimate_final (
        .clk                (clk),
        .rst_n              (rst_n),
        .in_valid           (in_valid),
        .in_data            (in_data),
        .scan_en            (scan_en),
        .rpu_event_pulse    (rpu_event_pulse),
        .rpu_state          (rpu_state),
        .wake_en            (wake_en),
        .delta_abs_dbg      (delta_abs_dbg),
        .threshold_dbg      (threshold_dbg),
        .full_status        (full_status),
        .gclk_out           (gclk_out),
        .guardian_alert     (guardian_alert),
        .guardian_last_data (guardian_last_data),
        .guardian_last_delta(guardian_last_delta),
        .guardian_last_th   (guardian_last_th)
    );

    // Gate-level run: give the SDF file with +define+RPU_SDF="<path>/rpu_ultimate_final_m.sdf" (no SDF: zero-delay netlist).
    // The VCD feeds the activity-based power analysis; +define+RPU_NO_VCD skips it.
`ifdef RPU_SDF
    initial $sdf_annotate(`RPU_SDF, rpu_ultimate_final, , , "MAXIMUM", , );
`endif
`ifndef RPU_NO_VCD
    initial begin
        $dumpfile("rpu_ultimate_final.vcd");
        $dumpvars(0, tb_rpu_ultimate_final.rpu_ultimate_final);
        $dumpon;
    end
`endif

    // -------------------------------------------------------------------------
    // Clock: 100 MHz
    // -------------------------------------------------------------------------
    initial clk = 1'b0;
    always  #5 clk = ~clk;

    // -------------------------------------------------------------------------
    // Error tracking
    // -------------------------------------------------------------------------
    int error_count = 0;

    task automatic fail(input string msg);
        error_count++;
        $display("[%0t] FAIL: %s", $time, msg);
    endtask

    task automatic clk_delay(input int n);
        repeat(n) @(posedge clk);
    endtask

    // -------------------------------------------------------------------------
    // Common per-sample checks
    // -------------------------------------------------------------------------
    task automatic check_no_x();
        if ($isunknown(rpu_event_pulse)) fail("rpu_event_pulse is X/Z");
        if ($isunknown(delta_abs_dbg))   fail("delta_abs_dbg is X/Z");
        if ($isunknown(threshold_dbg))   fail("threshold_dbg is X/Z");
        if ($isunknown(full_status))     fail("full_status is X/Z");
        if ($isunknown(wake_en))         fail("wake_en is X/Z");
    endtask

    task automatic check_warmup_guard();
        if (!full_status && rpu_event_pulse)
            fail("Warm-up violation: rpu_event_pulse asserted while full_status=0");
    endtask

    // -------------------------------------------------------------------------
    // Pipeline-aligned Reference Model
    //
    //   Mirrors Stage-A and Stage-B exactly, including:
    //     - pre-increment warmup_to_old flag
    //     - post-update (next-sum) delta computation
    //     - event using PRE-update threshold (matches DUT)
    //     - threshold update using post-update delta (matches DUT)
    // -------------------------------------------------------------------------
    logic [DATA_WIDTH-1:0] ref_mem [0:DEPTH-1];
    int unsigned           ref_wr_ptr;
    int unsigned           ref_count;
    logic                  ref_full;
    logic [SUM_W-1:0]      ref_sum_new;
    logic [SUM_W-1:0]      ref_sum_old;
    logic [DATA_WIDTH-1:0] ref_threshold;
    // [aligned] expectation queue (declared before ref_reset, which clears it); packed so Icarus accepts it
    typedef struct packed { int due; logic full; logic [DATA_WIDTH-1:0] delta; logic [DATA_WIDTH-1:0] th_after; logic ev; int idx; } exp_t;
    logic [$bits(exp_t)-1:0] exp_q[$];   // queue of packed expectations (Icarus has no queues of structs)
    int edge_cnt = 0;
    int sample_idx = 0;

    // Stage-A / Stage-B pipeline registers for reference model
    logic                  pipe_vld        [0:1];
    logic [DATA_WIDTH-1:0] pipe_din        [0:1];
    logic                  pipe_full       [0:1];
    logic                  pipe_warmup_old [0:1];
    int unsigned           pipe_tail       [0:1];
    int unsigned           pipe_mid        [0:1];

    function automatic int unsigned ref_inc(input int unsigned a);
        return (a == (DEPTH-1)) ? 0 : (a + 1);
    endfunction

    function automatic int unsigned ref_add_half(input int unsigned a);
        return (a < (DEPTH - HALF)) ? (a + HALF) : (a - (DEPTH - HALF));
    endfunction

    // Compute post-update delta from the reference model's next sums
    function automatic logic [DATA_WIDTH-1:0] ref_delta_next(
        input logic [SUM_W-1:0] sn,
        input logic [SUM_W-1:0] so
    );
        logic [DATA_WIDTH-1:0] an, ao;
        an = sn >> HALF_LOG2;
        ao = so >> HALF_LOG2;
        return (an > ao) ? (an - ao) : (ao - an);
    endfunction

    // Saturating threshold update (matches DUT Policy Engine)
    function automatic logic [DATA_WIDTH-1:0] ref_th_update(
        input logic [DATA_WIDTH-1:0] th,
        input logic [DATA_WIDTH-1:0] delta
    );
        if (delta > HI_DELTA_P[DATA_WIDTH-1:0]) begin
            if (th <= (MAX_TH_P[DATA_WIDTH-1:0] - STEP_UP_P[DATA_WIDTH-1:0]))
                return th + STEP_UP_P[DATA_WIDTH-1:0];
            else
                return MAX_TH_P[DATA_WIDTH-1:0];
        end else if (delta < LO_DELTA_P[DATA_WIDTH-1:0]) begin
            if (th >= (MIN_TH_P[DATA_WIDTH-1:0] + STEP_DN_P[DATA_WIDTH-1:0]))
                return th - STEP_DN_P[DATA_WIDTH-1:0];
            else
                return MIN_TH_P[DATA_WIDTH-1:0];
        end
        return th;
    endfunction

    task automatic ref_reset();
        int i;
        for (i = 0; i < DEPTH; i++) ref_mem[i] = '0;
        ref_wr_ptr    = 0;
        ref_count     = 0;
        ref_full      = 1'b0;
        ref_sum_new   = '0;
        ref_sum_old   = '0;
        ref_threshold = MIN_TH_P[DATA_WIDTH-1:0];
        exp_q.delete();   // [Faz 2 aligned]
        for (i = 0; i < 2; i++) begin
            pipe_vld[i]        = 1'b0;
            pipe_din[i]        = '0;
            pipe_full[i]       = 1'b0;
            pipe_warmup_old[i] = 1'b1;
            pipe_tail[i]       = 0;
            pipe_mid[i]        = 0;
        end
    endtask

    // -------------------------------------------------------------------------
    // send_sample — drives DUT + advances reference model + compares outputs
    // -------------------------------------------------------------------------
    // [aligned] checker: compare queued expectations at capture edge + 2, the edge where the DUT registers its outputs
    // (the original TB compared one edge early, so the DUT looked one sample behind the reference)
    exp_t chk;
    always @(posedge clk) edge_cnt <= edge_cnt + 1;
    always @(posedge clk) begin
        #1;
        while (exp_q.size() > 0) begin
            chk = exp_q[0];
            if (chk.due > edge_cnt) break;
            if (chk.due == edge_cnt && chk.full && !rst_n)
                $display("[%0t] NOTE: sample=%0d result due while rst_n=0 (cleared by the reset that starts the next test): not compared", $time, chk.idx);
            if (chk.due == edge_cnt && chk.full && rst_n) begin
                if (delta_abs_dbg !== chk.delta)
                    fail($sformatf("delta mismatch. sample=%0d DUT=%0d REF=%0d", chk.idx, delta_abs_dbg, chk.delta));
                if (threshold_dbg !== chk.th_after)
                    fail($sformatf("threshold mismatch. sample=%0d DUT=%0d REF=%0d", chk.idx, threshold_dbg, chk.th_after));
                if (rpu_event_pulse !== chk.ev)
                    fail($sformatf("event mismatch. sample=%0d DUT=%0b REF=%0b", chk.idx, rpu_event_pulse, chk.ev));
                if (wake_en !== chk.ev)
                    fail($sformatf("wake_en mismatch. sample=%0d DUT=%0b REF=%0b", chk.idx, wake_en, chk.ev));
            end
            void'(exp_q.pop_front());
        end
    end

    task automatic send_sample(input logic [DATA_WIDTH-1:0] d);
        logic [DATA_WIDTH-1:0] tail_old, mid_old;
        logic [SUM_W-1:0]      sn_next, so_next;
        logic [DATA_WIDTH-1:0] delta_ref, th_now;
        logic                  exp_event, full_a, warm_a;
        int unsigned           tail_a, mid_a;
        exp_t                  e;

        // --- Stage-A: capture (pre-increment) ---
        full_a = ref_full;
        warm_a = (!ref_full && (ref_count < HALF));
        tail_a = ref_wr_ptr;
        mid_a  = ref_add_half(ref_wr_ptr);
        ref_wr_ptr = ref_inc(ref_wr_ptr);
        if (!ref_full) begin
            if (ref_count == (DEPTH-1)) ref_full = 1'b1;
            ref_count++;
        end

        // --- Drive DUT ---
        @(negedge clk);
        in_valid = 1'b1;
        in_data  = d;
        @(posedge clk); #1;
        in_valid = 1'b0;

        // --- Stage-B for THIS sample (same arithmetic as before) ---
        sn_next = ref_sum_new;
        so_next = ref_sum_old;
        tail_old = ref_mem[tail_a];
        mid_old  = ref_mem[mid_a];
        ref_mem[tail_a] = d;
        if (!full_a) begin
            if (warm_a) so_next = ref_sum_old + d;
            else        sn_next = ref_sum_new + d;
        end else begin
            sn_next = (ref_sum_new - mid_old)  + d;
            so_next = (ref_sum_old - tail_old) + mid_old;
        end
        delta_ref = ref_delta_next(sn_next, so_next);
        th_now    = USE_DYNAMIC_TH ? ref_threshold : FIXED_TH[DATA_WIDTH-1:0];
        exp_event = full_a && (delta_ref > th_now);
        if (USE_DYNAMIC_TH && full_a)
            ref_threshold = ref_th_update(ref_threshold, delta_ref);
        ref_sum_new = sn_next;
        ref_sum_old = so_next;

        // queue the expectation for the DUT's output register edge (capture edge + 2)
        e.due = edge_cnt + 2; e.full = full_a; e.delta = delta_ref;
        e.th_after = USE_DYNAMIC_TH ? ref_threshold : FIXED_TH[DATA_WIDTH-1:0];
        e.ev = exp_event; e.idx = sample_idx; sample_idx++;
        exp_q.push_back(e);

        // --- Common checks (unchanged) ---
        check_no_x();
        check_warmup_guard();
    endtask

    // Random data helpers
    int unsigned seed = 32'hDEAD_C0DE;

    function automatic logic [DATA_WIDTH-1:0] rand_data();
        rand_data = $urandom(seed);
    endfunction

    // -------------------------------------------------------------------------
    // MAIN TEST FLOW
    // -------------------------------------------------------------------------
    initial begin
        $display("==================================================");
        $display("TB START: RPU_Ultimate_Final v2.0");
        $display("==================================================");

        scan_en  = 1'b0;
        in_valid = 1'b0;
        in_data  = '0;
        ref_reset();

        // ------------------------------------------------------------------ //
        // T1: Reset sanity                                                    //
        // ------------------------------------------------------------------ //
        $display("T1: Reset sanity...");
        rst_n = 1'b0; clk_delay(4);
        rst_n = 1'b1; clk_delay(2);

        if (full_status)
            fail("T1: full_status asserted after reset");
        if (rpu_event_pulse)
            fail("T1: rpu_event_pulse asserted after reset");
        if (wake_en)
            fail("T1: wake_en asserted after reset");
        if (threshold_dbg !== MIN_TH_P[DATA_WIDTH-1:0])
            fail($sformatf("T1: threshold not MIN_TH after reset. Got %0d", threshold_dbg));

        $display("T1: PASS");

        // ------------------------------------------------------------------ //
        // T2: Warm-up protection — DEPTH samples, zero events, then full=1   //
        // ------------------------------------------------------------------ //
        $display("T2: Warm-up protection...");
        for (int i = 0; i < DEPTH; i++) begin
            send_sample(12'd500);
            if (rpu_event_pulse) fail("T2: event fired during warm-up");
            if (wake_en)         fail("T2: wake_en asserted during warm-up");
        end
        clk_delay(2);
        if (!full_status) fail("T2: full_status not asserted after DEPTH samples");
        $display("T2: PASS");

        // ------------------------------------------------------------------ //
        // T3: Constant signal — delta=0, no events                           //
        // ------------------------------------------------------------------ //
        $display("T3: Constant signal (delta=0)...");
        for (int i = 0; i < DEPTH; i++) begin
            send_sample(12'd500);
            if (rpu_event_pulse) fail("T3: event fired on constant input");
        end
        $display("T3: PASS");

        // ------------------------------------------------------------------ //
        // T4: Large step change — at least one event expected                //
        // ------------------------------------------------------------------ //
        $display("T4: Large step change...");
        for (int i = 0; i < DEPTH; i++) send_sample(12'd100);
        begin
            int ev_cnt;
            ev_cnt = 0;
            for (int i = 0; i < DEPTH; i++) begin
                send_sample(12'd3800);
                if (rpu_event_pulse) ev_cnt++;
            end
            if (ev_cnt == 0)
                fail("T4: no events observed after large step change");
            else
                $display("T4: PASS (events observed=%0d)", ev_cnt);
        end

        // ------------------------------------------------------------------ //
        // T5: Pointer wrap-around robustness (6x buffer depth)               //
        // ------------------------------------------------------------------ //
        $display("T5: Pointer wrap-around robustness...");
        rst_n = 1'b0; clk_delay(2);
        rst_n = 1'b1; ref_reset(); clk_delay(2);
        for (int i = 0; i < DEPTH*6; i++) send_sample(rand_data());
        $display("T5: PASS");

        // ------------------------------------------------------------------ //
        // T6: Random valid stress (70% valid, 30% idle)                      //
        // ------------------------------------------------------------------ //
        $display("T6: Random valid stress (70%% duty)...");
        rst_n = 1'b0; clk_delay(2);
        rst_n = 1'b1; ref_reset(); clk_delay(2);
        for (int i = 0; i < DEPTH*10; i++) begin
            if ($urandom_range(0, 99) < 70) begin
                send_sample(rand_data());
            end else begin
                @(negedge clk);
                in_valid = 1'b0;
                @(posedge clk);
                check_no_x();
                check_warmup_guard();
            end
        end
        $display("T6: PASS");

        // ------------------------------------------------------------------ //
        // T7: Threshold saturation bounds                                     //
        // ------------------------------------------------------------------ //
        $display("T7: Threshold saturation bounds...");
        rst_n = 1'b0; clk_delay(2);
        rst_n = 1'b1; ref_reset(); clk_delay(2);
        for (int i = 0; i < DEPTH; i++) send_sample(12'd100);  // fill

        // Push threshold up toward MAX
        for (int i = 0; i < DEPTH*8; i++) begin
            send_sample(i[0] ? 12'd0 : 12'd4095);
            if (threshold_dbg > MAX_TH_P[DATA_WIDTH-1:0])
                fail($sformatf("T7: threshold exceeded MAX_TH. Got %0d", threshold_dbg));
        end

        // Pull threshold down toward MIN
        for (int i = 0; i < DEPTH*8; i++) begin
            send_sample(12'd2048);
            if (threshold_dbg < MIN_TH_P[DATA_WIDTH-1:0])
                fail($sformatf("T7: threshold below MIN_TH. Got %0d", threshold_dbg));
        end
        $display("T7: PASS");

        // ------------------------------------------------------------------ //
        // T8: Guardian sideband monitor                                       //
        // ------------------------------------------------------------------ //
        $display("T8: Guardian sideband monitor...");
        rst_n = 1'b0; clk_delay(2);
        rst_n = 1'b1; ref_reset(); clk_delay(2);
        for (int i = 0; i < DEPTH; i++) send_sample(12'd100);
        for (int i = 0; i < DEPTH; i++) send_sample(12'd3800);

        if ($isunknown(guardian_alert))
            fail("T8: guardian_alert is X/Z");
        if ($isunknown(guardian_last_data))
            fail("T8: guardian_last_data is X/Z");
        if ($isunknown(guardian_last_delta))
            fail("T8: guardian_last_delta is X/Z");
        if ($isunknown(guardian_last_th))
            fail("T8: guardian_last_th is X/Z");
        $display("T8: PASS");

        // ------------------------------------------------------------------ //
        // VERDICT                                                             //
        // ------------------------------------------------------------------ //
        clk_delay(10);
        $display("==================================================");
        if (error_count == 0)
            $display("RESULT: PASS — All tests passed. Errors=0");
        else
            $display("RESULT: FAIL — Total errors=%0d", error_count);
        $display("==================================================");
        $finish;
    end

    // Timeout guard — simulation must complete within this window
    initial begin
        #5_000_000;
        $display("==================================================");
        $display("RESULT: TIMEOUT — Simulation exceeded maximum time.");
        $display("==================================================");
        $finish;
    end

endmodule  // tb_rpu_ultimate_final

`default_nettype wire
