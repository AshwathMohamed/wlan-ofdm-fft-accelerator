`timescale 1ns/1ps
// Run from the fft/ folder. Reads data/in_<name>.mem, writes data/rtl_<name>.mem,
// and reports latency (clock edge that sees start -> clock edge that sees done).
module fft_tb;
    reg clk = 0;
    always #5 clk = ~clk;

    reg         rst = 1, start = 0, in_we = 0;
    reg  [9:0]  in_addr = 0, out_addr = 0;
    reg  [15:0] in_re = 0, in_im = 0;
    wire        busy, done;
    wire [15:0] out_re, out_im;

    fft_top dut (
        .clk(clk), .rst(rst),
        .in_we(in_we), .in_addr(in_addr), .in_re(in_re), .in_im(in_im),
        .start(start), .busy(busy), .done(done),
        .out_addr(out_addr), .out_re(out_re), .out_im(out_im)
    );

    reg [31:0] in_mem  [0:1023];
    reg [31:0] out_mem [0:1023];
    integer n, fd_out, fd_lat;
    integer cyc, t_start, t_done, latency;

    initial cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    task run_one;
        begin
            if (^in_mem[1023] === 1'bx) begin
                $display("ERROR: input file not read. Run from the fft/ folder after fft_model.m");
                $finish;
            end
            for (n = 0; n < 1024; n = n + 1) begin
                @(negedge clk);
                in_we = 1;  in_addr = n;
                in_re = in_mem[n][31:16];
                in_im = in_mem[n][15:0];
            end
            @(negedge clk);  in_we = 0;
            @(negedge clk);  start = 1;
            @(posedge clk);  t_start = cyc;
            @(negedge clk);  start = 0;
            @(posedge clk);
            while (done !== 1'b1) @(posedge clk);
            t_done  = cyc;
            latency = t_done - t_start;
            for (n = 0; n < 1024; n = n + 1) begin
                @(negedge clk);  out_addr = n;
                @(posedge clk);  #1;
                out_mem[n] = {out_re, out_im};
            end
        end
    endtask

    `define DO_TEST(NAME, IN_FILE, OUT_FILE) \
        begin \
            $readmemh(IN_FILE, in_mem); \
            run_one; \
            fd_out = $fopen(OUT_FILE, "w"); \
            for (n = 0; n < 1024; n = n + 1) $fwrite(fd_out, "%08x\n", out_mem[n]); \
            $fclose(fd_out); \
            $display("%s: latency = %0d clock cycles", NAME, latency); \
            $fwrite(fd_lat, "%s: latency = %0d clock cycles (start to done)\n", NAME, latency); \
        end

    initial begin
        fd_lat = $fopen("reports/latency.txt", "w");
        repeat (4) @(posedge clk);
        rst = 0;
        repeat (2) @(posedge clk);

        `DO_TEST("random",  "data/in_random.mem",  "data/rtl_random.mem")
        `DO_TEST("tone",    "data/in_tone.mem",    "data/rtl_tone.mem")
        `DO_TEST("impulse", "data/in_impulse.mem", "data/rtl_impulse.mem")

        $fclose(fd_lat);
        $display("simulation finished");
        $finish;
    end

    initial begin
        #50000000;
        $display("TIMEOUT: done never came");
        $finish;
    end
endmodule
