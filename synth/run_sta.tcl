# ==============================================================================
# Vivado Batch Script: Place, Route, and Static Timing Analysis (STA)
# Target Device: AMD/Xilinx Artix-7 XC7A200T (xc7a200tfbg676-2)
# ==============================================================================

set TOP_MODULE  "sys_array"
set TARGET_PART "xc7a200tfbg676-2"
set REPORT_DIR  "reports"

file mkdir $REPORT_DIR

# 1. Read Design Netlist or RTL
if {[file exists "sys_array.edif"]} {
    puts "--> Loading EDIF Netlist (sys_array.edif)..."
    read_edif sys_array.edif
    link_design -top $TOP_MODULE -part $TARGET_PART -mode out_of_context
} elseif {[file exists "sys_array_synth.v"]} {
    puts "--> Loading Structural Verilog Netlist (sys_array_synth.v)..."
    read_verilog sys_array_synth.v
    link_design -top $TOP_MODULE -part $TARGET_PART -mode out_of_context
} else {
    puts "--> Netlist not found, synthesizing from SystemVerilog RTL in Vivado..."
    read_verilog -sv src/mac.sv
    read_verilog -sv src/PE.sv
    read_verilog -sv src/sys_array.sv
    synth_design -top $TOP_MODULE -part $TARGET_PART -mode out_of_context
}

# 2. Apply 500 MHz Timing Constraints
puts "--> Applying Timing Constraints (sys_array_timing.xdc)..."
read_xdc sys_array_timing.xdc

# 3. Post-Synthesis Estimated Timing Check
puts "--> Running Post-Synthesis STA..."
report_timing_summary -file $REPORT_DIR/post_synth_timing.rpt

# 4. Physical Implementation (Place and Route)
puts "--> Running Logic Optimization (opt_design)..."
opt_design

puts "--> Running Physical Placement (place_design)..."
place_design

puts "--> Running Physical Routing (route_design)..."
route_design

# 5. Final Sign-Off Post-Route Timing & Utilization Reports
puts "--> Generating Final Sign-Off Post-Route STA Reports..."
report_timing_summary -max_paths 10 -report_unconstrained -file $REPORT_DIR/post_route_timing.rpt
report_utilization -hierarchical -file $REPORT_DIR/post_route_utilization.rpt
report_clock_utilization -file $REPORT_DIR/clock_utilization.rpt

puts "\n========================================================"
puts "  STA & IMPLEMENTATION COMPLETE! Reports saved in $REPORT_DIR/"
puts "========================================================\n"
exit
