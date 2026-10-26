# Pin mapping — EP4CE6F17C8 "C406" board — COMPLETE

Mapped 2026-10-26 with this JTAG pin-finder; SDRAM verified with `../sdram_test`
(full 32 MB fill/check, 0 errors at 50 MHz). Final assignments: `../board/c406_pins.tcl`.

| Signal | Ball | Notes |
|---|---|---|
| CLK_50M | M16 | 50 MHz oscillator, dedicated clock input |
| KEY | R8 | active-low; enable weak pull-up |
| LED | E10 | active-high |
| SDR_CLK, CKE | A14, A15 | |
| SDR_CS_N, RAS_N, CAS_N, WE_N | P15, P16, N14, G15 | |
| SDR_BA0, BA1 | R16, R14 | |
| SDR_LDQM, UDQM | G16, B16 | |
| SDR_A0..A12 | N12 L14 L13 J13 J14 F14 F13 E11 D14 C11 P14 D11 B14 | |
| SDR_DQ0..DQ15 | N16 N15 L15 L16 K15 K16 J15 J16 C15 C16 D15 D16 F16 F15 D12 C14 | DQ12 = F16 = nCEO: set nCEO "Use as regular I/O" |
| (not connected) | M15 | floating clock input |
| (do not drive low) | F5, L12 | held high by something on the board |
| (tied to GND) | E5 F6 F10 G11 J11 K6 K8 K12 L9 L10 L11 M12 | |
| (weakly pulled low, unknown) | D4 F7 F11 J6 J12 K9 K10 K11 L6 M9 N13 | |
| (header pin, reads low) | M11 | on the top header; weakly pulled low |
| (probably unconnected) | B9 E6 E7 F2 F3 G2 G5 K5 L3 L4 L7 L8 N11 | read high with pull-up |

SDRAM timing at 50 MHz, CL=2, SDRAM clock = inverted system clock: sample read data
2 clock edges after the edge that issues READ (window ~36-52 ns).
