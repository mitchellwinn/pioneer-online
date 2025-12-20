@echo off
title Local Multiplayer Test

:: ============================================
:: Starts 1 headless server + 2 clients for local testing
:: ============================================
set GODOT_PATH=G:\tools\engines\godot\v4.3\Godot_v4.3-stable_win64.exe
set PROJECT_PATH=%~dp0
set PROJECT_PATH=%PROJECT_PATH:~0,-1%
set SERVER_PORT=7777

:: Check if Godot exists
if not exist "%GODOT_PATH%" (
    echo ERROR: Godot not found at %GODOT_PATH%
    echo Please edit this script and set GODOT_PATH to your Godot executable
    pause
    exit /b 1
)

echo ============================================
echo Starting Local Multiplayer Test
echo ============================================
echo This will launch:
echo   - 1 Headless Server
echo   - 2 Game Clients
echo ============================================
echo.

:: Start server in background
echo Starting server...
start "Server" /min "%GODOT_PATH%" --headless --path "%PROJECT_PATH%" --server --port %SERVER_PORT%

:: Wait for server to initialize
timeout /t 2 /nobreak > nul

:: Start clients (they will show title menu)
:: Using smaller windows side by side on primary monitor
echo Starting client 1...
start "Client 1" "%GODOT_PATH%" --path "%PROJECT_PATH%" --resolution 800x600 --position 50,100

timeout /t 1 /nobreak > nul

echo Starting client 2...
start "Client 2" "%GODOT_PATH%" --path "%PROJECT_PATH%" --resolution 800x600 --position 900,100

echo.
echo All instances started!
echo Close this window to continue (servers/clients will keep running)
pause

