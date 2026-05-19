@echo off
setlocal

set ACTION=%~1
if "%ACTION%"=="" set ACTION=doctor

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0sub2api-ops.ps1" -Action "%ACTION%"
exit /b %ERRORLEVEL%
