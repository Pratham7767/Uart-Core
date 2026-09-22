// Baud rate generator.
//
// Produces a tick at 16x the configured baud rate. The receiver uses all
// 16 ticks per bit so it can sample in the middle of each bit; the
// transmitter counts 16 ticks to advance one bit time.
//
// divisor = round(clk_freq / (baud * 16))
// e.g. 50 MHz clock, 115200 baud -> 50e6 / (115200*16) = 27
//
// The divisor is a runtime input, not a parameter, so the baud rate can
// be reprogrammed without resynthesising.

module baud_gen (
    input             clk,
    input             rst_n,
    input      [15:0] divisor,     // clocks per 16x tick, must be >= 1
    output reg        tick         // one clk-wide pulse at 16x baud
);
    reg [15:0] count;

    wire [15:0] reload = (divisor == 16'd0) ? 16'd1 : divisor;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            count <= 16'd0;
            tick  <= 1'b0;
        end else if (count >= reload - 16'd1) begin
            count <= 16'd0;
            tick  <= 1'b1;
        end else begin
            count <= count + 16'd1;
            tick  <= 1'b0;
        end
    end
endmodule
