`timescale 1ns/1ps

`include "svunit_defines.svh"

// Unit tests for baud_rate_gen. Tests use a small baud_div (4) rather than
// the real value (e.g., 868 for 115200 at 100 MHz) so simulations are short
// and tick timing is easy to verify manually. The period relationship
// (baud_div+1 cycles) holds for any divisor value.
//
// Note: baud_div is registered internally (one cycle latency). Tests load
// baud_div one cycle before asserting baud_gen_en so the correct divisor is
// in effect when the first count begins.

module baud_rate_gen_unit_test;
    import svunit_pkg::svunit_testcase;

    localparam int CLK_PERIOD     = 10;
    localparam int RST_ASSERT_CNT = 2;

    string name = "baud_rate_gen_ut";
    svunit_testcase svunit_ut;

    bit          clk = 0;
    bit          rst = 0;
    logic        baud_gen_en;
    logic [14:0] baud_div;
    logic [14:0] baud_cnt;
    logic        baud_tick;

    baud_rate_gen dut (
        .clk            (clk),
        .rst            (rst),
        .baud_gen_en    (baud_gen_en),
        .baud_div       (baud_div),
        .baud_cnt       (baud_cnt),
        .baud_tick      (baud_tick)
    );

    initial begin
        forever begin
            #(CLK_PERIOD/2);
            clk = ~clk;
        end
    end

    default clocking cb @(posedge clk);
        default input #1step;
        default output #1;
        input  baud_tick;
        input  baud_cnt;
        output baud_gen_en;
        output baud_div;
    endclocking

    function automatic void build();
        svunit_ut = new(name);
    endfunction

    task automatic setup();
        svunit_ut.setup();
        $timeformat(-9, 0, " ns", 1);
        rst         = 1;
        baud_gen_en = 0;
        baud_div    = '0;
        ##RST_ASSERT_CNT;
        rst = 0;
        ##1;
    endtask

    task automatic teardown();
        svunit_ut.teardown();
    endtask

    `SVUNIT_TESTS_BEGIN

    // no tick produced while generator is disabled
    `SVTEST(no_tick_when_disabled)
        cb.baud_div <= 15'd4;
        ##10;
        `FAIL_UNLESS_EQUAL(cb.baud_tick, 1'b0);
        `FAIL_UNLESS_EQUAL(cb.baud_cnt,  15'd0);
    `SVTEST_END

    // tick fires exactly baud_div+1 cycles after enable is asserted
    `SVTEST(tick_fires_after_baud_div_plus_one_cycles)
        cb.baud_div     <= 15'd4;
        ##1;                        // let baud_div register into baud_div_q
        cb.baud_gen_en  <= 1;
        ##4;                        // cycles 1-4: no tick yet
        `FAIL_UNLESS_EQUAL(cb.baud_tick, 1'b0);
        ##2;                        // cycle 5: tick fires; +1 to read that cycle's result
        `FAIL_UNLESS_EQUAL(cb.baud_tick, 1'b1);
    `SVTEST_END

    // tick is a single-cycle pulse; deasserts on the following cycle
    `SVTEST(tick_is_one_cycle_wide)
        cb.baud_div     <= 15'd4;
        ##1;
        cb.baud_gen_en  <= 1;
        ##6;                        // tick fires at cycle 5; +1 to read that cycle's result
        `FAIL_UNLESS_EQUAL(cb.baud_tick, 1'b1);
        ##1;                        // tick deasserts
        `FAIL_UNLESS_EQUAL(cb.baud_tick, 1'b0);
    `SVTEST_END

    // after the first tick, subsequent ticks are spaced baud_div+1 cycles apart
    `SVTEST(steady_state_period_is_baud_div_plus_one)
        cb.baud_div     <= 15'd4;
        ##1;
        cb.baud_gen_en  <= 1;
        ##6;                        // tick fires at cycle 5; +1 to read that cycle's result
        `FAIL_UNLESS_EQUAL(cb.baud_tick, 1'b1);
        ##4;                        // 4 cycles later: not yet
        `FAIL_UNLESS_EQUAL(cb.baud_tick, 1'b0);
        ##1;                        // 5 cycles later: second tick
        `FAIL_UNLESS_EQUAL(cb.baud_tick, 1'b1);
    `SVTEST_END

    // with baud_div=0 the tick fires every cycle
    `SVTEST(baud_div_zero_ticks_every_cycle)
        cb.baud_div     <= 15'd0;   // baud_div_q already 0 from setup
        cb.baud_gen_en  <= 1;
        ##2;                        // tick fires at cycle 1; +1 to read that cycle's result
        `FAIL_UNLESS_EQUAL(cb.baud_tick, 1'b1);
        ##1;
        `FAIL_UNLESS_EQUAL(cb.baud_tick, 1'b1);
        ##1;
        `FAIL_UNLESS_EQUAL(cb.baud_tick, 1'b1);
    `SVTEST_END

    // deasserting baud_gen_en resets the counter to zero
    `SVTEST(disable_resets_counter)
        cb.baud_div     <= 15'd10;
        ##1;
        cb.baud_gen_en  <= 1;
        ##5;                        // mid-count
        cb.baud_gen_en  <= 0;
        ##2;                        // disable takes effect at next cycle; +1 to read that result
        `FAIL_UNLESS_EQUAL(cb.baud_tick, 1'b0);
        `FAIL_UNLESS_EQUAL(cb.baud_cnt, 15'd0);
    `SVTEST_END

    // asserting rst clears the tick and counter mid-operation
    `SVTEST(reset_clears_outputs)
        cb.baud_div     <= 15'd4;
        ##1;
        cb.baud_gen_en  <= 1;
        ##3;                        // mid-count
        rst = 1;
        ##2;                        // reset takes effect at next cycle; +1 to read that result
        `FAIL_UNLESS_EQUAL(cb.baud_tick, 1'b0);
        `FAIL_UNLESS_EQUAL(cb.baud_cnt,  15'd0);
    `SVTEST_END

    `SVUNIT_TESTS_END

endmodule : baud_rate_gen_unit_test
