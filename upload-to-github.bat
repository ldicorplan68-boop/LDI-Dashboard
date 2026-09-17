@echo off
title Upload to GitHub
cd /d "C:\Users\User\Desktop\Sales"

echo ========================================
echo       UPLOADING FILES TO GITHUB
echo ========================================
echo.

echo Adding all files...
git add -A

echo.
echo Creating commit...
git commit -m "Update files"

echo.
echo Pushing to GitHub...
git push origin main

echo.
if %errorlevel%==0 (
    echo ========================================
    echo       UPLOAD SUCCESSFUL!
    echo ========================================
) else (
    echo ========================================
    echo         UPLOAD FAILED!
    echo ========================================
)

echo.
pause