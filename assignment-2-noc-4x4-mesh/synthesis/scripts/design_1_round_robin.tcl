
# -------------------------------------------------------
# Design and Path Variables
# -------------------------------------------------------
set DESIGN mkNoc
set _OUTPUTS_PATH ../outputs
set _REPORTS_PATH ../reports

# -------------------------------------------------------
# Library Setup - SAED14nm EDK 03_2025
# -------------------------------------------------------
set PDK_PATH "/home/tools/pdk/SAED14nm_EDK_03_2025"

set target_library [list]
set link_library "*"

set SYNOPSYS_ROOT "/home/tools/pd_tools/syn/U-2022.12"

set synthetic_library [list \
    $SYNOPSYS_ROOT/libraries/syn/dw_foundation.sldb \
    $SYNOPSYS_ROOT/libraries/syn/standard.sldb \
]

# Target library: SAED14 RVT, SS corner
set target_library [concat $target_library \
    $PDK_PATH/SAED14nm_EDK_STD_RVT/liberty/nldm/base/saed14rvt_base_ss0p72v125c.db \
]

# Link library
set link_library [concat $link_library \
    $PDK_PATH/SAED14nm_EDK_STD_RVT/liberty/nldm/base/saed14rvt_base_ss0p72v125c.db \
]

# Combine libraries
set link_library [concat $link_library $target_library $synthetic_library]

# -------------------------------------------------------
# Output Directory Setup and SVF
# -------------------------------------------------------
file mkdir ${_OUTPUTS_PATH}
file mkdir ${_REPORTS_PATH}

set_svf ${_OUTPUTS_PATH}/${DESIGN}.svf

# -------------------------------------------------------
# RTL Read and Elaboration
# -------------------------------------------------------
analyze -format verilog -autoread ../../rtl/
elaborate $DESIGN
current_design $DESIGN
link

# -------------------------------------------------------
# Apply Timing Constraints
# -------------------------------------------------------
source ../scripts/mkNoc.sdc

# -------------------------------------------------------
# Optimization Constraints
# -------------------------------------------------------
set_max_area 0
set_dont_retime $DESIGN true

# -------------------------------------------------------
# Path Group Setup
# -------------------------------------------------------
set unq_input_list [all_inputs]

foreach_in_collection unq_clock_element [all_clocks] {
    set unq_clock_name [get_port $unq_clock_element]
    set unq_input_list [remove_from_collection \
        $unq_input_list $unq_clock_name]
}

group_path -name f2f \
    -from [all_registers] \
    -to [all_registers] \
    -critical_range 0.15

group_path -name i2f \
    -from $unq_input_list \
    -to [all_registers] \
    -critical_range 0.15

group_path -name f2o \
    -from [all_registers] \
    -to [all_outputs] \
    -critical_range 0.15

group_path -name i2o \
    -from $unq_input_list \
    -to [all_outputs] \
    -critical_range 0.15

# -------------------------------------------------------
# Pre-Compile Design Check
# -------------------------------------------------------
check_design > ${_REPORTS_PATH}/check_design.pre_compile.rpt

# -------------------------------------------------------
# Synthesis
# -------------------------------------------------------
compile_ultra \
    -no_autoungroup \
    -no_seq_output_inversion \
    -timing_high_effort_script

# -------------------------------------------------------
# Naming Convention Enforcement
# -------------------------------------------------------
define_name_rules verilog -allowed "a-z A-Z 0-9 _ /"
change_names -hier -rules verilog

# -------------------------------------------------------
# Write Post-Synthesis Outputs
# -------------------------------------------------------
write -format verilog \
    -hierarchy \
    -output ${_OUTPUTS_PATH}/$DESIGN.verilog.v

write -format ddc \
    -hierarchy \
    -output ${_OUTPUTS_PATH}/$DESIGN.compile.ddc

# -------------------------------------------------------
# Timing and QoR Reports
# -------------------------------------------------------
report_qor > ${_REPORTS_PATH}/dc_compile_ultra_1.qor

report_timing \
    -nosplit \
    -max_paths 20 \
    -input \
    -nets \
    -cap \
    -tran \
    -sig 2 \
    -group f2f \
    > ${_REPORTS_PATH}/setup.f2f.tim.rpt

report_timing \
    -nosplit \
    -max_paths 20 \
    -input \
    -nets \
    -cap \
    -tran \
    -sig 2 \
    -group i2f \
    > ${_REPORTS_PATH}/setup.i2f.tim.rpt

report_timing \
    -nosplit \
    -max_paths 20 \
    -input \
    -nets \
    -cap \
    -tran \
    -sig 2 \
    -group f2o \
    > ${_REPORTS_PATH}/setup.f2o.tim.rpt

report_timing \
    -nosplit \
    -max_paths 20 \
    -input \
    -nets \
    -cap \
    -tran \
    -sig 3 \
    -group i2o \
    > ${_REPORTS_PATH}/setup.i2o.tim.rpt

# -------------------------------------------------------
# Post-Compile Design Check
# -------------------------------------------------------
check_design > ${_REPORTS_PATH}/check_design.dc_compile_1.rpt

# -------------------------------------------------------
# Multi-Port Net Fix
# -------------------------------------------------------
set verilogout_no_tri true

set_app_var compile_advanced_fix_multiple_port_nets true

set_fix_multiple_port_nets -all -buffer_constants

change_names -hier -rules verilog

# -------------------------------------------------------
# Write Final Netlist
# -------------------------------------------------------
write -format verilog \
    -hierarchy \
    -output ${_OUTPUTS_PATH}/$DESIGN.verilog_noassign.v

# -------------------------------------------------------
# Power Report
# -------------------------------------------------------
puts "=============================================="
puts "Generating power report..."
puts "=============================================="

report_power -verbose > ${_REPORTS_PATH}/power.rpt

puts "=============================================="
puts "Power report generated:"
puts "${_REPORTS_PATH}/power.rpt"
puts "=============================================="

# -------------------------------------------------------
# Exit
# -------------------------------------------------------
exit
