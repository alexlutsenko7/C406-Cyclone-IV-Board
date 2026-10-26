# Builds one stress-test bitstream per clock frequency:
#   quartus_sh -t build.tcl [MHz ...]       (default: all of 100 133 150 166)
package require ::quartus::project
package require ::quartus::flow

# MHz -> {PLL multiply, PLL divide, period in ps} from the 50 MHz oscillator
set freqs {
    100 {2 1 10000}
    133 {8 3 7500}
    150 {3 1 6667}
    166 {10 3 6000}
}

set here [file dirname [file normalize [info script]]]
set want [expr {[llength $quartus(args)] ? $quartus(args) : [dict keys $freqs]}]
foreach mhz $want {
    lassign [dict get $freqs $mhz] mul div ps
    set dir [file join $here build_$mhz]
    file mkdir $dir
    cd $dir
    project_new sdram_stress -overwrite
    source [file join $here .. board c406_pins.tcl]
    set_global_assignment -name TOP_LEVEL_ENTITY sdram_stress
    set_global_assignment -name VERILOG_FILE [file join $here sdram_stress.v]
    set_global_assignment -name SDC_FILE [file join $here sdram_stress.sdc]
    set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files
    set_parameter -name PLL_MUL $mul
    set_parameter -name PLL_DIV $div
    set_parameter -name CLK_PS $ps
    foreach sig {sdr_cs_n sdr_ras_n sdr_cas_n sdr_we_n sdr_ba[*] sdr_a[*] sdr_dq[*]} {
        set_instance_assignment -name FAST_OUTPUT_REGISTER ON -to $sig
    }
    set_instance_assignment -name FAST_INPUT_REGISTER ON -to sdr_dq[*]
    set_instance_assignment -name FAST_OUTPUT_ENABLE_REGISTER ON -to sdr_dq[*]
    if {[catch {execute_flow -compile} err]} {
        puts stderr "$mhz MHz: compilation failed: $err"
        project_close
        exit 1
    }
    project_close
    puts "$mhz MHz: done"
}
