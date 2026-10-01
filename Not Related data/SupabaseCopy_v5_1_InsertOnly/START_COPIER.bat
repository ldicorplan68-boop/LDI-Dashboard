@echo off
setlocal
cd /d "%~dp0"

set PYTHON=C:\Users\User\AppData\Local\Programs\Python\Python314\python.exe

if not exist "%PYTHON%" (
    echo ERROR: Python was not found:
    echo %PYTHON%
    pause
    exit /b 1
)

echo Checking required Python package...
"%PYTHON%" -m pip install --disable-pip-version-check --quiet paramiko

if errorlevel 1 (
    echo ERROR: Could not install paramiko.
    pause
    exit /b 1
)

echo.
echo Starting Supabase Incremental Copier v5.1 - INSERT ONLY
echo.
"%PYTHON%" "%~dp0supabase_copier_v5_1.py"

endlocal
