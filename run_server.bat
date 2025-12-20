@echo off
title Godot Headless Server

:: ============================================
:: Configuration - Edit these paths as needed
:: ============================================
set GODOT_PATH=G:\tools\engines\godot\v4.3\Godot_v4.3-stable_win64.exe
set PROJECT_PATH=%~dp0
set PROJECT_PATH=%PROJECT_PATH:~0,-1%
set SERVER_PORT=7777
set MAX_PLAYERS=32

:: Check if Godot exists
if not exist "%GODOT_PATH%" (
    echo ERROR: Godot not found at %GODOT_PATH%
    echo Please edit this script and set GODOT_PATH to your Godot executable
    echo.
    echo Common locations:
    echo   - C:\Program Files\Godot\Godot_v4.3-stable_win64.exe
    echo   - C:\Users\%USERNAME%\Downloads\Godot_v4.3-stable_win64.exe
    echo   - %LOCALAPPDATA%\Godot\Godot_v4.3-stable_win64.exe
    pause
    exit /b 1
)

echo ============================================
echo Starting Godot Headless Server
echo ============================================
echo Project: %PROJECT_PATH%
echo Port: %SERVER_PORT%
echo Max Players: %MAX_PLAYERS%
echo ============================================
echo.

:: Run headless server
"%GODOT_PATH%" --headless --path "%PROJECT_PATH%" --server --port %SERVER_PORT% --max-players %MAX_PLAYERS%

pause

