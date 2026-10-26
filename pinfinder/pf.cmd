@echo off
rem Shortcut for the pin-finder console: pf program | sample | watch | walk | bisect <label> | drive <pin> 0|1 | release | list
if /i "%~1"=="program" (
    "C:\Altera\quartus\bin64\quartus_pgm.exe" -c "USB-Blaster [USB-0]" -m jtag -o "p;%~dp0pinfinder\output_files\pinfinder.sof"
    exit /b
)
"C:\Altera\quartus\bin64\quartus_stp.exe" -t "%~dp0issp.tcl" %*
