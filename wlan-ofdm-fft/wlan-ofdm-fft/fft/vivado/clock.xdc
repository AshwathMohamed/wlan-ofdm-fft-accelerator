# 100 MHz clock (the Arty S7 board oscillator is 100 MHz)
create_clock -period 10.000 -name clk [get_ports clk]
