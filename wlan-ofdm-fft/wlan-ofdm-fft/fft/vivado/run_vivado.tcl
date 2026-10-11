# Run from the fft/ folder:  vivado -mode batch -source vivado/run_vivado.tcl
# Arty S7-25:                vivado -mode batch -source vivado/run_vivado.tcl -tclargs xc7s25csga324-1
# Out of context: FFT core only, no I/O pins.

set part xc7s50csga324-1
if {$argc > 0} { set part [lindex $argv 0] }
puts "Using part: $part"

if {![file exists data/twiddle.mem]} {
    error "data/twiddle.mem not found. Run fft_model.m first and start Vivado from the fft/ folder."
}

file mkdir reports
read_verilog [glob rtl/*.v]
read_xdc vivado/clock.xdc

synth_design -top fft_top -part $part -mode out_of_context
report_utilization -file reports/utilization_synth.rpt

opt_design
place_design
route_design

report_utilization    -file reports/utilization_impl.rpt
report_timing_summary -file reports/timing_summary.rpt

set slack [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
puts "Worst setup slack (WNS) at 10 ns clock: $slack ns"
if {$slack >= 0} {
    puts [format "Timing met. Rough Fmax = %.1f MHz" [expr {1000.0 / (10.0 - $slack)}]]
} else {
    puts "Timing NOT met at 100 MHz"
}
