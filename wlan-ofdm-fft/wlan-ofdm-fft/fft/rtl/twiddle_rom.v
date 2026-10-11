`timescale 1ns/1ps
// 512-entry twiddle ROM, word = {cos, -sin} in Q1.15, loaded from data/twiddle.mem.
// Start the simulator / Vivado from the fft/ folder.
module twiddle_rom #(
    parameter FILE = "data/twiddle.mem"
)(
    input               clk,
    input  [8:0]        addr,
    output reg [31:0]   data
);
    (* rom_style = "block" *) reg [31:0] rom [0:511];

    initial $readmemh(FILE, rom);

    always @(posedge clk) data <= rom[addr];
endmodule
