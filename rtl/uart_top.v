// UART top level: one baud generator shared by the transmitter and
// receiver, plus the configuration inputs that both of them use.
//
// Loopback for bring-up: tie rx to tx externally and the receiver
// should return exactly what the transmitter sent.

module uart_top (
    input            clk,
    input            rst_n,

    // configuration
    input     [15:0] divisor,      // clk / (baud * 16)
    input     [3:0]  data_bits,    // 5..8
    input            parity_en,
    input            parity_odd,   // 0 = even, 1 = odd
    input            stop2,        // 0 = 1 stop bit, 1 = 2 stop bits

    // transmit side
    input     [7:0]  tx_data,
    input            tx_start,
    output           tx_busy,
    output           tx_done,
    output           tx,

    // receive side
    input            rx,
    output    [7:0]  rx_data,
    output           rx_valid,
    output           parity_err,
    output           frame_err,
    output           rx_busy
);

    wire tick;

    baud_gen u_baud (
        .clk     (clk),
        .rst_n   (rst_n),
        .divisor (divisor),
        .tick    (tick)
    );

    uart_tx u_tx (
        .clk        (clk),
        .rst_n      (rst_n),
        .tick       (tick),
        .data_bits  (data_bits),
        .parity_en  (parity_en),
        .parity_odd (parity_odd),
        .stop2      (stop2),
        .tx_data    (tx_data),
        .tx_start   (tx_start),
        .tx_busy    (tx_busy),
        .tx_done    (tx_done),
        .tx         (tx)
    );

    uart_rx u_rx (
        .clk        (clk),
        .rst_n      (rst_n),
        .tick       (tick),
        .data_bits  (data_bits),
        .parity_en  (parity_en),
        .parity_odd (parity_odd),
        .rx         (rx),
        .rx_data    (rx_data),
        .rx_valid   (rx_valid),
        .parity_err (parity_err),
        .frame_err  (frame_err),
        .rx_busy    (rx_busy)
    );

    // Simulation-only waveform dump, harmless if never opened.
    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, uart_top);
    end

endmodule
