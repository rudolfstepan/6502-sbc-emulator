@echo off
setlocal
pushd "%~dp0" || exit /b 1

if not exist "bin\sbc6502.exe" (
    echo sbc6502.exe is missing. Run make in the project directory.
    popd
    pause
    exit /b 1
)

if not exist "c64.ini" (
    echo c64.ini is missing from the project directory.
    popd
    pause
    exit /b 1
)

".\bin\sbc6502.exe" c64.ini %* 2>&1
set "result=%errorlevel%"
popd
if not "%result%"=="0" pause
exit /b %result%
