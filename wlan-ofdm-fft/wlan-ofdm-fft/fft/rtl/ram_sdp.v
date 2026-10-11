`timescale 1ns/1ps
// Simple dual-port RAM, read data appears 1 clock after the address (maps to BRAM).
module ram_sdp #(
    parameter AW = 10,
    parameter DW = 32
)(
    input               clk,
    input               we,
    input  [AW-1:0]     waddr,
    input  [DW-1:0]     wdata,
    input  [AW-1:0]     raddr,
    output reg [DW-1:0] rdata
);
    (* ram_style = "block" *) reg [DW-1:0] mem [0:(1<<AW)-1];

    always @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        rdata <= mem[raddr];
    end
endmodule
