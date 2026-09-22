// UART transmitter.
//
// Frame layout: 1 start bit (0), 5-8 data bits LSB first, optional
// parity bit, 1 or 2 stop bits (1).
//
// Handshake: assert tx_start for one clock with tx_data valid. The
// transmitter asserts tx_busy until the final stop bit has been driven,
// and pulses tx_done for one clock at the end of the frame. tx_start is
// ignored while busy, so back-to-back sends just need the sender to
// wait for tx_done (or !tx_busy) before starting the next byte.
//
// Configuration (sampled when a frame starts, so changing it mid-frame
// cannot corrupt the frame in flight):
//   data_bits  : 4'd5..4'd8   number of payload bits
//   parity_en  : enable parity bit
//   parity_odd : 0 = even parity, 1 = odd parity
//   stop2      : 0 = one stop bit, 1 = two stop bits

module uart_tx (
    input            clk,
    input            rst_n,
    input            tick,        // 16x baud tick from baud_gen

    input      [3:0] data_bits,
    input            parity_en,
    input            parity_odd,
    input            stop2,

    input      [7:0] tx_data,
    input            tx_start,
    output reg       tx_busy,
    output reg       tx_done,
    output reg       tx                // serial line, idles high
);

    localparam S_IDLE   = 3'd0,
               S_START  = 3'd1,
               S_DATA   = 3'd2,
               S_PARITY = 3'd3,
               S_STOP1  = 3'd4,
               S_STOP2  = 3'd5;

    reg [2:0]  state;
    reg [3:0]  tick_cnt;     // counts 0..15 within one bit time
    reg [3:0]  bit_idx;
    reg [7:0]  shreg;
    reg        parity_acc;

    // latched configuration for the frame currently being sent
    reg [3:0]  cfg_data_bits;
    reg        cfg_parity_en, cfg_parity_odd, cfg_stop2;

    wire bit_done = (tick_cnt == 4'd15);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            tx         <= 1'b1;
            tx_busy    <= 1'b0;
            tx_done    <= 1'b0;
            tick_cnt   <= 4'd0;
            bit_idx    <= 4'd0;
            shreg      <= 8'd0;
            parity_acc <= 1'b0;
        end else begin
            tx_done <= 1'b0;

            case (state)
                S_IDLE: begin
                    tx      <= 1'b1;
                    tx_busy <= 1'b0;
                    if (tx_start) begin
                        shreg          <= tx_data;
                        cfg_data_bits  <= data_bits;
                        cfg_parity_en  <= parity_en;
                        cfg_parity_odd <= parity_odd;
                        cfg_stop2      <= stop2;
                        parity_acc     <= 1'b0;
                        tick_cnt       <= 4'd0;
                        bit_idx        <= 4'd0;
                        tx_busy        <= 1'b1;
                        tx             <= 1'b0;   // start bit on the line
                        state          <= S_START;
                    end
                end

                S_START: if (tick) begin
                    if (bit_done) begin
                        tick_cnt <= 4'd0;
                        tx       <= shreg[0];
                        state    <= S_DATA;
                    end else begin
                        tick_cnt <= tick_cnt + 4'd1;
                    end
                end

                S_DATA: if (tick) begin
                    if (bit_done) begin
                        tick_cnt   <= 4'd0;
                        parity_acc <= parity_acc ^ shreg[0];
                        shreg      <= {1'b0, shreg[7:1]};
                        if (bit_idx == cfg_data_bits - 4'd1) begin
                            if (cfg_parity_en) begin
                                // parity over the data bits just sent
                                tx    <= cfg_parity_odd ? ~(parity_acc ^ shreg[0])
                                                         :  (parity_acc ^ shreg[0]);
                                state <= S_PARITY;
                            end else begin
                                tx    <= 1'b1;
                                state <= S_STOP1;
                            end
                        end else begin
                            bit_idx <= bit_idx + 4'd1;
                            tx      <= shreg[1];
                        end
                    end else begin
                        tick_cnt <= tick_cnt + 4'd1;
                    end
                end

                S_PARITY: if (tick) begin
                    if (bit_done) begin
                        tick_cnt <= 4'd0;
                        tx       <= 1'b1;
                        state    <= S_STOP1;
                    end else begin
                        tick_cnt <= tick_cnt + 4'd1;
                    end
                end

                S_STOP1: if (tick) begin
                    if (bit_done) begin
                        tick_cnt <= 4'd0;
                        if (cfg_stop2) begin
                            state <= S_STOP2;
                        end else begin
                            tx_done <= 1'b1;
                            tx_busy <= 1'b0;
                            state   <= S_IDLE;
                        end
                    end else begin
                        tick_cnt <= tick_cnt + 4'd1;
                    end
                end

                S_STOP2: if (tick) begin
                    if (bit_done) begin
                        tick_cnt <= 4'd0;
                        tx_done  <= 1'b1;
                        tx_busy  <= 1'b0;
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
