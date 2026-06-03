@echo off
setlocal

cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "tools\publish_wiki.ps1" -Push

if errorlevel 1 (
    echo.
    echo Wiki update failed.
    exit /b %errorlevel%
)

echo.
echo Wiki update completed.
