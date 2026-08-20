@echo off
powershell -NoProfile -Command "if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { Start-Process -FilePath '%~f0' -Verb RunAs -WorkingDirectory '%~dp0'; exit 1 }"
if errorlevel 1 exit /b
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0wipe.ps1"
echo.
pause
