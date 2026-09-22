@echo off
REM ============================================================
REM  Lakpue Drug Inc — Chrome Launcher with Local Supabase
REM  Opens Chrome with Mixed Content + Private Network bypass
REM  so http://192.168.0.5:8000 works even from HTTPS pages.
REM ============================================================

setlocal

REM ---- Chrome locations to check (first one found wins) ------
set "CHROME1=C:\Program Files\Google\Chrome\Application\chrome.exe"
set "CHROME2=C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"
set "CHROME3=%LOCALAPPDATA%\Google\Chrome\Application\chrome.exe"

set "CHROME="
if exist "%CHROME1%" set "CHROME=%CHROME1%"
if exist "%CHROME2%" set "CHROME=%CHROME2%"
if exist "%CHROME3%" set "CHROME=%CHROME3%"

if "%CHROME%"=="" (
  echo.
  echo   ERROR: Chrome not found.
  echo   Please check that Google Chrome is installed.
  echo.
  pause
  exit /b 1
)

REM ---- App URL -----------------------------------------------
set "APP_URL=https://ldicorplan68-boop.github.io/LDI-Dashboard/mis.html"

REM ---- Launch Chrome with the bypass flags -------------------
echo.
echo   Launching Chrome with local Supabase bypass...
echo   App: %APP_URL%
echo   Supabase: http://192.168.0.5:8000
echo.

start "" "%CHROME%" ^
  --unsafely-treat-insecure-origin-as-secure="http://192.168.0.5:8000,http://192.168.0.5:3000" ^
  --disable-features=BlockInsecurePrivateNetworkRequests ^
  --user-data-dir="%LOCALAPPDATA%\LakpueChromeProfile" ^
  "%APP_URL%"

endlocal