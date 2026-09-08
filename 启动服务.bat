@echo off
title Salary Timer Network Service
cd /d "%~dp0"
echo ================================================================
echo   Salary Timer - Network Deployment Launcher
echo ================================================================
echo.
echo Starting local web server (port 8765, all interfaces)...
echo Do NOT close this window while the service is running.
echo Press Ctrl+C to stop.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0serve.ps1"
echo.
echo Service has stopped. Press any key to close.
pause >nul
