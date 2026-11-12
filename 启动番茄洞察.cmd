@echo off
start "" powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -STA -File "%~dp0PomoInsight.ps1"
exit /b
