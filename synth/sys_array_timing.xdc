# ==============================================================================
# Xilinx Design Constraints (XDC) for 16x16 Systolic Array
# Target Device: AMD/Xilinx Artix-7 XC7A200T (Speed Grade -2)
# ==============================================================================

# Primary 500 MHz Clock Definition (Period = 2.000 ns)
create_clock -name clk -period 2.000 [get_ports clk]

# Clock Uncertainty (Jitter budget: 50 ps)
set_clock_uncertainty 0.050 [get_clocks clk]

# Out-Of-Context (OOC) boundary delay budget (0.400 ns = 20% of cycle)
set_input_delay  -clock clk 0.400 [all_inputs -no_clocks]
set_output_delay -clock clk 0.400 [all_outputs]
