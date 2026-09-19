@echo off
setlocal EnableExtensions
if "%~1"=="" (
  echo Usage: run_blackbox.cmd ^<path-to-producer.exe^>
  exit /b 2
)
if not "%~2"=="" (
  echo CLEAN1 launcher accepts exactly one executable path.
  exit /b 5
)
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_blackbox.ps1" "%~1"
exit /b %ERRORLEVEL%
