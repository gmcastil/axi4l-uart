`timescale 1ns/1ps

`include "svunit_defines.svh"

// Unit tests for uart_tx.
//
// baud_tick is driven directly from the testbench. The TX FIFO interface is
// modeled with simple procedural logic per test; there is no structural FIFO.
//
// tick() drives one baud_tick pulse: asserted for one clock cycle, deasserted
// for one clock cycle. After tick() returns, cb reads reflect the DUT output
// registered when baud_tick was asserted.
//
// bit_period(expected) drives 16 ticks and checks tx at tick 1 (verifies
// transition timing) and tick 8 (canonical mid-bit sample). check_frame()
// calls bit_period() once per field and covers the full frame including the
// trigger tick that starts it.
//
// UTX-010 (tx_rd_en assertion timing) is deferred. Tests verify only that
// tx_rd_en is not asserted while tx_empty is high.

module uart_tx_unit_test;
    import svunit_pkg::svunit_testcase;

    localparam int CLK_PERIOD     = 10;
    localparam int RST_ASSERT_CNT = 2;

    string name = "uart_tx_ut";
    svunit_testcase svunit_ut;

    bit   clk       = 0;
    bit   rst       = 0;

    logic        baud_tick;
    logic [3:0]  data_bits;
    logic        parity_en;
    logic        parity_odd;
    logic        stop_bits;
    logic [7:0]  tx_data;
    logic        tx_empty;
    logic        tx_rd_en;
    logic        tx;
    logic        tx_busy;
    logic [31:0] tx_frame_count;

    uart_tx dut (
        .clk            (clk),
        .rst            (rst),
        .baud_tick      (baud_tick),
        .data_bits      (data_bits),
        .parity_en      (parity_en),
        .parity_odd     (parity_odd),
        .stop_bits      (stop_bits),
        .tx_data        (tx_data),
        .tx_empty       (tx_empty),
        .tx_rd_en       (tx_rd_en),
        .tx             (tx),
        .tx_busy        (tx_busy),
        .tx_frame_count (tx_frame_count)
    );

    initial begin
        forever begin
            #(CLK_PERIOD/2);
            clk = ~clk;
        end
    end

    default clocking cb @(posedge clk);
        default input  #1step;
        default output #1;
        input  tx;
        input  tx_busy;
        input  tx_rd_en;
        input  tx_frame_count;
        output baud_tick;
        output data_bits;
        output parity_en;
        output parity_odd;
        output stop_bits;
        output tx_data;
        output tx_empty;
    endclocking

    // Drive one baud_tick pulse. After returning, cb reads reflect the DUT
    // output registered on the cycle baud_tick was asserted.
    task automatic tick();
        cb.baud_tick <= 1;
        ##1;
        cb.baud_tick <= 0;
        ##1;
    endtask

    task automatic ticks(int n);
        repeat (n) tick();
    endtask

    // Advance the DUT through one 16-tick bit window and verify tx holds
    // expected_tx at tick 1 (transition timing) and tick 8 (mid-bit sample).
    task automatic bit_period(logic expected_tx);
        tick();
        `FAIL_UNLESS_EQUAL(cb.tx, expected_tx);
        ticks(6);
        tick();
        `FAIL_UNLESS_EQUAL(cb.tx, expected_tx);
        ticks(8);
    endtask

    // Expected parity bit for nbits data bits from data, with odd=1 selecting
    // odd parity.
    function automatic logic calc_parity(
        logic [7:0] data,
        int         nbits,
        logic       odd
    );
        logic p;
        p = 1'b0;
        for (int i = 0; i < nbits; i++)
            p ^= data[i];
        return odd ? ~p : p;
    endfunction

    // Advance the DUT through a complete frame by driving baud_tick pulses and
    // verify the serial output matches the expected frame. The first baud_tick
    // starts the frame; tx_empty must be deasserted and tx_data valid before
    // calling.
    task automatic check_frame(
        logic [7:0] data,
        int         nbits,
        logic       par_en,
        logic       par_odd,
        logic       two_stops
    );
        bit_period(1'b0);
        for (int i = 0; i < nbits; i++)
            bit_period(data[i]);
        if (par_en)
            bit_period(calc_parity(data, nbits, par_odd));
        bit_period(1'b1);
        if (two_stops)
            bit_period(1'b1);
    endtask

    function automatic void build();
        svunit_ut = new(name);
    endfunction

    task automatic setup();
        svunit_ut.setup();
        $timeformat(-9, 0, " ns", 1);
        rst = 1;
        // Each test will set it's own setup conditions
        cb.baud_tick  <= 0;
        cb.data_bits  <= 4'd8;
        cb.parity_en  <= 0;
        cb.parity_odd <= 0;
        cb.stop_bits  <= 0;
        cb.tx_data    <= 8'h00;
        cb.tx_empty   <= 1;
        ##RST_ASSERT_CNT;
        rst = 0;
        ##1;
    endtask

    task automatic teardown();
        svunit_ut.teardown();
    endtask

    `SVUNIT_TESTS_BEGIN

    // tx stays high and tx_busy stays low with no ticks while FIFO is empty
    `SVTEST(idle_when_empty)
        cb.data_bits  <= 4'd8;
        cb.parity_en  <= 0;
        cb.parity_odd <= 0;
        cb.stop_bits  <= 0;
        cb.tx_data    <= 8'h00;
        cb.tx_empty   <= 1;
        ##1;
        ticks(20);
        `FAIL_UNLESS_EQUAL(cb.tx,       1'b1);
        `FAIL_UNLESS_EQUAL(cb.tx_busy,  1'b0);
        `FAIL_UNLESS_EQUAL(cb.tx_rd_en, 1'b0);
    `SVTEST_END

    // synchronous reset clears tx to 1, tx_busy to 0, tx_rd_en to 0
    `SVTEST(reset_clears_outputs)
        cb.data_bits  <= 4'd8;
        cb.parity_en  <= 0;
        cb.parity_odd <= 0;
        cb.stop_bits  <= 0;
        cb.tx_data    <= 8'hA5;
        cb.tx_empty   <= 0;
        ##1;
        ticks(5);
        rst = 1;
        ##2;
        `FAIL_UNLESS_EQUAL(cb.tx,       1'b1);
        `FAIL_UNLESS_EQUAL(cb.tx_busy,  1'b0);
        `FAIL_UNLESS_EQUAL(cb.tx_rd_en, 1'b0);
    `SVTEST_END

    // start bit is tx=0 for exactly 16 baud_ticks; tx transitions to data[0]
    // on tick 17
    `SVTEST(start_bit_width)
        cb.data_bits  <= 4'd8;
        cb.parity_en  <= 0;
        cb.parity_odd <= 0;
        cb.stop_bits  <= 0;
        cb.tx_data    <= 8'hFF;
        cb.tx_empty   <= 0;
        ##1;
        tick();
        repeat (14) begin
            `FAIL_UNLESS_EQUAL(cb.tx, 1'b0);
            tick();
        end
        `FAIL_UNLESS_EQUAL(cb.tx, 1'b0);
        tick();
        `FAIL_UNLESS_EQUAL(cb.tx, 1'b0);
        tick();
        `FAIL_UNLESS_EQUAL(cb.tx, 1'b1);
        cb.tx_empty <= 1;
    `SVTEST_END

    // complete 8N1 frame: all bits correct, LSB-first
    `SVTEST(frame_8n1)
        cb.data_bits  <= 4'd8;
        cb.parity_en  <= 0;
        cb.parity_odd <= 0;
        cb.stop_bits  <= 0;
        cb.tx_data    <= 8'hB5;
        cb.tx_empty   <= 0;
        ##1;
        check_frame(8'hB5, 8, 0, 0, 0);
        cb.tx_empty <= 1;
    `SVTEST_END

    // 5-bit frame
    `SVTEST(frame_5bit)
        cb.data_bits  <= 4'd5;
        cb.parity_en  <= 0;
        cb.parity_odd <= 0;
        cb.stop_bits  <= 0;
        cb.tx_data    <= 8'h15;
        cb.tx_empty   <= 0;
        ##1;
        check_frame(8'h15, 5, 0, 0, 0);
        cb.tx_empty <= 1;
    `SVTEST_END

    // 6-bit frame
    `SVTEST(frame_6bit)
        cb.data_bits  <= 4'd6;
        cb.parity_en  <= 0;
        cb.parity_odd <= 0;
        cb.stop_bits  <= 0;
        cb.tx_data    <= 8'h2A;
        cb.tx_empty   <= 0;
        ##1;
        check_frame(8'h2A, 6, 0, 0, 0);
        cb.tx_empty <= 1;
    `SVTEST_END

    // 7-bit frame
    `SVTEST(frame_7bit)
        cb.data_bits  <= 4'd7;
        cb.parity_en  <= 0;
        cb.parity_odd <= 0;
        cb.stop_bits  <= 0;
        cb.tx_data    <= 8'h55;
        cb.tx_empty   <= 0;
        ##1;
        check_frame(8'h55, 7, 0, 0, 0);
        cb.tx_empty <= 1;
    `SVTEST_END

    // even parity with even number of 1s: parity bit = 0
    `SVTEST(parity_even_zero)
        cb.data_bits  <= 4'd8;
        cb.parity_en  <= 1;
        cb.parity_odd <= 0;
        cb.stop_bits  <= 0;
        cb.tx_data    <= 8'h03;
        cb.tx_empty   <= 0;
        ##1;
        check_frame(8'h03, 8, 1, 0, 0);
        cb.tx_empty <= 1;
    `SVTEST_END

    // even parity with odd number of 1s: parity bit = 1
    `SVTEST(parity_even_one)
        cb.data_bits  <= 4'd8;
        cb.parity_en  <= 1;
        cb.parity_odd <= 0;
        cb.stop_bits  <= 0;
        cb.tx_data    <= 8'h01;
        cb.tx_empty   <= 0;
        ##1;
        check_frame(8'h01, 8, 1, 0, 0);
        cb.tx_empty <= 1;
    `SVTEST_END

    // odd parity with odd number of 1s: parity bit = 0
    `SVTEST(parity_odd_zero)
        cb.data_bits  <= 4'd8;
        cb.parity_en  <= 1;
        cb.parity_odd <= 1;
        cb.stop_bits  <= 0;
        cb.tx_data    <= 8'h01;
        cb.tx_empty   <= 0;
        ##1;
        check_frame(8'h01, 8, 1, 1, 0);
        cb.tx_empty <= 1;
    `SVTEST_END

    // odd parity with even number of 1s: parity bit = 1
    `SVTEST(parity_odd_one)
        cb.data_bits  <= 4'd8;
        cb.parity_en  <= 1;
        cb.parity_odd <= 1;
        cb.stop_bits  <= 0;
        cb.tx_data    <= 8'h03;
        cb.tx_empty   <= 0;
        ##1;
        check_frame(8'h03, 8, 1, 1, 0);
        cb.tx_empty <= 1;
    `SVTEST_END

    // two stop bits: both are tx=1 for 16 ticks each
    `SVTEST(two_stop_bits)
        cb.data_bits  <= 4'd8;
        cb.parity_en  <= 0;
        cb.parity_odd <= 0;
        cb.stop_bits  <= 1;
        cb.tx_data    <= 8'hA5;
        cb.tx_empty   <= 0;
        ##1;
        check_frame(8'hA5, 8, 0, 0, 1);
        cb.tx_empty <= 1;
    `SVTEST_END

    // tx_busy asserts on the first tick of the start bit and deasserts on the
    // cycle following the last stop bit tick
    `SVTEST(tx_busy_timing)
        cb.data_bits  <= 4'd8;
        cb.parity_en  <= 0;
        cb.parity_odd <= 0;
        cb.stop_bits  <= 0;
        cb.tx_data    <= 8'hA5;
        cb.tx_empty   <= 0;
        ##1;
        `FAIL_UNLESS_EQUAL(cb.tx_busy, 1'b0);
        tick();
        `FAIL_UNLESS_EQUAL(cb.tx_busy, 1'b1);
        ticks(159);
        `FAIL_UNLESS_EQUAL(cb.tx_busy, 1'b0);
        cb.tx_empty <= 1;
    `SVTEST_END

    // back-to-back frames: second frame starts on the immediately following
    // baud_tick after the first frame completes, with no idle tick between
    `SVTEST(back_to_back_frames)
        logic [31:0] count_before;
        cb.data_bits  <= 4'd8;
        cb.parity_en  <= 0;
        cb.parity_odd <= 0;
        cb.stop_bits  <= 0;
        cb.tx_data    <= 8'hAA;
        cb.tx_empty   <= 0;
        ##1;
        fork
            begin : fifo_model
                @(posedge clk iff cb.tx_rd_en === 1'b1);
                cb.tx_data <= 8'h55;
                @(posedge clk iff cb.tx_rd_en === 1'b1);
                cb.tx_empty <= 1;
            end
        join_none
        check_frame(8'hAA, 8, 0, 0, 0);
        count_before = cb.tx_frame_count;
        tick();
        `FAIL_UNLESS_EQUAL(cb.tx,      1'b0);
        `FAIL_UNLESS_EQUAL(cb.tx_busy, 1'b1);
        ticks(159);
        `FAIL_UNLESS_EQUAL(cb.tx_frame_count, count_before + 1);
        disable fifo_model;
    `SVTEST_END

    // frame config is latched at frame start; changes mid-frame take effect on
    // the next frame
    `SVTEST(frame_config_latching)
        cb.data_bits  <= 4'd8;
        cb.parity_en  <= 0;
        cb.parity_odd <= 0;
        cb.stop_bits  <= 0;
        cb.tx_data    <= 8'hFF;
        cb.tx_empty   <= 0;
        ##1;
        fork
            begin : fifo_model
                @(posedge clk iff cb.tx_rd_en === 1'b1);
                cb.tx_data <= 8'hFF;
                @(posedge clk iff cb.tx_rd_en === 1'b1);
                cb.tx_empty <= 1;
            end
        join_none
        tick();
        ticks(79);
        cb.data_bits <= 4'd5;
        ticks(79);
        `FAIL_UNLESS_EQUAL(cb.tx_busy, 1'b1);
        tick();
        `FAIL_UNLESS_EQUAL(cb.tx_busy, 1'b0);
        check_frame(8'hFF, 5, 0, 0, 0);
        disable fifo_model;
    `SVTEST_END

    // tx_frame_count increments by 1 on the cycle tx_busy deasserts after
    // each transmitted frame
    `SVTEST(tx_frame_count_increments)
        logic [31:0] count_before;
        cb.data_bits  <= 4'd8;
        cb.parity_en  <= 0;
        cb.parity_odd <= 0;
        cb.stop_bits  <= 0;
        cb.tx_data    <= 8'hA5;
        cb.tx_empty   <= 0;
        ##1;
        count_before = cb.tx_frame_count;
        check_frame(8'hA5, 8, 0, 0, 0);
        `FAIL_UNLESS_EQUAL(cb.tx_frame_count, count_before + 1);
        cb.tx_empty <= 1;
    `SVTEST_END

    // tx stays idle after a frame completes when tx_empty is asserted
    `SVTEST(idle_after_frame_completes)
        cb.data_bits  <= 4'd8;
        cb.parity_en  <= 0;
        cb.parity_odd <= 0;
        cb.stop_bits  <= 0;
        cb.tx_data    <= 8'hA5;
        cb.tx_empty   <= 0;
        ##1;
        check_frame(8'hA5, 8, 0, 0, 0);
        cb.tx_empty <= 1;
        ##1;
        ticks(20);
        `FAIL_UNLESS_EQUAL(cb.tx,      1'b1);
        `FAIL_UNLESS_EQUAL(cb.tx_busy, 1'b0);
    `SVTEST_END

    // parity is computed over only the transmitted data bits; uses 5-bit frame
    // with upper bits set to expose any incorrect 8-bit parity calculation
    `SVTEST(parity_5bit_data)
        cb.data_bits  <= 4'd5;
        cb.parity_en  <= 1;
        cb.parity_odd <= 0;
        cb.stop_bits  <= 0;
        cb.tx_data    <= 8'hE1;
        cb.tx_empty   <= 0;
        ##1;
        check_frame(8'hE1, 5, 1, 0, 0);
        cb.tx_empty <= 1;
    `SVTEST_END

    // tx_busy deasserts on the cycle following the last stop bit tick for a
    // frame with two stop bits (8N2: 16 + 128 + 32 = 176 ticks)
    `SVTEST(tx_busy_timing_two_stop_bits)
        cb.data_bits  <= 4'd8;
        cb.parity_en  <= 0;
        cb.parity_odd <= 0;
        cb.stop_bits  <= 1;
        cb.tx_data    <= 8'hA5;
        cb.tx_empty   <= 0;
        ##1;
        `FAIL_UNLESS_EQUAL(cb.tx_busy, 1'b0);
        tick();
        `FAIL_UNLESS_EQUAL(cb.tx_busy, 1'b1);
        ticks(175);
        `FAIL_UNLESS_EQUAL(cb.tx_busy, 1'b0);
        cb.tx_empty <= 1;
    `SVTEST_END

    // tx_frame_count increments correctly across two consecutive frames
    `SVTEST(tx_frame_count_two_frames)
        logic [31:0] count_before;
        cb.data_bits  <= 4'd8;
        cb.parity_en  <= 0;
        cb.parity_odd <= 0;
        cb.stop_bits  <= 0;
        cb.tx_data    <= 8'hA5;
        cb.tx_empty   <= 0;
        ##1;
        fork
            begin : fifo_model
                @(posedge clk iff cb.tx_rd_en === 1'b1);
                cb.tx_data <= 8'h5A;
                @(posedge clk iff cb.tx_rd_en === 1'b1);
                cb.tx_empty <= 1;
            end
        join_none
        count_before = cb.tx_frame_count;
        check_frame(8'hA5, 8, 0, 0, 0);
        `FAIL_UNLESS_EQUAL(cb.tx_frame_count, count_before + 1);
        check_frame(8'h5A, 8, 0, 0, 0);
        `FAIL_UNLESS_EQUAL(cb.tx_frame_count, count_before + 2);
        disable fifo_model;
    `SVTEST_END

    `SVUNIT_TESTS_END

endmodule : uart_tx_unit_test
