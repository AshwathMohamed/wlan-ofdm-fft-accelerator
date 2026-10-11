`timescale 1ns/1ps
// Radix-2 DIT butterfly, 4-clock pipeline: t = W*x1, y0 = (x0+t)/2, y1 = (x0-t)/2 (Q1.15).
// Rounding happens only in the last stage: x0*2^15 +/- W*x1 is kept at full precision (Q2.30),
// then 2^15 is added and the sum is shifted right by 16 (divide by 2 and Q2.30 -> Q1.15).
// So it is round half up. No saturation: keep |input| <= 1.
module butterfly (
    input                clk,
    input                rst,
    input                vin,
    input  signed [15:0] x0_re, x0_im,
    input  signed [15:0] x1_re, x1_im,
    input  signed [15:0] w_re,  w_im,
    output reg           vout,
    output reg signed [15:0] y0_re, y0_im,
    output reg signed [15:0] y1_re, y1_im
);
    // x1 = a + jb, W = c + jd
    reg signed [15:0] a, b, c, d;
    reg signed [15:0] x0_re_1, x0_im_1;
    reg               v1;

    // four multipliers (DSP48)
    (* use_dsp = "yes" *) reg signed [31:0] p_ac, p_bd, p_ad, p_bc;
    reg signed [15:0] x0_re_2, x0_im_2;
    reg               v2;

    // t = W*x1 (Q2.30)
    reg signed [32:0] t_re, t_im;
    reg signed [15:0] x0_re_3, x0_im_3;
    reg               v3;

    wire signed [33:0] x0_re_ext = {{3{x0_re_3[15]}}, x0_re_3, 15'b0};
    wire signed [33:0] x0_im_ext = {{3{x0_im_3[15]}}, x0_im_3, 15'b0};
    wire signed [33:0] half = 34'sd32768;

    wire signed [33:0] s0_re = x0_re_ext + t_re + half;
    wire signed [33:0] s1_re = x0_re_ext - t_re + half;
    wire signed [33:0] s0_im = x0_im_ext + t_im + half;
    wire signed [33:0] s1_im = x0_im_ext - t_im + half;

    always @(posedge clk) begin
        a <= x1_re;  b <= x1_im;  c <= w_re;  d <= w_im;
        x0_re_1 <= x0_re;  x0_im_1 <= x0_im;

        p_ac <= a * c;
        p_bd <= b * d;
        p_ad <= a * d;
        p_bc <= b * c;
        x0_re_2 <= x0_re_1;  x0_im_2 <= x0_im_1;

        t_re <= p_ac - p_bd;
        t_im <= p_ad + p_bc;
        x0_re_3 <= x0_re_2;  x0_im_3 <= x0_im_2;

        // shift right by 16
        y0_re <= s0_re[31:16];
        y1_re <= s1_re[31:16];
        y0_im <= s0_im[31:16];
        y1_im <= s1_im[31:16];
    end

    always @(posedge clk) begin
        if (rst) begin
            v1 <= 1'b0;  v2 <= 1'b0;  v3 <= 1'b0;  vout <= 1'b0;
        end else begin
            v1 <= vin;  v2 <= v1;  v3 <= v2;  vout <= v3;
        end
    end
endmodule
