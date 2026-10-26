# Builds the SDRAM self-test:  quartus_sh -t build.tcl
package require ::quartus::project
package require ::quartus::flow

cd [file dirname [file normalize [info script]]]
project_new sdram_test -overwrite
source ../board/c406_pins.tcl
set_global_assignment -name TOP_LEVEL_ENTITY sdram_test
set_global_assignment -name VERILOG_FILE sdram_test.v
set_global_assignment -name SDC_FILE sdram_test.sdc
set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files
# Keep the SDRAM interface registers in the I/O cells for predictable timing.
foreach sig {sdr_cs_n sdr_ras_n sdr_cas_n sdr_we_n sdr_ba[*] sdr_a[*] sdr_dq[*]} {
    set_instance_assignment -name FAST_OUTPUT_REGISTER ON -to $sig
}
set_instance_assignment -name FAST_INPUT_REGISTER ON -to sdr_dq[*]
set_instance_assignment -name FAST_OUTPUT_ENABLE_REGISTER ON -to sdr_dq[*]
if {[catch {execute_flow -compile} err]} {
    puts stderr "Compilation failed: $err"
    project_close
    exit 1
}
project_close
puts "Done: output_files/sdram_test.sof"
