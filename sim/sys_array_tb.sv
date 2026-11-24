`timescale 1ns/1ps

// ============================================================================
// 1. SYSTOLIC ARRAY INTERFACE (sys_array_if)
// Bundles all signals connecting to the 16x16 Systolic Array DUT.
// Includes driver and monitor clocking blocks to eliminate race conditions.
// ============================================================================
interface sys_array_if #(
    parameter ARR_SIZE = 16
)(
    input logic clk
);
    // Control & Reset
    logic               rst;
    logic               weight_load_en;
    logic               weight_swap_en;

    // Inputs (unpacked arrays matching sys_array RTL ports)
    logic               valid_in       [ARR_SIZE-1:0];
    logic signed [15:0] input_act      [ARR_SIZE-1:0];
    logic signed [15:0] input_weight   [ARR_SIZE-1:0];

    // Outputs
    logic               psum_valid_out [ARR_SIZE-1:0];
    logic signed [39:0] psum_out       [ARR_SIZE-1:0];

    // ------------------------------------------------------------------------
    // Driver Clocking Block:
    // TB samples DUT outputs #1step before posedge clk.
    // TB drives DUT inputs #1ns after posedge clk, preventing delta-cycle races.
    // ------------------------------------------------------------------------
    clocking cb @(posedge clk);
        default input #1step output #1ns;
        output rst;
        output weight_load_en;
        output weight_swap_en;
        output valid_in;
        output input_act;
        output input_weight;
        input  psum_valid_out;
        input  psum_out;
    endclocking

    // ------------------------------------------------------------------------
    // Passive Monitor Clocking Block:
    // Samples all bus transactions #1step before posedge clk (Observed region).
    // ------------------------------------------------------------------------
    clocking mon_cb @(posedge clk);
        default input #1step;
        input  rst;
        input  weight_load_en;
        input  weight_swap_en;
        input  valid_in;
        input  input_act;
        input  input_weight;
        input  psum_valid_out;
        input  psum_out;
    endclocking

endinterface


// ============================================================================
// 2. TRANSACTION CLASS (sys_array_tx)
// Represents a matrix multiplication test transaction on the 16x16 array:
// Contains a 16x16 weight matrix, a sequence of activation vectors,
// and constrained random variables covering all critical corner cases.
// ============================================================================
package sys_array_pkg;

    typedef enum int {
        TEST_ZEROS       = 0, // All zero weights/acts: test zero propagation
        TEST_MAX_POS     = 1, // Max positive values (+32767): test dynamic range & overflow
        TEST_MIN_NEG     = 2, // Min negative values (-32768): test sign extension & negative MAC
        TEST_IDENTITY    = 3, // Identity weight matrix: output must exactly equal input (Y = A)
        TEST_ALTERNATING = 4, // Alternating (+/-) values: test sign cancellation / zero-crossings
        TEST_SPARSE      = 5, // High sparsity (>85% zeros): realistic deep learning activation pattern
        TEST_RANDOM      = 6  // Mixed constrained random distribution across corner & regular ranges
    } test_type_e;

    // Structure for individual column output observation from the monitor
    typedef struct {
        int                 col;
        logic signed [39:0] val;
        time                sim_time;
    } col_out_t;

endpackage

/* verilator lint_off IMPORTSTAR */
import sys_array_pkg::*;
/* verilator lint_on IMPORTSTAR */

class sys_array_tx #(
    parameter ARR_SIZE = 16,
    parameter NUM_VECS = 8
);
    // Test scenario type
    rand test_type_e       test_type;

    // Weight Matrix: [row][col] where weights[r][c] is mapped to PE(r, c)
    rand bit signed [15:0] weight_matrix[ARR_SIZE][ARR_SIZE];

    // Activation Matrix: [vector_index][row]
    rand bit signed [15:0] act_matrix   [NUM_VECS][ARR_SIZE];

    // Valid indicator per activation vector (supports pipeline bubbles)
    rand bit               vec_valid    [NUM_VECS];

    // ------------------------------------------------------------------------
    // Standard SystemVerilog Constraints
    // ------------------------------------------------------------------------
    constraint c_test_type_dist {
        test_type dist {
            TEST_ZEROS       := 10,
            TEST_MAX_POS     := 10,
            TEST_MIN_NEG     := 10,
            TEST_IDENTITY    := 15,
            TEST_ALTERNATING := 15,
            TEST_SPARSE      := 15,
            TEST_RANDOM      := 25
        };
    }

    constraint c_valid_dist {
        foreach (vec_valid[v]) {
            vec_valid[v] dist { 1'b1 := 85, 1'b0 := 15 };
        }
    }

    // Weight distribution constraint targeting corner values
    constraint c_weight_dist {
        foreach (weight_matrix[r, c]) {
            weight_matrix[r][c] dist {
                16'sh0000      := 15, // Zero weight
                16'sh7FFF      := 15, // Max positive (+32767)
                16'sh8000      := 15, // Min negative (-32768)
                16'sh0001      := 5,  // Small positive (+1)
                -16'sh0001     := 5,  // Small negative (-1)
                [-100:100]     := 25, // Small magnitude range
                [-32768:32767] := 20  // Full dynamic range
            };
        }
    }

    // Activation distribution constraint targeting corner values
    constraint c_act_dist {
        foreach (act_matrix[v, r]) {
            act_matrix[v][r] dist {
                16'sh0000      := 15, // Zero activation
                16'sh7FFF      := 15, // Max positive (+32767)
                16'sh8000      := 15, // Min negative (-32768)
                16'sh0001      := 5,  // Small positive (+1)
                -16'sh0001     := 5,  // Small negative (-1)
                [-100:100]     := 25, // Small magnitude range
                [-32768:32767] := 20  // Full dynamic range
            };
        }
    }

    // Helper: generate single 16-bit random operand according to weighted corner case distribution
    function bit signed [15:0] get_random_corner_val();
        int pick = $urandom_range(0, 99);
        if (pick < 15)       return 16'sh0000;              // 0
        else if (pick < 30)  return 16'sh7FFF;              // +32767
        else if (pick < 45)  return 16'sh8000;              // -32768
        else if (pick < 50)  return 16'sh0001;              // +1
        else if (pick < 55)  return -16'sh0001;             // -1
        else if (pick < 80)  return 16'($signed($urandom_range(0, 200)) - 100); // [-100:100]
        else                 return 16'($signed($urandom()));    // Full 16-bit range
    endfunction

    // ------------------------------------------------------------------------
    // Deterministic Corner Case Generation Method
    // Guarantees all corner cases execute reliably across any simulator
    // ------------------------------------------------------------------------
    function void populate_scenario(test_type_e t_type);
        this.test_type = t_type;

        case (t_type)
            TEST_ZEROS: begin
                // All zeros corner case
                for (int r = 0; r < ARR_SIZE; r++) begin
                    for (int c = 0; c < ARR_SIZE; c++) weight_matrix[r][c] = 16'sh0000;
                end
                for (int v = 0; v < NUM_VECS; v++) begin
                    vec_valid[v] = 1'b1;
                    for (int r = 0; r < ARR_SIZE; r++) act_matrix[v][r] = 16'sh0000;
                end
            end

            TEST_MAX_POS: begin
                // Maximum positive saturation (+32767)
                for (int r = 0; r < ARR_SIZE; r++) begin
                    for (int c = 0; c < ARR_SIZE; c++) weight_matrix[r][c] = 16'sh7FFF;
                end
                for (int v = 0; v < NUM_VECS; v++) begin
                    vec_valid[v] = 1'b1;
                    for (int r = 0; r < ARR_SIZE; r++) act_matrix[v][r] = 16'sh7FFF;
                end
            end

            TEST_MIN_NEG: begin
                // Minimum negative saturation (-32768)
                for (int r = 0; r < ARR_SIZE; r++) begin
                    for (int c = 0; c < ARR_SIZE; c++) weight_matrix[r][c] = 16'sh8000;
                end
                for (int v = 0; v < NUM_VECS; v++) begin
                    vec_valid[v] = 1'b1;
                    for (int r = 0; r < ARR_SIZE; r++) act_matrix[v][r] = 16'sh8000;
                end
            end

            TEST_IDENTITY: begin
                // Identity matrix: W = I (diag=1, off-diag=0). Output Y = A * I = A
                for (int r = 0; r < ARR_SIZE; r++) begin
                    for (int c = 0; c < ARR_SIZE; c++) begin
                        weight_matrix[r][c] = (r == c) ? 16'sh0001 : 16'sh0000;
                    end
                end
                for (int v = 0; v < NUM_VECS; v++) begin
                    vec_valid[v] = 1'b1;
                    for (int r = 0; r < ARR_SIZE; r++) begin
                        act_matrix[v][r] = get_random_corner_val();
                    end
                end
            end

            TEST_ALTERNATING: begin
                // Checkerboard alternating signs to test cancellation
                for (int r = 0; r < ARR_SIZE; r++) begin
                    for (int c = 0; c < ARR_SIZE; c++) begin
                        weight_matrix[r][c] = ((r + c) % 2 == 0) ? 16'sh7FFF : -16'sh7FFF;
                    end
                end
                for (int v = 0; v < NUM_VECS; v++) begin
                    vec_valid[v] = 1'b1;
                    for (int r = 0; r < ARR_SIZE; r++) begin
                        act_matrix[v][r] = ((v + r) % 2 == 0) ? 16'sh7FFF : -16'sh7FFF;
                    end
                end
            end

            TEST_SPARSE: begin
                // Sparse matrix (>85% zeros) with occasional random non-zeros
                for (int r = 0; r < ARR_SIZE; r++) begin
                    for (int c = 0; c < ARR_SIZE; c++) begin
                        weight_matrix[r][c] = ($urandom_range(0, 99) < 85) ? 16'sh0000 : get_random_corner_val();
                    end
                end
                for (int v = 0; v < NUM_VECS; v++) begin
                    vec_valid[v] = ($urandom_range(0, 99) < 85) ? 1'b1 : 1'b0;
                    for (int r = 0; r < ARR_SIZE; r++) begin
                        act_matrix[v][r] = ($urandom_range(0, 99) < 85) ? 16'sh0000 : get_random_corner_val();
                    end
                end
            end

            TEST_RANDOM: begin
                // Full constrained random distribution covering all corner weights & acts
                for (int r = 0; r < ARR_SIZE; r++) begin
                    for (int c = 0; c < ARR_SIZE; c++) begin
                        weight_matrix[r][c] = get_random_corner_val();
                    end
                end
                for (int v = 0; v < NUM_VECS; v++) begin
                    vec_valid[v] = ($urandom_range(0, 99) < 85) ? 1'b1 : 1'b0; // 85% valid, 15% bubble
                    for (int r = 0; r < ARR_SIZE; r++) begin
                        act_matrix[v][r] = get_random_corner_val();
                    end
                end
            end
        endcase
    endfunction

    // Deep copy function
    function sys_array_tx #(ARR_SIZE, NUM_VECS) copy();
        sys_array_tx #(ARR_SIZE, NUM_VECS) cp = new();
        cp.test_type     = this.test_type;
        cp.weight_matrix = this.weight_matrix;
        cp.act_matrix    = this.act_matrix;
        cp.vec_valid     = this.vec_valid;
        return cp;
    endfunction

    // Print summary of the transaction
    function void print(string tag = "");
        $display("[%0t] [%s] Test Scenario: %s | Vectors=%0d (ARR_SIZE=%0dx%0d)",
                 $time, tag, test_type.name(), NUM_VECS, ARR_SIZE, ARR_SIZE);
    endfunction

endclass


// ============================================================================
// 3. GENERATOR (sys_array_gen)
// Generates directed corner cases and constrained random transactions.
// ============================================================================
class sys_array_gen #(
    parameter ARR_SIZE = 16,
    parameter NUM_VECS = 8
);
    mailbox #(sys_array_tx #(ARR_SIZE, NUM_VECS)) gen2drv;
    mailbox #(sys_array_tx #(ARR_SIZE, NUM_VECS)) gen2scb;
    event drv_done;

    function new(
        mailbox #(sys_array_tx #(ARR_SIZE, NUM_VECS)) gen2drv,
        mailbox #(sys_array_tx #(ARR_SIZE, NUM_VECS)) gen2scb
    );
        this.gen2drv = gen2drv;
        this.gen2scb = gen2scb;
    endfunction

    task run();
        test_type_e test_plan[$];
        sys_array_tx #(ARR_SIZE, NUM_VECS) tx;

        // Build comprehensive test plan covering all corner cases
        test_plan.push_back(TEST_ZEROS);       // 1. All Zeros
        test_plan.push_back(TEST_MAX_POS);     // 2. Max Positive (+32767)
        test_plan.push_back(TEST_MIN_NEG);     // 3. Min Negative (-32768)
        test_plan.push_back(TEST_IDENTITY);    // 4. Identity Matrix Verification
        test_plan.push_back(TEST_ALTERNATING); // 5. Alternating (+/-) Cancellation
        test_plan.push_back(TEST_SPARSE);      // 6. Sparse Neural Network Pattern
        test_plan.push_back(TEST_RANDOM);      // 7. Constrained Random Scenario 1
        test_plan.push_back(TEST_RANDOM);      // 8. Constrained Random Scenario 2

        $display("\n[%0t] [GEN] ===================================================", $time);
        $display("[%0t] [GEN] Starting generation of %0d test scenarios...", $time, test_plan.size());
        $display("[%0t] [GEN] ===================================================", $time);

        foreach (test_plan[i]) begin
            tx = new();
            tx.populate_scenario(test_plan[i]);
            tx.print($sformatf("GEN-SCENARIO-%0d", i+1));

            // Forward to scoreboard reference model and driver
            gen2scb.put(tx.copy());
            gen2drv.put(tx);

            // Wait for driver to complete execution of current batch before generating next
            @(drv_done);
        end

        $display("[%0t] [GEN] All %0d test scenarios generated successfully.\n", $time, test_plan.size());
    endtask
endclass


// ============================================================================
// 4. DRIVER (sys_array_drv)
// Pulls transactions from mailbox and drives DUT via sys_array_if.cb.
// Manages:
//   1. Hardware reset sequencing
//   2. Serial top-to-bottom weight loading and shadow-register swapping
//   3. Pipelined, skewed systolic activation streaming
// ============================================================================
class sys_array_drv #(
    parameter ARR_SIZE = 16,
    parameter NUM_VECS = 8,
    parameter DSP_LATENCY = 2
);
    virtual sys_array_if #(ARR_SIZE) vif;
    mailbox #(sys_array_tx #(ARR_SIZE, NUM_VECS)) gen2drv;
    event drv_done;

    function new(
        virtual sys_array_if #(ARR_SIZE) vif,
        mailbox #(sys_array_tx #(ARR_SIZE, NUM_VECS)) gen2drv
    );
        this.vif     = vif;
        this.gen2drv = gen2drv;
    endfunction

    // ------------------------------------------------------------------------
    // Reset Sequence
    // ------------------------------------------------------------------------
    task reset();
        $display("[%0t] [DRV] Asserting Hardware Reset...", $time);
        vif.cb.rst            <= 1'b1;
        vif.cb.weight_load_en <= 1'b0;
        vif.cb.weight_swap_en <= 1'b0;
        for (int i = 0; i < ARR_SIZE; i++) begin
            vif.cb.valid_in[i]     <= 1'b0;
            vif.cb.input_act[i]    <= 16'sh0;
            vif.cb.input_weight[i] <= 16'sh0;
        end
        repeat (3) @(vif.cb);
        vif.cb.rst <= 1'b0;
        @(vif.cb);
        $display("[%0t] [DRV] Reset Released.", $time);
    endtask

    // ------------------------------------------------------------------------
    // Weight Loading Sequence:
    // In sys_array, weights shift vertically downward through shadow registers.
    // Row (ARR_SIZE-1) weights enter first at cycle 0; Row 0 enters at cycle (ARR_SIZE-1).
    // After ARR_SIZE cycles with weight_load_en=1, pulse weight_swap_en=1 to
    // latch shadow registers into active computation registers in every PE.
    // ------------------------------------------------------------------------
    task load_weights(ref bit signed [15:0] weights[ARR_SIZE][ARR_SIZE]);
        $display("[%0t] [DRV] Loading %0dx%0d Weight Matrix into Shadow Registers...",
                 $time, ARR_SIZE, ARR_SIZE);

        vif.cb.weight_load_en <= 1'b1;
        vif.cb.weight_swap_en <= 1'b0;
        @(vif.cb);

        for (int r = ARR_SIZE - 1; r >= 0; r--) begin
            for (int c = 0; c < ARR_SIZE; c++) begin
                vif.cb.input_weight[c] <= weights[r][c];
            end
            if (r == ARR_SIZE - 1 || r == 0) $display("[%0t] [LOAD] r=%0d", $time, r);
            @(vif.cb);
        end

        // Deassert load, clear weight inputs, and assert swap enable for 1 cycle
        vif.cb.weight_load_en <= 1'b0;
        vif.cb.weight_swap_en <= 1'b1;
        for (int c = 0; c < ARR_SIZE; c++) begin
            vif.cb.input_weight[c] <= 16'sh0;
        end
        @(vif.cb);

        // Deassert swap enable
        vif.cb.weight_swap_en <= 1'b0;
        @(vif.cb);
        $display("[%0t] [DRV] Weights Successfully Swapped into Active PE Registers.", $time);
        $display("[DEBUG] row0: reg=%0d | row13: reg=%0d shdw=%0d | row14: reg=%0d shdw=%0d | row15: reg=%0d shdw=%0d",
                 top.dut.sys_row[0].sys_col[0].u_pe.weight_reg,
                 top.dut.sys_row[13].sys_col[0].u_pe.weight_reg, top.dut.sys_row[13].sys_col[0].u_pe.weight_shdw_reg,
                 top.dut.sys_row[14].sys_col[0].u_pe.weight_reg, top.dut.sys_row[14].sys_col[0].u_pe.weight_shdw_reg,
                 top.dut.sys_row[15].sys_col[0].u_pe.weight_reg, top.dut.sys_row[15].sys_col[0].u_pe.weight_shdw_reg);
    endtask

    // ------------------------------------------------------------------------
    // Activation Streaming with Systolic Skewing:
    // For vector v, input_act[r] and valid_in[r] must be presented at cycle:
    //   t_feed = v + r
    // Pipelining allows vector (v+1) to enter directly on the subsequent cycle.
    // ------------------------------------------------------------------------
    task drive_activations(
        ref bit signed [15:0] acts[NUM_VECS][ARR_SIZE],
        ref bit               valid[NUM_VECS]
    );
        int total_cycles = NUM_VECS + (ARR_SIZE - 1) * DSP_LATENCY + 1;

        $display("[%0t] [DRV] Streaming %0d Pipelined Activation Vectors with Systolic Skew (DSP latency=%0d)...",
                 $time, NUM_VECS, DSP_LATENCY);

        for (int t = 0; t < total_cycles; t++) begin
            for (int r = 0; r < ARR_SIZE; r++) begin
                int v = t - (r * DSP_LATENCY);
                if (v >= 0 && v < NUM_VECS && valid[v]) begin
                    vif.cb.valid_in[r]  <= 1'b1;
                    vif.cb.input_act[r] <= acts[v][r];
                end else begin
                    vif.cb.valid_in[r]  <= 1'b0;
                    vif.cb.input_act[r] <= 16'sh0;
                end
            end
            @(vif.cb);
        end

        // Idle activation inputs after batch completes
        for (int r = 0; r < ARR_SIZE; r++) begin
            vif.cb.valid_in[r]  <= 1'b0;
            vif.cb.input_act[r] <= 16'sh0;
        end
    endtask

    // ------------------------------------------------------------------------
    // Main Driver Run Loop
    // ------------------------------------------------------------------------
    task run();
        forever begin
            sys_array_tx #(ARR_SIZE, NUM_VECS) tx;
            gen2drv.get(tx);

            // 1. Load weight matrix into systolic array
            load_weights(tx.weight_matrix);

            // 2. Stream activation vectors with proper skew
            drive_activations(tx.act_matrix, tx.vec_valid);

            // 3. Wait for all in-flight systolic waves to drain through array
            repeat (DSP_LATENCY * ARR_SIZE + ARR_SIZE + 10) @(vif.cb);

            // Inform generator that current transaction batch has completed
            -> drv_done;
        end
    endtask

    task idle();
        vif.cb.weight_load_en <= 1'b0;
        vif.cb.weight_swap_en <= 1'b0;
        for (int i = 0; i < ARR_SIZE; i++) begin
            vif.cb.valid_in[i]     <= 1'b0;
            vif.cb.input_act[i]    <= 16'sh0;
            vif.cb.input_weight[i] <= 16'sh0;
        end
        @(vif.cb);
    endtask
endclass


// ============================================================================
// 5. MONITOR (sys_array_mon)
// Passively samples DUT output signals via vif.mon_cb and forwards valid
// column outputs to the scoreboard.
// ============================================================================
class sys_array_mon #(
    parameter ARR_SIZE = 16
);
    virtual sys_array_if #(ARR_SIZE) vif;
    mailbox #(col_out_t) out_mon2scb;

    function new(
        virtual sys_array_if #(ARR_SIZE) vif,
        mailbox #(col_out_t) out_mon2scb
    );
        this.vif         = vif;
        this.out_mon2scb = out_mon2scb;
    endfunction

    task run();
        forever begin
            @(vif.mon_cb);
            if (!vif.mon_cb.rst) begin
                for (int c = 0; c < ARR_SIZE; c++) begin
                    if (vif.mon_cb.psum_valid_out[c] === 1'b1) begin
                        col_out_t pkt;
                        pkt.col      = c;
                        pkt.val      = vif.mon_cb.psum_out[c];
                        pkt.sim_time = $time;
                        out_mon2scb.put(pkt);
                    end
                end
            end
        end
    endtask
endclass


// ============================================================================
// 6. SCOREBOARD (sys_array_scb)
// Golden mathematical reference model for the 16x16 Systolic Array.
// - Processes transactions from generator to compute expected Y = A * W
// - Maintains per-column FIFO queues to match systolic output skew
// - Compares actual monitor output against expected results with detailed checks
// ============================================================================
class sys_array_scb #(
    parameter ARR_SIZE = 16,
    parameter NUM_VECS = 8
);
    mailbox #(sys_array_tx #(ARR_SIZE, NUM_VECS)) gen2scb;
    mailbox #(col_out_t)                          out_mon2scb;

    // Expected output FIFO queue per column
    logic signed [39:0] exp_queue[ARR_SIZE][$];

    // Verification statistics
    int total_expected  = 0;
    int match_count     = 0;
    int mismatch_count  = 0;
    int unexpected_count = 0;

    function new(
        mailbox #(sys_array_tx #(ARR_SIZE, NUM_VECS)) gen2scb,
        mailbox #(col_out_t)                          out_mon2scb
    );
        this.gen2scb     = gen2scb;
        this.out_mon2scb = out_mon2scb;
    endfunction

    // ------------------------------------------------------------------------
    // Process Golden Reference Matrix Multiplication:
    // For each valid activation vector v and column c:
    //   Y[v][c] = SUM_{r=0..ARR_SIZE-1} (A[v][r] * W[r][c])
    // Pushes expected result into column FIFO queue.
    // ------------------------------------------------------------------------
    task collect_expected();
        forever begin
            sys_array_tx #(ARR_SIZE, NUM_VECS) tx;
            gen2scb.get(tx);

            for (int v = 0; v < NUM_VECS; v++) begin
                if (tx.vec_valid[v]) begin
                    for (int c = 0; c < ARR_SIZE; c++) begin
                        logic signed [39:0] golden_sum = 40'sh0;

                        for (int r = 0; r < ARR_SIZE; r++) begin
                            logic signed [39:0] prod;
                            prod = $signed(tx.act_matrix[v][r]) * $signed(tx.weight_matrix[r][c]);
                            golden_sum = golden_sum + prod;
                        end

                        exp_queue[c].push_back(golden_sum);
                        total_expected++;
                    end
                end
            end
        end
    endtask

    // ------------------------------------------------------------------------
    // Check Actual DUT Outputs against Column Expected FIFO
    // ------------------------------------------------------------------------
    task check_actual();
        forever begin
            col_out_t pkt;
            logic signed [39:0] expected_val;

            out_mon2scb.get(pkt);

            // Yield #0 to allow collect_expected to enqueue if occurring on same edge
            #0;

            if (exp_queue[pkt.col].size() == 0) begin
                $error("[%0t] [SCB ERROR] Spurious output on Col %0d! Output=%0d, Queue is empty!",
                       pkt.sim_time, pkt.col, pkt.val);
                unexpected_count++;
            end else begin
                expected_val = exp_queue[pkt.col].pop_front();

                if (pkt.val === expected_val) begin
                    match_count++;
                    if (match_count <= 20 || match_count % 16 == 0) begin
                        $display("[%0t] [SCB PASS] Match #%0d | Col %02d | Expected=%0d | Actual=%0d",
                                 pkt.sim_time, match_count, pkt.col, expected_val, pkt.val);
                    end
                end else begin
                    mismatch_count++;
                    $fatal(1, "[%0t] [SCB MISMATCH] Col %02d | Expected=%0d | Actual=%0d",
                           pkt.sim_time, pkt.col, expected_val, pkt.val);
                end
            end
        end
    endtask

    task run();
        fork
            collect_expected();
            check_actual();
        join
    endtask

    // ------------------------------------------------------------------------
    // Final Verification Summary Report
    // ------------------------------------------------------------------------
    function void report();
        int pending_items = 0;
        for (int c = 0; c < ARR_SIZE; c++) pending_items += exp_queue[c].size();

        $display("\n=======================================================");
        $display("          16x16 SYSTOLIC ARRAY TEST REPORT             ");
        $display("=======================================================");
        $display(" Array Dimensions             : %0d x %0d", ARR_SIZE, ARR_SIZE);
        $display(" Total Expected Vector-Cols   : %0d", total_expected);
        $display(" Total Matches                : %0d", match_count);
        $display(" Total Mismatches             : %0d", mismatch_count);
        $display(" Unexpected / Spurious Pulses : %0d", unexpected_count);
        $display(" Pending Unverified in Queues : %0d", pending_items);
        $display("-------------------------------------------------------");
        if (mismatch_count == 0 && unexpected_count == 0 &&
            pending_items == 0 && match_count == total_expected && total_expected > 0) begin
            $display(" STATUS: >>> ALL 16x16 SYSTOLIC ARRAY TESTS PASSED <<<");
        end else begin
            $display(" STATUS: >>> TEST FAILED <<<");
        end
        $display("=======================================================\n");
    endfunction
endclass


// ============================================================================
// 7. ENVIRONMENT (sys_array_env)
// Connects generator, driver, monitor, scoreboard, and manages test lifecycle.
// ============================================================================
class sys_array_env #(
    parameter ARR_SIZE = 16,
    parameter NUM_VECS = 8,
    parameter DSP_LATENCY = 2
);
    virtual sys_array_if #(ARR_SIZE) vif;

    mailbox #(sys_array_tx #(ARR_SIZE, NUM_VECS)) gen2drv;
    mailbox #(sys_array_tx #(ARR_SIZE, NUM_VECS)) gen2scb;
    mailbox #(col_out_t)                          out_mon2scb;

    sys_array_gen #(ARR_SIZE, NUM_VECS)               gen;
    sys_array_drv #(ARR_SIZE, NUM_VECS, DSP_LATENCY) drv;
    sys_array_mon #(ARR_SIZE)                         mon;
    sys_array_scb #(ARR_SIZE, NUM_VECS)               scb;

    function new(virtual sys_array_if #(ARR_SIZE) vif);
        this.vif         = vif;
        this.gen2drv     = new();
        this.gen2scb     = new();
        this.out_mon2scb = new();

        this.gen = new(gen2drv, gen2scb);
        this.drv = new(vif, gen2drv);
        this.mon = new(vif, out_mon2scb);
        this.scb = new(gen2scb, out_mon2scb);

        // Connect generator/driver handshake event
        this.gen.drv_done = this.drv.drv_done;
    endfunction

    task run();
        // 1. Reset DUT
        drv.reset();

        // 2. Fork concurrent verification threads
        fork
            begin : gen_thread
                gen.run();
            end
            begin : drv_thread
                drv.run();
            end
            begin : mon_thread
                mon.run();
            end
            begin : scb_thread
                scb.run();
            end
        join_any

        // 3. Generator finished all scenarios; disable driver and idle the bus
        $display("[%0t] [ENV] All test scenarios submitted. Draining remaining systolic waves...", $time);
        disable drv_thread;
        drv.idle();

        // 4. Clean drain: wait until all expected transactions are matched
        fork : drain_or_timeout
            begin
                while (scb.match_count != scb.total_expected ||
                       out_mon2scb.num() != 0) begin
                    @(vif.mon_cb);
                end
                // Quiet cycles to verify no delayed or stray pulses occur
                repeat (10) @(vif.cb);
            end
            begin
                repeat (2000) @(vif.cb);
                $fatal(1, "[%0t] [ENV ERROR] Drain timeout! Expected=%0d, Matched=%0d, Mon_Queue=%0d",
                       $time, scb.total_expected, scb.match_count, out_mon2scb.num());
            end
        join_any
        disable drain_or_timeout;
        disable mon_thread;
        disable scb_thread;

        // 5. Generate final report
        scb.report();
    endtask
endclass


// ============================================================================
// 8. TESTBENCH TOP MODULE (top)
// Instantiates 16x16 systolic array DUT and runs the verification environment.
// ============================================================================
module top;
    localparam ARR_SIZE = 16;
    localparam NUM_VECS = 8;

    // 100MHz clock (10ns period)
    logic clk;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // Interface instantiation
    sys_array_if #(.ARR_SIZE(ARR_SIZE)) sa_if(clk);

    // DUT Instantiation with ARR_SIZE = 16
    sys_array #(
        .ARR_SIZE(ARR_SIZE)
    ) dut (
        .clk            (clk),
        .rst            (sa_if.rst),
        .weight_load_en (sa_if.weight_load_en),
        .weight_swap_en (sa_if.weight_swap_en),
        .valid_in       (sa_if.valid_in),
        .input_act      (sa_if.input_act),
        .input_weight   (sa_if.input_weight),
        .psum_valid_out (sa_if.psum_valid_out),
        .psum_out       (sa_if.psum_out)
    );

    // Test execution
    initial begin
        sys_array_env #(.ARR_SIZE(ARR_SIZE), .NUM_VECS(NUM_VECS), .DSP_LATENCY(2)) env;

        $dumpfile("sys_array_wave.vcd");
        $dumpvars(0, top);

        $display("\n-------------------------------------------------------");
        $display("   STARTING SYSTEMVERILOG 16x16 SYSTOLIC ARRAY TEST   ");
        $display("-------------------------------------------------------\n");

        env = new(sa_if);
        env.run();

        $finish;
    end

    always @(posedge clk) begin
        if (sa_if.weight_load_en || sa_if.weight_swap_en) begin
            $display("[%0t] [CLK] load=%b swap=%b | in=%0d | r0=%0d r1=%0d r14=%0d r15=%0d",
                     $time, sa_if.weight_load_en, sa_if.weight_swap_en,
                     sa_if.input_weight[0],
                     dut.sys_row[0].sys_col[0].u_pe.weight_shdw_reg,
                     dut.sys_row[1].sys_col[0].u_pe.weight_shdw_reg,
                     dut.sys_row[14].sys_col[0].u_pe.weight_shdw_reg,
                     dut.sys_row[15].sys_col[0].u_pe.weight_shdw_reg);
        end
    end

endmodule
