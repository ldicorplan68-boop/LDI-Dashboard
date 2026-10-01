@echo off
title Replace GitHub with Local Files
cd /d "C:\Users\User\Desktop\Sales"

echo ========================================
echo    REPLACING GITHUB WITH LOCAL FILES
echo ========================================
echo.

echo Adding all files...
git add -A

echo.
echo Creating commit...
git commit -m "Replace GitHub with latest local files"

echo.
echo Pushing to GitHub and replacing remote...
git push origin main --force

echo.
if %errorlevel%==0 (
    echo ========================================
    echo       UPLOAD SUCCESSFUL!
    echo ========================================
    echo.
    echo GitHub has been replaced with
    echo the current files in:
    echo C:\Users\User\Desktop\Sales
) else (
    echo ========================================
    echo         UPLOAD FAILED!
    echo ========================================
)

echo.
pause