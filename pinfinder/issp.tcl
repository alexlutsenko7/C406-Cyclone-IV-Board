# Pin-finder console, used after pinfinder.sof is programmed:
#   quartus_stp -t issp.tcl <command> [args]
#
#   sample [n]        read all candidates n times (default 200); report toggling
#                     pins (clock) and pins held low; both go to exclude.txt
#   watch [seconds]   print every pin change (default 30 s) - press the button
#   walk [ms]         blink each candidate pin in turn, printing its name - watch the LED
#   bisect [label]    find the ball wired to whatever you probe (meter, LED) by y/n questions;
#                     each round drives every free pin to one bit of its index
#   dq <n>            bisect for SDR_DQ<n> among the data-bus pins (SDRAM must be quiet)
#   among <label> <pin>...  bisect restricted to the listed pins
#   check <pin> [label]  test whether the probe follows one pin; records it under label if so
#   drive <pin> 0|1   hold a pin at a level (persists until released)
#   release [pin]     stop driving one pin, or all pins
#   list              show candidates, held and excluded pins

package require ::quartus::insystem_source_probe

set here [file dirname [file normalize [info script]]]
cd $here
set args $quartus(args)
set cmd [lindex $args 0]

# --- candidate table ---------------------------------------------------------
set io {}
set all {}
set fh [open candidates.txt r]
while {[gets $fh line] >= 0} {
    if {[string match #* $line] || [llength $line] < 3} continue
    lassign $line b p kind
    lappend all $p
    if {$kind eq "io"} { lappend io $p }
}
close $fh
set N [llength $io]
set W [llength $all]

proc load_list {path} {
    if {![file exists $path]} { return {} }
    set fh [open $path r]
    set v [string trim [read $fh]]
    close $fh
    return $v
}

proc save_list {path v} {
    set fh [open $path w]
    puts $fh $v
    close $fh
}

set holds [load_list holds.txt]      ;# dict pin -> 0|1
set excluded [load_list exclude.txt]
set fighting [load_list fighting.txt]  ;# pins seen driven by another chip
set found {}                           ;# pins already identified (found.txt)
foreach {label p note} [load_list found.txt] { lappend found $p }

# --- JTAG access -------------------------------------------------------------
proc open_issp {} {
    global inst hw dev
    set names [get_hardware_names]
    if {[llength $names] == 0} { puts stderr "No JTAG cable found"; exit 1 }
    set hw [lindex $names 0]
    foreach h $names { if {[string match *USB-Blaster* $h]} { set hw $h; break } }
    set dev [lindex [get_device_names -hardware_name $hw] 0]
    set inst 0
    foreach info [get_insystem_source_probe_instance_info -hardware_name $hw -device_name $dev] {
        if {[lindex $info 3] eq "PF"} { set inst [lindex $info 0] }
    }
    start_insystem_source_probe -hardware_name $hw -device_name $dev
}

# Runs one source/probe call; if the JTAG session dropped (it shows up as an
# "internal Tcl interpreter error"), reconnects and retries once.
proc jtag {args} {
    global hw dev
    if {![catch {{*}$args} r]} { return $r }
    puts stderr "JTAG access failed ($r) - reconnecting"
    catch end_insystem_source_probe
    after 500
    start_insystem_source_probe -hardware_name $hw -device_name $dev
    return [{*}$args]
}

# Returns the pin levels as a list indexed by probe bit.
proc probe {} {
    global inst W
    set s [jtag read_probe_data -instance_index $inst]
    set out {}
    for {set i 0} {$i < $W} {incr i} { lappend out [string index $s end-$i] }
    return $out
}

# Drives the pins in dict $drive (plus held pins); every other pin is released.
proc apply {{drive {}}} {
    global inst N io holds
    set drive [dict merge $drive $holds]
    set s ""
    foreach part {val oe} {
        for {set i [expr {$N-1}]} {$i >= 0} {incr i -1} {
            set p [lindex $io $i]
            if {![dict exists $drive $p]} {
                append s 0
            } elseif {$part eq "oe"} {
                append s 1
            } else {
                append s [dict get $drive $p]
            }
        }
    }
    jtag write_source_data -instance_index $inst -value $s
    if {[jtag read_source_data -instance_index $inst] ne $s} {
        puts stderr "ERROR: the JTAG write did not take effect - close other JTAG tools and run again."
        end_insystem_source_probe
        exit 1
    }

    # A driven pin that is not at its level is fought by a stronger driver - in
    # practice the SDRAM's data outputs. Stop driving it and keep it out of later
    # patterns; SDRAM inputs (CS#, address, ...) never fight, so no target is lost.
    set levels [probe]
    set bad {}
    dict for {p v} $drive {
        if {[lindex $levels [lsearch -exact $io $p]] ne $v} { lappend bad $p }
    }
    if {[llength $bad]} {
        global fighting
        puts "Driven by something else (likely SDRAM DQ), released: $bad"
        lappend fighting {*}$bad
        save_list fighting.txt [lsort -unique $fighting]
        set holds [dict remove $holds {*}$bad]
        apply [dict remove $drive {*}$bad]
    }
}

proc require_io {p} {
    global io
    if {[lsearch -exact $io $p] < 0} { puts stderr "$p is not a drivable candidate pin"; exit 1 }
}

proc ask {q} {
    while 1 {
        puts -nonewline "$q \[y/n\] "
        flush stdout
        set a [string tolower [string trim [gets stdin]]]
        if {$a eq "y" || $a eq "n"} { return $a }
    }
}

proc free_pins {} {
    global io excluded holds fighting found
    set out {}
    foreach p $io {
        if {[lsearch -exact $excluded $p] < 0 && [lsearch -exact $fighting $p] < 0
            && [lsearch -exact $found $p] < 0 && ![dict exists $holds $p]} { lappend out $p }
    }
    return $out
}

proc pattern {pins v} {
    set d {}
    foreach p $pins { dict set d $p $v }
    return $d
}

# --- commands ----------------------------------------------------------------
# "dq <n>" is a bisect for SDR_DQ<n> among the pins once seen fighting (the SDRAM
# data bus). Only safe while the SDRAM is quiet, i.e. CS# held high since power-up.
if {$cmd eq "dq"} {
    set pool {}
    foreach p $fighting { if {[lsearch -exact $found $p] < 0} { lappend pool $p } }
    set args [list bisect SDR_DQ[lindex $args 1]]
    set cmd bisect
}
# "among <label> <pin>..." is a bisect restricted to the listed pins.
if {$cmd eq "among"} {
    set pool [string toupper [lrange $args 2 end]]
    set args [list bisect [lindex $args 1]]
    set cmd bisect
}

open_issp

switch -- $cmd {
    sample {
        set n [expr {[llength $args] > 1 ? [lindex $args 1] : 200}]
        set ones [lrepeat $W 0]
        for {set k 0} {$k < $n} {incr k} {
            set i 0
            foreach v [probe] { lset ones $i [expr {[lindex $ones $i] + $v}]; incr i }
        }
        set toggling {}
        set low {}
        set i 0
        foreach p $all {
            set c [lindex $ones $i]
            if {$c > 0 && $c < $n} {
                lappend toggling $p
                puts [format "TOGGLING  %-4s high %3d%% of reads  <- clock?" $p [expr {100 * $c / $n}]]
            } elseif {$c == 0 && ![dict exists $holds $p]} {
                lappend low $p
            }
            incr i
        }
        puts "Held low (driven by something, or pulled down): $low"
        puts "All other undriven candidates read high (weak pull-up)."
        set excluded [lsort -unique [concat $excluded $toggling $low]]
        save_list exclude.txt $excluded
        puts "Excluded from walk/bisect: $excluded"
    }
    watch {
        set secs [expr {[llength $args] > 1 ? [lindex $args 1] : 30}]
        set end [expr {[clock seconds] + $secs}]
        puts "Watching for $secs s - press the button now."
        set prev [probe]
        while {[clock seconds] < $end} {
            set cur [probe]
            foreach p $all a $prev b $cur {
                if {$a ne $b && [lsearch -exact $excluded $p] < 0} {
                    puts "[clock format [clock seconds] -format %T]  $p: $a -> $b"
                }
            }
            set prev $cur
            after 20
        }
    }
    walk {
        set ms [expr {[llength $args] > 1 ? [lindex $args 1] : 1500}]
        set half [expr {$ms / 6}]
        foreach p [free_pins] {
            puts -nonewline "$p ... "
            flush stdout
            for {set k 0} {$k < 3} {incr k} {
                apply [dict create $p 0]
                after $half
                apply [dict create $p 1]
                after $half
            }
            apply
            puts ""
        }
    }
    bisect {
        set label [expr {[llength $args] > 1 ? [lindex $args 1] : "target"}]
        set S [expr {[info exists pool] ? $pool : [free_pins]}]
        puts "Probing $label among [llength $S] pins. Answer for your meter (HIGH?) or LED (ON?)."
        apply [pattern $S 1]
        set r1 [ask "All candidates driven 1: is it HIGH / ON?"]
        apply [pattern $S 0]
        set r0 [ask "All candidates driven 0: is it HIGH / ON?"]
        if {$r1 eq $r0} {
            puts "$label does not follow any free candidate pin (header pin, excluded, held, or bad contact)."
            apply
            end_insystem_source_probe
            exit 1
        }
        # Each round drives every free pin to one bit of its index, so the answers
        # spell out the index. No pin is ever released mid-search: a released pin
        # floats HIGH through its pull-up and would mislead every later answer.
        set n [llength $S]
        set idx 0
        for {set k 0} {(1 << $k) < $n} {incr k} {
            set d {}
            set i 0
            foreach p $S { dict set d $p [expr {($i >> $k) & 1}]; incr i }
            apply $d
            if {[ask "Round [expr {$k+1}]: is it HIGH / ON?"] eq $r1} { set idx [expr {$idx | (1 << $k)}] }
        }
        if {$idx >= $n} {
            puts "Inconsistent answers (index $idx of $n) - check the probe contact and run again."
            apply
            end_insystem_source_probe
            exit 1
        }
        set p [lindex $S $idx]
        set others [lsearch -all -inline -exact -not $S $p]
        apply [dict merge [pattern $others 0] [dict create $p 1]]
        set v1 [ask "Only $p driven 1, all others 0: is it HIGH / ON?"]
        apply [dict merge [pattern $others 1] [dict create $p 0]]
        set v0 [ask "Only $p driven 0, all others 1: is it HIGH / ON?"]
        apply
        if {$v1 eq $r1 && $v0 eq $r0} {
            set note [expr {$r1 eq "y" ? "active-high" : "active-low"}]
            puts "FOUND: $label = $p ($note)"
            set fh [open found.txt a]
            puts $fh "$label $p $note"
            close $fh
        } else {
            puts "Verification failed for $p - check the probe contact and run again."
        }
    }
    read {
        set levels [probe]
        foreach p [lrange $args 1 end] {
            set p [string toupper $p]
            puts "$p = [lindex $levels [lsearch -exact $all $p]]"
        }
    }
    check {
        lassign $args - p label
        set p [string toupper $p]
        require_io $p
        set others [lsearch -all -inline -exact -not [free_pins] $p]
        apply [dict merge [pattern $others 0] [dict create $p 1]]
        set v1 [ask "$p driven 1, all others 0: is it HIGH / ON?"]
        apply [dict merge [pattern $others 1] [dict create $p 0]]
        set v0 [ask "$p driven 0, all others 1: is it HIGH / ON?"]
        apply
        if {$v1 eq "y" && $v0 eq "n"} {
            puts "MATCH: the probe follows $p"
            if {$label ne ""} {
                set fh [open found.txt a]
                puts $fh "$label $p active-high"
                close $fh
            }
        } else {
            puts "No match for $p"
        }
    }
    drive {
        lassign $args - p v
        set p [string toupper $p]
        require_io $p
        if {$v ne "0" && $v ne "1"} { puts stderr "Level must be 0 or 1"; exit 1 }
        dict set holds $p $v
        save_list holds.txt $holds
        apply
        puts "Holding: $holds"
    }
    release {
        if {[llength $args] > 1} {
            set holds [dict remove $holds [string toupper [lindex $args 1]]]
        } else {
            set holds {}
        }
        save_list holds.txt $holds
        apply
        puts "Holding: $holds"
    }
    list {
        puts "Candidates ($W): $all"
        puts "Held: $holds"
        puts "Excluded: $excluded"
    }
    default {
        puts "Commands: sample \[n\] | watch \[s\] | walk \[ms\] | bisect \[label\] | check <pin> \[label\] | drive <pin> 0|1 | release \[pin\] | list"
    }
}

end_insystem_source_probe
