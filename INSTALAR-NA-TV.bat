@echo off
chcp 65001 >nul
echo ========================================================
echo   FRANK KARAOKE TV - BUILD E INSTALACAO SAMSUNG TIZEN
echo ========================================================
echo.
set TV_IP=192.168.1.3
if not "%~1"=="" set TV_IP=%~1
node "%~dp0tizen-tv\build-tizen.js" --tv %TV_IP%
echo.
pause
