# Define the primary clock on the Clk port
# Clock period in ns. Change only this value between synthesis runs.
set PERIOD 1.0

create_clock -period $PERIOD -waveform [list 0.0 [expr $PERIOD/2.0]] [get_ports CLK]

# External delay = 40% of the clock period (per assignment)
set_input_delay  -clock CLK [expr 0.4*$PERIOD] [remove_from_collection [all_inputs] [get_ports CLK]]
set_output_delay -clock CLK [expr 0.4*$PERIOD] [all_outputs]
