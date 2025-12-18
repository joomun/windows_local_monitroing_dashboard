@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"

:menu
cls
echo Simple Local Monitor
echo.
echo 1) Start monitoring (background)
echo 2) Stop monitoring (monitor + server)
echo 3) Open HTML view (starts tiny HTTP server and opens browser)
echo 4) Exit
echo.
set /p choice=Choose an option: 

if "%choice%"=="1" goto start
if "%choice%"=="2" goto stop
if "%choice%"=="3" goto view
if "%choice%"=="4" goto end
goto menu

:start
rem check if monitor.ps1 is already running
tasklist /FI "IMAGENAME eq powershell.exe" /V /FO CSV | findstr /I "monitor.ps1" >nul
if %errorlevel%==0 (
  echo Monitor already running.
  pause
  goto menu
)
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0monitor.ps1"
echo Monitoring started (powershell).
pause
goto menu

:stop
rem stop both monitor.ps1 and serve.ps1 if running
for %%S in (monitor.ps1 serve.ps1) do (
  for /f "tokens=2 delims=," %%P in ('tasklist /FI "IMAGENAME eq powershell.exe" /FO CSV /V ^| findstr /I "%%S"') do (
    set "pid=%%~P"
    rem strip quotes
    set "pid=!pid:"=!"
    if defined pid (
      echo Stopping powershell process PID !pid! (%%S)
      taskkill /PID !pid! /F >nul 2>&1
    )
  )
)
echo Stop command sent (if running).
pause
goto menu

:view
if not exist "%~dp0dashboard.html" (
  echo dashboard.html not found. Start monitoring first to generate the dashboard.
  pause
  goto menu
)
rem start tiny HTTP server (serve.ps1) if not already running
tasklist /FI "IMAGENAME eq powershell.exe" /V /FO CSV | findstr /I "serve.ps1" >nul
if %errorlevel% neq 0 (
  start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0serve.ps1"
  timeout /t 1 /nobreak >nul
)
rem open dashboard via http to avoid CORS
start "" "http://127.0.0.1:8000/dashboard.html"
goto menu

:end
endlocal
exit /b 0