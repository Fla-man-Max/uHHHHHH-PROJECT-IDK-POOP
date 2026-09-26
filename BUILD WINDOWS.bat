@echo off
setlocal
cd /d "%~dp0"
where haxelib >nul 2>nul
if errorlevel 1 (
    echo Haxe and Haxelib must be installed and available in PATH.
    pause
    exit /b 1
)
set "HXCPP_COMPILE_THREADS=8"
haxelib run lime build windows -64 -release
if errorlevel 1 (
    echo Windows build failed. See the error above.
    pause
    exit /b 1
)
echo Windows release: export\release\windows\bin\Funkin.exe
pause
