# WLAN OFDM Baseband Simulation and FFT Accelerator

Two parts in one repo:

* **Part A (`ofdm/`)**: Python simulation of an IEEE 802.11a-style OFDM link with QAM-16 and QAM-64.
* **Part B (`fft/`)**: 1024-point radix-2 FFT accelerator in Verilog (Q1.15), with a MATLAB/Octave bit-true model, a testbench and Vivado scripts for the Arty S7.

## Folder layout

```
ofdm/ofdm_sim.py          OFDM chain + BER plots
ofdm/results/             PNG plots and CSV are written here
fft/rtl/                  fft_top, butterfly, ram_sdp, twiddle_rom
fft/tb/fft_tb.v           testbench (reads a file, writes a file, prints latency)
fft/matlab/fft_model.m    twiddles, test vectors, bit-true model, SQNR, RTL check
fft/data/                 twiddle.mem, input vectors (model and RTL outputs are written here)
fft/vivado/               Vivado batch script + clock constraint
fft/reports/              latency, SQNR/match and Vivado reports are written here
```

## Part A - OFDM chain

What it does:

1. Random bits are mapped to Gray-coded QAM-16 or QAM-64.
2. A 64-point IFFT builds each OFDM symbol: 48 data subcarriers, 4 pilots, DC and guard bands set to zero. A 16-sample cyclic prefix is added.
3. A frame is 1 known training symbol followed by 10 data symbols.
4. Channel: 4-tap multipath (delays 0, 2, 5, 9 samples, all inside the CP, new random channel for each frame) plus AWGN.
5. Receiver: remove the CP, FFT, least-squares channel estimate from the training symbol, zero-forcing equalizer (divide by the estimated channel), hard-decision demapper.

Three BER versus SNR experiments are run (SNR is Es/N0 per used subcarrier):

1. **AWGN only vs theory.** Checks that the chain is correct. It is compared with the Gray-coded square-QAM formula (nearest-neighbour approximation, tight below BER of about 1e-2).
2. **Multipath + LS channel estimate + ZF.**
3. **Multipath + perfect channel knowledge + ZF**, for comparison.

Run:

```
pip install -r ofdm/requirements.txt
python ofdm/ofdm_sim.py          # add --quick for a fast but noisy test
```

It saves `ber_awgn_vs_theory.png`, `ber_multipath.png` and `ber_results.csv` in `ofdm/results/`.

Notes:
* Pilots are inserted like 802.11a, but the receiver does not use them (the channel is static within a frame and there is no frequency offset).
* ZF boosts the noise on faded subcarriers, so multipath BER is much higher than AWGN BER.
* The LS estimate comes from one noisy training symbol, so it is worse than the perfect channel.

## Part B - FFT accelerator

How it works:

* Radix-2 decimation-in-time, 1024 points, 16-bit signed Q1.15 for real and imaginary parts.
* One butterfly unit (4-stage pipeline, four registered 16x16 multipliers for DSP48 inference).
* Ping-pong memories A and B (1024 x 32 bit, written in the standard style so Vivado infers BRAM). Even stages read A and write B, odd stages the opposite.
* Twiddle ROM (512 entries) loaded with `$readmemh` from `fft/data/twiddle.mem`, which is made by the MATLAB script.
* Small FSM: IDLE, RUN (1024 read clocks per stage, two reads per butterfly), DRAIN (6 clocks to flush the pipeline), 10 stages.
* Scaling by 1/2 in every stage, so output = FFT / 1024 and nothing overflows when the input magnitude is <= 1.
* Input is written to bit-reversed addresses, so the output comes out in natural order.

**Where rounding happens:** only in the last step of `butterfly.v`. The sum `x0*2^15 +/- W*x1` is kept at full precision (Q2.30). Then 2^15 is added and the sum is shifted right by 16. That one shift does both the divide-by-2 and the Q2.30 to Q1.15 conversion (round half up). There is no saturation. The twiddles are rounded to Q1.15 when the ROM file is made (+1.0 is stored as 32767).

**Testbench:** reads `data/in_<name>.mem`, runs the FFT, writes `data/rtl_<name>.mem` and writes the latency (clock cycles from start to done) to `reports/latency.txt`.

**MATLAB/Octave script:** makes the twiddle file and the test vectors, runs a bit-true fixed-point model of the same algorithm and scaling, runs the floating-point `fft()`, reports the SQNR, and compares the RTL output with the model sample by sample.

SQNR = 10*log10( sum|ref|^2 / sum|fixed - ref|^2 ), where ref = fft(x)/1024 in double precision.

Test vectors: random complex samples (each part within +-0.7), a complex tone at bin 100 (amplitude 0.9), and an impulse of 0.9 at n = 0.

### How to run (from the `fft/` folder)

```
cd fft

# 1) make twiddle file and test vectors, run the bit-true model
octave matlab/fft_model.m

# 2) RTL simulation (Vivado simulator, or Icarus Verilog)
xvlog rtl/ram_sdp.v rtl/twiddle_rom.v rtl/butterfly.v rtl/fft_top.v tb/fft_tb.v
xelab fft_tb -s fft_sim
xsim fft_sim -runall
#   iverilog -g2005 -o sim.vvp rtl/ram_sdp.v rtl/twiddle_rom.v rtl/butterfly.v rtl/fft_top.v tb/fft_tb.v
#   vvp sim.vvp

# 3) run the model again: it now also compares the RTL output with the model
octave matlab/fft_model.m

# 4) Vivado synthesis + implementation (Arty S7-25: add  -tclargs xc7s25csga324-1)
vivado -mode batch -source vivado/run_vivado.tcl
```

Step 4 uses the part `xc7s50csga324-1` (Arty S7-50) by default. It builds the FFT core only (out of context, no I/O pins) at 100 MHz and writes the utilization and timing reports to `fft/reports/`.

### Limits

* One butterfly and one read port per memory, so about one butterfly every 2 clocks.
* No saturation; the input must stay within |x| <= 1.
* Fixed 1/2 scaling per stage loses precision on small signals.
