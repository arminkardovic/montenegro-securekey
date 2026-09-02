`default_nettype none
`timescale 1ns / 1ps

module tb ();
    reg        clk;
    reg        rst_n;
    reg        ena;
    reg  [7:0] ui_in;
    reg  [7:0] uio_in;
    wire [7:0] uo_out;
    wire [7:0] uio_out;
    wire [7:0] uio_oe;

    initial begin
        $dumpfile("tb.fst");
        $dumpvars(0, tb);
    end

`ifdef GL_TEST
    wire VPWR = 1'b1;
    wire VGND = 1'b0;

    tt_um_arminkardovic_montenegro_securekey user_project (
        .VPWR   (VPWR),
        .VGND   (VGND),
`else
    // Faster melody timing for RTL simulation. Authentication timing and
    // results are identical to the silicon configuration.
    tt_um_arminkardovic_montenegro_securekey #(
        .CLOCK_HZ        (100_000),
        .NOTE_UNIT_CYCLES(500)
    ) user_project (
`endif
        .ui_in  (ui_in),
        .uo_out (uo_out),
        .uio_in (uio_in),
        .uio_out(uio_out),
        .uio_oe (uio_oe),
        .ena    (ena),
        .clk    (clk),
        .rst_n  (rst_n)
    );

endmodule

`default_nettype wire
