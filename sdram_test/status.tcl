# Reads the SDRAM self-test status over JTAG:  quartus_stp -t status.tcl [capture_delay 0-3]
package require ::quartus::insystem_source_probe

set hw [lindex [get_hardware_names] 0]
foreach h [get_hardware_names] { if {[string match *USB-Blaster* $h]} { set hw $h; break } }
set dev [lindex [get_device_names -hardware_name $hw] 0]
start_insystem_source_probe -hardware_name $hw -device_name $dev

if {[llength $quartus(args)] > 0} {
    set d [lindex $quartus(args) 0]
    write_source_data -instance_index 0 -value [format %d%d [expr {($d >> 1) & 1}] [expr {$d & 1}]]
    puts "Capture delay set to $d - press the KEY to restart the test"
}

# Probe, MSB first: state(4) reading(1) pass(16) errors(16) err_addr(24) err_exp(16) err_got(16)
set s [read_probe_data -instance_index 0]
proc field {s from len} { return [expr "0b[string range $s $from [expr {$from + $len - 1}]]"] }
set state    [field $s 0 4]
set reading  [field $s 4 1]
set pass     [field $s 5 16]
set errors   [field $s 21 16]
set err_addr [field $s 37 24]
set err_exp  [field $s 61 16]
set err_got  [field $s 77 16]
puts [format "Passes: %d   Errors: %d   Phase: %s   Capture delay: %s" \
    $pass $errors [expr {$reading ? "check" : "fill"}] [read_source_data -instance_index 0]]
if {$errors} {
    puts [format "First error: bank %d row %d col %d  expected %04X  got %04X  (diff bits %04X)" \
        [expr {$err_addr >> 22}] [expr {($err_addr >> 9) & 0x1FFF}] [expr {$err_addr & 0x1FF}] \
        $err_exp $err_got [expr {$err_exp ^ $err_got}]]
}
end_insystem_source_probe
