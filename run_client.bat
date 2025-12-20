@echo off
title Godot Game Client

:: ============================================
:: Configuration - Edit these paths as needed
:: ============================================
set GODOT_PATH=G:\tools\engines\godot\v4.3\Godot_v4.3-stable_win64.exe
set PROJECT_PATH=%~dp0
set PROJECT_PATH=%PROJECT_PATH:~0,-1%
set SERVER_IP=127.0.0.1
set SERVER_PORT=7777

:: Check if Godot exists
if not exist "%GODOT_PATH%" (
    echo ERROR: Godot not found at %GODOT_PATH%
    echo Please edit this script and set GODOT_PATH to your Godot executable
    pause
    exit /b 1
)

echo ============================================
echo Starting Godot Game Client
echo ============================================
echo Connecting to: %SERVER_IP%:%SERVER_PORT%
echo ============================================
echo.

:: Run client (not headless - shows window)
"%GODOT_PATH%" --path "%PROJECT_PATH%" --client --ip %SERVER_IP% --port %SERVER_PORT%

pause

