@echo off
title Ember build
cd /d "%~dp0"
set "PATH=C:\dev\flutter\bin;%PATH%"
taskkill /im ember.exe /f >nul 2>&1
echo Building Ember (release)...
call flutter build windows --release
if errorlevel 1 (
  echo.
  echo Build failed. See the messages above.
  pause
  exit /b 1
)
start "" "%~dp0build\windows\x64\runner\Release\ember.exe"
exit /b 0
