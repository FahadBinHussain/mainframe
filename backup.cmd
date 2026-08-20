@echo off
powershell -NoProfile -Command "if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { Start-Process -FilePath '%~f0' -Verb RunAs -WorkingDirectory '%~dp0'; exit 1 }"
if errorlevel 1 exit /b
powershell -NoProfile -Command "try { $b = $Host.UI.RawUI.BufferSize; $b.Height = 9999; $Host.UI.RawUI.BufferSize = $b } catch {}"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0backup.ps1"
echo.
pause
