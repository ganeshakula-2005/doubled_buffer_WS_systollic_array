`timescale 1ns/1ps

// ============================================================================
// 1. MAC INTERFACE
// Bundles all signals connecting to the MAC DUT.
// Includes a clocking block to eliminate race conditions between TB and DUT.
// ============================================================================
interface mac_if(input logic clk);
    logic               rst;
    logic signed [15:0] act_in;
    logic signed [15:0] weight_in;
    logic signed [39:0] psum_in;
    logic               valid_in;
    logic signed [39:0] psum_out;
    logic               done;

    // Clocking block:
    // TB samples DUT signals #1step before posedge clk (Observed region).
    // TB drives DUT inputs #1ns after posedge clk, preventing delta-cycle races.
    clocking cb @(posedge clk);
        default input #1step output #1ns;
        output rst;
        output act_in;
        output weight_in;
        output psum_in;
        output valid_in;
        input  psum_out;
        input  done;
    endclocking

    // Passive monitor modport (all signals sampled via cb)
    clocking mon_cb @(posedge clk);
        default input #1step;
        input rst;
        input act_in;
        input weight_in;
        input psum_in;
        input valid_in;
        input psum_out;
        input done;
    endclocking
endinterface


// ============================================================================
// 2. TRANSACTION CLASS (mac_tx)
// Represents a single transaction packet sent to or observed from the DUT.
// ============================================================================
class mac_tx;
    rand bit signed [15:0] act_in;
    rand bit signed [15:0] weight_in;
    rand bit signed [39:0] psum_in;
    rand bit               valid_in;

    // Captured response fields
    bit signed [39:0]      psum_out;
    bit                    done;

    // Constraint 1: Realistic valid density (80% active, 20% bubble)
    constraint c_valid_dist {
        valid_in dist { 1'b1 := 80, 1'b0 := 20 };
    }

    // Constraint 2: Corner cases for activations
    constraint c_act_dist {
        act_in dist {
            16'sh0000      := 10, // Zero operand
            16'sh7FFF      := 10, // Max positive (+32767)
            16'sh8000      := 10, // Min negative (-32768)
            -1             := 5,
            1              := 5,
            [-100:100]     := 30,
            [-32768:32767] := 30
        };
    }

    // Constraint 3: Corner cases for weights
    constraint c_weight_dist {
        weight_in dist {
            16'sh0000      := 10, // Zero weight
            16'sh7FFF      := 10, // Max positive weight
            16'sh8000      := 10, // Min negative weight
            -1             := 5,
            1              := 5,
            [-100:100]     := 30,
            [-32768:32767] := 30
        };
    }

    // Constraint 4: Partial sum accumulator range
    constraint c_psum_dist {
        psum_in inside {
            40'sh00_0000_0000,
            40'sh7F_FFFF_FFFF,
            40'sh80_0000_0000,
            [-1000:1000],
            [-1000000:1000000]
        };
    }

    function mac_tx copy();
        mac_tx cp = new();
        cp.act_in    = this.act_in;
        cp.weight_in = this.weight_in;
        cp.psum_in   = this.psum_in;
        cp.valid_in  = this.valid_in;
        cp.psum_out  = this.psum_out;
        cp.done      = this.done;
        return cp;
    endfunction

    function void print(string tag = "");
        $display("[%0t] [%s] act=%0d wt=%0d psum_in=%0d valid=%0b | done=%0b psum_out=%0d",
                 $time, tag, act_in, weight_in, psum_in, valid_in, done, psum_out);
    endfunction
endclass


// ============================================================================
// 3. GENERATOR (mac_gen)
// Creates sequences of transactions and pushes them into the driver mailbox.
// ============================================================================
class mac_gen;
    mailbox #(mac_tx) gen2drv;
    int               num_tx;
    event             drv_done;

    function new(mailbox #(mac_tx) gen2drv, int num_tx);
        this.gen2drv = gen2drv;
        this.num_tx  = num_tx;
    endfunction

    task run();
        $display("[%0t] [GEN] Starting generation of %0d transactions...", $time, num_tx);
        for (int i = 0; i < num_tx; i++) begin
            mac_tx tx = new();
            if (tx.randomize() == 0) begin
                $fatal(1, "[%0t] [GEN] ERROR: Randomization failed!", $time);
            end
            gen2drv.put(tx);
            // Wait for driver to latch transaction onto interface before generating next
            @(drv_done);
        end
        $display("[%0t] [GEN] Finished generating all %0d transactions.", $time, num_tx);
    endtask
endclass


// ============================================================================
// 4. DRIVER (mac_drv)
// Pulls transactions from mailbox and drives DUT pins via mac_if.cb.
// Fully decoupled from the scoreboard.
// ============================================================================
class mac_drv;
    virtual mac_if    vif;
    mailbox #(mac_tx) gen2drv;
    event             drv_done;

    function new(virtual mac_if vif, mailbox #(mac_tx) gen2drv);
        this.vif     = vif;
        this.gen2drv = gen2drv;
    endfunction

    task reset();
        $display("[%0t] [DRV] Applying Reset...", $time);
        vif.cb.rst       <= 1'b1;
        vif.cb.valid_in  <= 1'b0;
        vif.cb.act_in    <= 16'sh0;
        vif.cb.weight_in <= 16'sh0;
        vif.cb.psum_in   <= 40'sh0;
        repeat (3) @(vif.cb);
        vif.cb.rst       <= 1'b0;
        @(vif.cb);
        $display("[%0t] [DRV] Reset Released.", $time);
    endtask

    task run();
        forever begin
            mac_tx tx;
            gen2drv.get(tx);

            @(vif.cb);
            vif.cb.valid_in  <= tx.valid_in;
            vif.cb.act_in    <= tx.act_in;
            vif.cb.weight_in <= tx.weight_in;
            vif.cb.psum_in   <= tx.psum_in;

            if (tx.valid_in) begin
                $display("[%0t] [DRV] Drove valid=1 act=%0d wt=%0d psum=%0d",
                         $time, tx.act_in, tx.weight_in, tx.psum_in);
            end else begin
                $display("[%0t] [DRV] Drove valid=0 (bubble)", $time);
            end

            // Inform generator that transaction is placed on the bus
            -> drv_done;
        end
    endtask

    task idle();
        @(vif.cb);
        vif.cb.valid_in  <= 1'b0;
        vif.cb.act_in    <= 16'sh0;
        vif.cb.weight_in <= 16'sh0;
        vif.cb.psum_in   <= 40'sh0;
    endtask
endclass


// ============================================================================
// 5. MONITOR (mac_mon)
// Passively observes both inputs (valid_in) and outputs (done) on the bus
// and forwards them to the scoreboard through dedicated mailboxes.
// ============================================================================
class mac_mon;
    virtual mac_if    vif;
    mailbox #(mac_tx) in_mon2scb;
    mailbox #(mac_tx) out_mon2scb;

    function new(virtual mac_if vif, mailbox #(mac_tx) in_mon2scb, mailbox #(mac_tx) out_mon2scb);
        this.vif         = vif;
        this.in_mon2scb  = in_mon2scb;
        this.out_mon2scb = out_mon2scb;
    endfunction

    task run();
        forever begin
            @(vif.mon_cb);
            if (!vif.mon_cb.rst) begin
                // 1. Observe accepted input transactions
                if (vif.mon_cb.valid_in === 1'b1) begin
                    mac_tx in_tx = new();
                    in_tx.valid_in  = 1'b1;
                    in_tx.act_in    = vif.mon_cb.act_in;
                    in_tx.weight_in = vif.mon_cb.weight_in;
                    in_tx.psum_in   = vif.mon_cb.psum_in;
                    $display("[%0t] [MON-IN]  Sampled valid=1 act=%0d wt=%0d psum_in=%0d",
                             $time, in_tx.act_in, in_tx.weight_in, in_tx.psum_in);
                    in_mon2scb.put(in_tx);
                end

                // 2. Observe DUT output responses
                if (vif.mon_cb.done === 1'b1) begin
                    mac_tx out_tx = new();
                    out_tx.psum_out = vif.mon_cb.psum_out;
                    out_tx.done     = 1'b1;
                    $display("[%0t] [MON-OUT] Sampled done=1 psum_out=%0d",
                             $time, out_tx.psum_out);
                    out_mon2scb.put(out_tx);
                end
            end
        end
    endtask
endclass


// ============================================================================
// 6. SCOREBOARD (mac_scb)
// Golden mathematical reference model fed purely by the passive monitor.
// ============================================================================
class mac_scb;
    mailbox #(mac_tx)   in_mon2scb;
    mailbox #(mac_tx)   out_mon2scb;
    logic signed [39:0] exp_queue[$];

    int total_expected = 0;
    int match_count    = 0;
    int mismatches     = 0;
    int unexpected     = 0;

    function new(mailbox #(mac_tx) in_mon2scb, mailbox #(mac_tx) out_mon2scb);
        this.in_mon2scb  = in_mon2scb;
        this.out_mon2scb = out_mon2scb;
    endfunction

    // Process observed inputs into golden expected results
    task collect_expected();
        forever begin
            mac_tx in_tx;
            logic signed [39:0] golden_prod;
            logic signed [39:0] golden_result;

            in_mon2scb.get(in_tx);
            golden_prod   = in_tx.act_in * in_tx.weight_in;
            golden_result = golden_prod + in_tx.psum_in;

            exp_queue.push_back(golden_result);
            total_expected++;
        end
    endtask

    // Compare observed outputs against golden queue
    task check_actual();
        forever begin
            mac_tx actual_tx;
            logic signed [39:0] exp_val;

            out_mon2scb.get(actual_tx);

            // Yield 0-delay if input and output arrive on the exact same clock edge
            // (e.g., 0-latency combinational DUT) so collect_expected runs first.
            #0;

            if (exp_queue.size() == 0) begin
                $error("[%0t] [SCB ERROR] Output done=1 observed, but expected queue is empty! Output=%0d",
                       $time, actual_tx.psum_out);
                unexpected++;
            end else begin
                exp_val = exp_queue.pop_front();
                if (actual_tx.psum_out === exp_val) begin
                    match_count++;
                    $display("[%0t] [SCB PASS] Match #%0d: Expected=%0d | Actual=%0d",
                             $time, match_count, exp_val, actual_tx.psum_out);
                end else begin
                    mismatches++;
                    $fatal(1, "[%0t] [SCB MISMATCH] Expected=%0d | Actual=%0d",
                           $time, exp_val, actual_tx.psum_out);
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

    function void report();
        $display("\n=======================================================");
        $display("                 MAC TEST SUMMARY REPORT                ");
        $display("=======================================================");
        $display(" Total Expected Transactions : %0d", total_expected);
        $display(" Total Matches               : %0d", match_count);
        $display(" Total Mismatches            : %0d", mismatches);
        $display(" Unexpected Output Pulses    : %0d", unexpected);
        $display(" Pending Unverified in Queue : %0d", exp_queue.size());
        $display("-------------------------------------------------------");
        if (mismatches == 0 && unexpected == 0 && exp_queue.size() == 0 && match_count == total_expected) begin
            $display(" STATUS: >>> TEST PASSED SUCCESSFULLY <<<");
        end else begin
            $display(" STATUS: >>> TEST FAILED <<<");
        end
        $display("=======================================================\n");
    endfunction
endclass


// ============================================================================
// 7. ENVIRONMENT (mac_env)
// Connects generator, driver, monitor, scoreboard, and mailboxes.
// ============================================================================
class mac_env;
    virtual mac_if    vif;
    mailbox #(mac_tx) gen2drv;
    mailbox #(mac_tx) in_mon2scb;
    mailbox #(mac_tx) out_mon2scb;

    mac_gen gen;
    mac_drv drv;
    mac_mon mon;
    mac_scb scb;

    function new(virtual mac_if vif, int num_tx);
        this.vif         = vif;
        this.gen2drv     = new();
        this.in_mon2scb  = new();
        this.out_mon2scb = new();

        this.scb = new(in_mon2scb, out_mon2scb);
        this.drv = new(vif, gen2drv);
        this.gen = new(gen2drv, num_tx);
        this.mon = new(vif, in_mon2scb, out_mon2scb);

        // Connect generator/driver handshake event
        this.gen.drv_done = this.drv.drv_done;
    endfunction

    task run();
        // 1. Reset DUT
        drv.reset();

        // 2. Fork concurrent processes (only gen.run() terminates naturally)
        fork
            begin : gen_proc
                gen.run();
            end
            begin : drv_proc
                drv.run();
            end
            begin : mon_proc
                mon.run();
            end
            begin : scb_proc
                scb.run();
            end
        join_any

        // 3. join_any unblocks immediately when gen.run() completes (no event race!)
        $display("[%0t] [ENV] All transactions generated. Idling bus and draining DUT...", $time);

        // Stop driver loop and drive idle on the next clocking edge
        disable drv_proc;
        drv.idle();

        // 4. Clean drain: wait until all observed valid inputs have matching outputs
        fork : drain_or_timeout
            // 4. Clean drain: wait until all observed valid inputs have matching outputs
            begin
                // Wait at least 1 cycle so monitor captures the final driven cycle
                @(vif.mon_cb);
                while (scb.match_count != scb.total_expected ||
                       in_mon2scb.num() != 0 ||
                       out_mon2scb.num() != 0) begin
                    @(vif.mon_cb);
                end
                repeat (5) @(vif.cb); // Extra quiet cycles to catch spurious done pulses
            end
            begin
                repeat (100) @(vif.cb);
                $fatal(1, "[%0t] [ENV ERROR] Drain timeout! expected=%0d, matched=%0d, pending_q=%0d, in_mbx=%0d, out_mbx=%0d",
                       $time, scb.total_expected, scb.match_count, scb.exp_queue.size(),
                       in_mon2scb.num(), out_mon2scb.num());
            end
        join_any
        disable drain_or_timeout;
        disable mon_proc;
        disable scb_proc;

        // 5. Print final report
        scb.report();
    endtask
endclass


// ============================================================================
// 8. TESTBENCH TOP MODULE (top)
// ============================================================================
module top;
    // Clock generation: 100MHz (10ns period)
    logic clk;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // Interface instantiation
    mac_if mif(clk);

    // DUT instantiation
    mac dut (
        .clk       (clk),
        .rst       (mif.rst),
        .act_in    (mif.act_in),
        .weight_in (mif.weight_in),
        .psum_in   (mif.psum_in),
        .valid_in  (mif.valid_in),
        .psum_out  (mif.psum_out),
        .done      (mif.done)
    );

    // Simulation control
    initial begin
        mac_env env;

        $dumpfile("mac_wave.vcd");
        $dumpvars(0, top);

        // Run 200 transactions to thoroughly exercise corner cases
        env = new(mif, 200);
        env.run();

        $finish;
    end
endmodule
