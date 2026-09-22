// UART receiver.
//
// The incoming line is asynchronous to clk, so it goes through a
// two-flop synchroniser before anything looks at it (otherwise a start
// edge arriving near a clock edge can put the FSM into a metastable
// state).
//
// Sampling: on a falling edge the FSM waits 8 ticks (half a bit time at
// 16x oversampling) and re-checks the line. If it has gone high again
// the edge was noise and the receiver returns to idle. Otherwise it is
// now aligned to the middle of the start bit, and every subsequent 16
// ticks land in the middle of a data bit.
//
// Error flags, valid alongside rx_valid:
//   parity_err  : received parity bit disagrees with the computed one
//   frame_err   : stop bit was not high (line still low when it should
//                 have returned to idle) -- typically a baud mismatch

module uart_rx (
    input            clk,
    input            rst_n,
    input            tick,        // 16x baud tick from baud_gen

    input      [3:0] data_bits,
    input            parity_en,
    input            parity_odd,

    input            rx,          // asynchronous serial input
    output reg [7:0] rx_data,
    output reg       rx_valid,    // one clock pulse when a frame completes
    output reg       parity_err,
    output reg       frame_err,
    output reg       rx_busy
);

    localparam S_IDLE   = 3'd0,
               S_START  = 3'd1,
               S_DATA   = 3'd2,
               S_PARITY = 3'd3,
               S_STOP   = 3'd4;

    // two-flop synchroniser for the asynchronous input
    reg rx_meta, rx_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_meta <= 1'b1;
            rx_sync <= 1'b1;
        end else begin
            rx_meta <= rx;
            rx_sync <= rx_meta;
        end
    end

    reg [2:0] state;
    reg [3:0] tick_cnt;
    reg [3:0] bit_idx;
    reg [7:0] shreg;
    reg       parity_acc, parity_bit;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            tick_cnt   <= 4'd0;
            bit_idx    <= 4'd0;
            shreg      <= 8'd0;
            rx_data    <= 8'd0;
            rx_valid   <= 1'b0;
            parity_err <= 1'b0;
            frame_err  <= 1'b0;
            rx_busy    <= 1'b0;
            parity_acc <= 1'b0;
            parity_bit <= 1'b0;
        end else begin
            rx_valid <= 1'b0;

            case (state)
                S_IDLE: begin
                    rx_busy <= 1'b0;
                    if (!rx_sync) begin           // start bit edge
                        tick_cnt   <= 4'd0;
                        parity_acc <= 1'b0;
                        bit_idx    <= 4'd0;
                        shreg      <= 8'd0;
                        rx_busy    <= 1'b1;
                        state      <= S_START;
                    end
                end

                S_START: if (tick) begin
                    if (tick_cnt == 4'd7) begin   // middle of start bit
                        tick_cnt <= 4'd0;
                        if (rx_sync) begin
                            rx_busy <= 1'b0;      // false start, glitch
                            state   <= S_IDLE;
                        end else begin
                            state <= S_DATA;
                        end
                    end else begin
                        tick_cnt <= tick_cnt + 4'd1;
                    end
                end

                S_DATA: if (tick) begin
                    if (tick_cnt == 4'd15) begin  // middle of data bit
                        tick_cnt   <= 4'd0;
                        shreg      <= {rx_sync, shreg[7:1]};
                        parity_acc <= parity_acc ^ rx_sync;
                        if (bit_idx == data_bits - 4'd1) begin
                            state <= parity_en ? S_PARITY : S_STOP;
                        end else begin
                            bit_idx <= bit_idx + 4'd1;
                        end
                    end else begin
                        tick_cnt <= tick_cnt + 4'd1;
                    end
                end

                S_PARITY: if (tick) begin
                    if (tick_cnt == 4'd15) begin
                        tick_cnt   <= 4'd0;
                        parity_bit <= rx_sync;
                        state      <= S_STOP;
                    end else begin
                        tick_cnt <= tick_cnt + 4'd1;
                    end
                end

                S_STOP: if (tick) begin
                    if (tick_cnt == 4'd15) begin
                        tick_cnt <= 4'd0;
                        // right-align the payload: bits shifted in from
                        // the MSB end, so shift down by (8 - data_bits)
                        rx_data  <= shreg >> (4'd8 - data_bits);
                        frame_err  <= ~rx_sync;    // stop bit must be high
                        parity_err <= parity_en &&
                                      (parity_bit != (parity_odd ? ~parity_acc
                                                                  :  parity_acc));
                        rx_valid <= 1'b1;
                        rx_busy  <= 1'b0;
                        state    <= S_IDLE;
                    end else begin
                        tick_cnt <= tick_cnt + 4'd1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
