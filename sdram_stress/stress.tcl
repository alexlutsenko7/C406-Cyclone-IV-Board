# Host side of the SDRAM stress test. Program a build_<MHz> bitstream first, then:
#   quartus_stp -t stress.tcl <steps_per_period> [full] [soak_runs] [retention_s]
# <steps_per_period> = clock period / PLL phase step (from the fitter's PLL report).
#
# 1. Sweep: at every SDRAM-clock phase step, fill 64K words and check them with each
#    read-capture delay (0..3), using checkerboard and random data. Prints a pass map.
# 2. Moves to the centre of the widest passing window.
# 3. With "full": every pattern and its inverse over all 32 MB, a retention test
#    (fill, wait with refresh only, check), then soak runs of random data.
package require ::quartus::insystem_source_probe

lassign $quartus(args) nsteps full soak retention
if {$soak eq ""} { set soak 10 }
if {$retention eq ""} { set retention 30 }

set hw [lindex [get_hardware_names] 0]
foreach h [get_hardware_names] { if {[string match *USB-Blaster* $h]} { set hw $h; break } }
set dev [lindex [get_device_names -hardware_name $hw] 0]
set inst 0
foreach info [get_insystem_source_probe_instance_info -hardware_name $hw -device_name $dev] {
    if {[lindex $info 3] eq "SDS"} { set inst [lindex $info 0] }
}
start_insystem_source_probe -hardware_name $hw -device_name $dev

# ---- source / probe access ----------------------------------------------------------
set src [read_source_data -instance_index $inst]
foreach {name from len} {seed 0 8 len 8 2 cap 10 2 inv 12 1 mode 13 3 step 16 1 check 17 1 fill 18 1} {
    set S($name) [expr "0b[string range $src $from [expr {$from + $len - 1}]]"]
}

proc put {} {
    global S inst
    set v [format "%08b%02b%02b%01b%03b%01b%01b%01b" $S(seed) $S(len) $S(cap) $S(inv) $S(mode) \
        $S(step) $S(check) $S(fill)]
    write_source_data -instance_index $inst -value $v
}

proc probe {} {
    global inst
    set s [read_probe_data -instance_index $inst]
    set d {}
    foreach {name from len} {locked 0 1 step_ack 1 8 done 9 8 busy 17 1 errors 18 32
                             err_bits 50 16 err_addr 66 24 err_exp 90 16 err_got 106 16} {
        dict set d $name [expr "0b[string range $s $from [expr {$from + $len - 1}]]"]
    }
    return $d
}

proc wait_for {key old timeout_ms} {
    set end [expr {[clock milliseconds] + $timeout_ms}]
    while {[clock milliseconds] < $end} {
        set p [probe]
        if {[dict get $p $key] != $old} { return $p }
        after 2
    }
    error "timeout waiting for $key"
}

# Runs one fill or check over the region; returns the probe after it finished.
proc op {kind mode inv cap len seed} {
    global S
    array set S [list mode $mode inv $inv cap $cap len $len seed $seed]
    put
    set done [dict get [probe] done]
    set S($kind) [expr {!$S($kind)}]
    put
    return [wait_for done $done 60000]
}

proc step {} {
    global S
    set ack [dict get [probe] step_ack]
    set S(step) [expr {!$S(step)}]
    put
    wait_for step_ack $ack 2000
}

if {![dict get [probe] locked]} { puts "PLL not locked"; exit 1 }

# ---- 1. phase x capture-delay sweep -------------------------------------------------
puts "Phase sweep: $nsteps steps per clock period; columns = read capture delay 0..3"
array set ok {}
for {set p 0} {$p < $nsteps} {incr p} {
    set line [format "step %2d %4d deg  " $p [expr {360 * $p / $nsteps}]]
    for {set c 0} {$c < 4} {incr c} { set ok($p,$c) 1; set bits($c) 0 }
    foreach {mode seed} [list 2 0 3 [expr {$p + 1}]] {
        op fill $mode 0 0 0 $seed
        for {set c 0} {$c < 4} {incr c} {
            set r [op check $mode 0 $c 0 $seed]
            if {[dict get $r errors]} {
                set ok($p,$c) 0
                set bits($c) [expr {$bits($c) | [dict get $r err_bits]}]
            }
        }
    }
    for {set c 0} {$c < 4} {incr c} {
        append line [expr {$ok($p,$c) ? "  pass      " : [format "  FAIL %04X " $bits($c)]}]
    }
    puts $line
    step
}

# Widest circular run of passing phases for each capture delay.
set best_len 0
for {set c 0} {$c < 4} {incr c} {
    for {set s 0} {$s < $nsteps} {incr s} {
        if {!$ok($s,$c)} continue
        set n 0
        while {$n < $nsteps && $ok([expr {($s + $n) % $nsteps}],$c)} { incr n }
        if {$n > $best_len} { set best_len $n; set best_start $s; set best_cap $c }
    }
}
if {$best_len == 0} { puts "No passing phase at any capture delay."; end_insystem_source_probe; exit 1 }
set centre [expr {($best_start + $best_len / 2) % $nsteps}]
puts [format "Widest window: capture delay %d, steps %d..%d (%d of %d steps = %.0f%% of the period); centre step %d" \
    $best_cap $best_start [expr {($best_start + $best_len - 1) % $nsteps}] $best_len $nsteps \
    [expr {100.0 * $best_len / $nsteps}] $centre]
for {set i 0} {$i < $centre} {incr i} { step }

if {$full ne "full"} { end_insystem_source_probe; exit 0 }

# ---- 2. full suite at the centre ------------------------------------------------------
set names {0 address 1 walking-ones 2 checkerboard 3 random 4 solid}
set total 0
proc report {label r} {
    global total
    set e [dict get $r errors]
    incr total $e
    if {$e} {
        puts [format "  %-28s %d errors, failing bits %04X, first at %06X exp %04X got %04X" $label $e \
            [dict get $r err_bits] [dict get $r err_addr] [dict get $r err_exp] [dict get $r err_got]]
    } else {
        puts [format "  %-28s ok" $label]
    }
}
puts "Full 32 MB tests at step $centre, capture delay $best_cap:"
foreach mode {0 1 2 3 4} {
    foreach inv {0 1} {
        op fill $mode $inv $best_cap 3 [expr {$mode * 2 + $inv}]
        report "[dict get $names $mode][expr {$inv ? " inverted" : ""}]" \
            [op check $mode $inv $best_cap 3 [expr {$mode * 2 + $inv}]]
    }
}
op fill 3 0 $best_cap 3 200
after [expr {$retention * 1000}]
report "retention ${retention}s (random)" [op check 3 0 $best_cap 3 200]
for {set i 1} {$i <= $soak} {incr i} {
    set seed [expr {(37 * $i + 11) & 255}]
    op fill 3 [expr {$i & 1}] $best_cap 3 $seed
    report "soak $i (random seed $seed)" [op check 3 [expr {$i & 1}] $best_cap 3 $seed]
}
puts "TOTAL ERRORS: $total"
end_insystem_source_probe
