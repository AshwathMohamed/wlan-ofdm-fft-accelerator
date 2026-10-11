`timescale 1ns/1ps
// 1024-point radix-2 DIT FFT, Q1.15. One butterfly, ping-pong memories A/B, twiddle ROM, FSM.
// Output = FFT / 1024 (1/2 scaling per stage).
// Use: write 1024 samples (in_we/in_addr), pulse start, wait for done, read out_addr (1 clock later).
// Input goes to bit-reversed addresses, so the output is in natural order.
// Even stages read A and write B, odd stages the opposite, so the result ends in A.
// Per stage: 1024 read clocks + DRAIN_CYCLES.
module fft_top (
    input                clk,
    input                rst,
    input                in_we,
    input  [9:0]         in_addr,
    input  signed [15:0] in_re,
    input  signed [15:0] in_im,
    input                start,
    output reg           busy,
    output reg           done,
    input  [9:0]         out_addr,
    output signed [15:0] out_re,
    output signed [15:0] out_im
);
    localparam IDLE = 2'd0, RUN = 2'd1, DRAIN = 2'd2;
    localparam DRAIN_CYCLES = 6;      // RAM read 1 + butterfly 4 + second write 1

    reg [1:0] state;
    reg [3:0] stage;
    reg [9:0] cnt;                    // read slot in a stage, 0..1023
    reg [2:0] drain_cnt;

    // butterfly k (0..511) of stage s uses samples i0 and i1 = i0 + 2^s
    function [9:0] idx0;
        input [8:0] k;
        input [3:0] s;
        reg   [9:0] kk;
        begin
            kk   = {1'b0, k};
            idx0 = ((kk >> s) << (s + 1)) | (kk & ((10'd1 << s) - 10'd1));
        end
    endfunction

    function [9:0] idx1;
        input [8:0] k;
        input [3:0] s;
        begin
            idx1 = idx0(k, s) | (10'd1 << s);
        end
    endfunction

    // twiddle index = (k mod 2^s) * 2^(9-s)
    function [8:0] twidx;
        input [8:0] k;
        input [3:0] s;
        reg   [9:0] kk, j, sh;
        begin
            kk    = {1'b0, k};
            j     = kk & ((10'd1 << s) - 10'd1);
            sh    = j << (4'd9 - s);
            twidx = sh[8:0];
        end
    endfunction

    function [9:0] bitrev;
        input [9:0] a;
        integer i;
        begin
            for (i = 0; i < 10; i = i + 1) bitrev[i] = a[9 - i];
        end
    endfunction

    // read side: even cnt reads x0, odd cnt reads x1 (and the twiddle)
    wire [8:0] k_rd    = cnt[9:1];
    wire       ph_rd   = cnt[0];
    wire [9:0] rd_addr = ph_rd ? idx1(k_rd, stage) : idx0(k_rd, stage);
    wire [8:0] tw_addr = twidx(k_rd, stage);

    wire [31:0] ramA_rdata, ramB_rdata, tw_data;
    wire [31:0] rd_data = stage[0] ? ramB_rdata : ramA_rdata;

    twiddle_rom u_rom (.clk(clk), .addr(tw_addr), .data(tw_data));

    // memory data arrives 1 clock after the address
    reg        v1, ph1;
    reg [8:0]  k1;
    reg [31:0] x0_hold;
    always @(posedge clk) begin
        if (rst) v1 <= 1'b0;
        else     v1 <= (state == RUN);
        ph1 <= cnt[0];
        k1  <= cnt[9:1];
        if (v1 && !ph1) x0_hold <= rd_data;
    end
    wire bf_vin = v1 & ph1;           // x1 and twiddle are ready, start the butterfly

    wire               bf_vout;
    wire signed [15:0] y0_re, y0_im, y1_re, y1_im;

    butterfly u_bf (
        .clk(clk), .rst(rst), .vin(bf_vin),
        .x0_re(x0_hold[31:16]), .x0_im(x0_hold[15:0]),
        .x1_re(rd_data[31:16]), .x1_im(rd_data[15:0]),
        .w_re(tw_data[31:16]),  .w_im(tw_data[15:0]),
        .vout(bf_vout),
        .y0_re(y0_re), .y0_im(y0_im), .y1_re(y1_re), .y1_im(y1_im)
    );

    // write side: one write port, so y0 first and y1 one clock later.
    // k is delayed by the butterfly latency (4) to rebuild the write addresses.
    reg [8:0]  kd1, kd2, kd3, kd4, k_hold;
    reg [31:0] y1_hold;
    reg        wr1;
    always @(posedge clk) begin
        kd1 <= k1;  kd2 <= kd1;  kd3 <= kd2;  kd4 <= kd3;
        k_hold  <= kd4;
        y1_hold <= {y1_re, y1_im};
        if (rst) wr1 <= 1'b0;
        else     wr1 <= bf_vout;
    end

    wire        dst_we   = bf_vout | wr1;
    wire [9:0]  dst_addr = bf_vout ? idx0(kd4, stage) : idx1(k_hold, stage);
    wire [31:0] dst_data = bf_vout ? {y0_re, y0_im}   : y1_hold;

    // memory A is also used to load the input and read the output when idle
    wire        we_A    = busy ? (dst_we & stage[0]) : in_we;
    wire [9:0]  waddr_A = busy ? dst_addr            : bitrev(in_addr);
    wire [31:0] wdata_A = busy ? dst_data            : {in_re, in_im};
    wire [9:0]  raddr_A = busy ? rd_addr             : out_addr;

    wire        we_B    = busy & dst_we & ~stage[0];

    ram_sdp u_ramA (.clk(clk), .we(we_A), .waddr(waddr_A), .wdata(wdata_A),
                    .raddr(raddr_A), .rdata(ramA_rdata));
    ram_sdp u_ramB (.clk(clk), .we(we_B), .waddr(dst_addr), .wdata(dst_data),
                    .raddr(rd_addr), .rdata(ramB_rdata));

    assign out_re = ramA_rdata[31:16];
    assign out_im = ramA_rdata[15:0];

    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE;  busy <= 1'b0;  done <= 1'b0;
            stage <= 4'd0;  cnt <= 10'd0;  drain_cnt <= 3'd0;
        end else begin
            done <= 1'b0;
            case (state)
                IDLE: if (start) begin
                    state <= RUN;  busy <= 1'b1;  stage <= 4'd0;  cnt <= 10'd0;
                end
                RUN: begin
                    cnt <= cnt + 1'b1;
                    if (cnt == 10'd1023) begin
                        state <= DRAIN;  drain_cnt <= 3'd0;
                    end
                end
                DRAIN: begin
                    drain_cnt <= drain_cnt + 1'b1;
                    if (drain_cnt == DRAIN_CYCLES - 1) begin
                        if (stage == 4'd9) begin
                            state <= IDLE;  busy <= 1'b0;  done <= 1'b1;
                        end else begin
                            stage <= stage + 1'b1;  cnt <= 10'd0;  state <= RUN;
                        end
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
