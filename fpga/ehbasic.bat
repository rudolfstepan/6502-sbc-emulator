@echo off
@REM This batch file is used to upload the EHBasic monitor ROM to an FPGA board and run it immediately after uploading.
python "%~dp0tools\upload_monitor_hex_enter.py" "%~dp0roms\fpga_ehbasic_16kb.rom" --port COM15 --address 0xC000 --run --send-enter-after-run
