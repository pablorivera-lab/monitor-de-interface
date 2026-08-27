@echo off
chcp 65001 >nul
title Servidor Web Monitor de Red

net session >nul 2>&1
if %errorLevel% neq 0 (
    echo [!] Ejecuta este script como Administrador para habilitar el servidor web.
    pause
    exit /b
)

echo ===================================================
echo     INICIANDO MONITOR DE RED WEB
echo ===================================================
echo.

set /p USER_PORT="Ingrese el puerto a utilizar [Presiona ENTER para 8080]: "
if "%USER_PORT%"=="" set USER_PORT=8080
set TARGET_PORT=%USER_PORT%

echo.
echo [*] Limpiando procesos previos en el puerto %TARGET_PORT%...
for /f "tokens=5" %%a in ('netstat -aon ^| findstr /r /c:":%TARGET_PORT% *LISTENING"') do (
    taskkill /F /PID %%a >nul 2>&1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1"
pause
exit /b