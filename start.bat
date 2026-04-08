@echo off
setlocal EnableDelayedExpansion

:: ╔═══════════════════════════════════════════════════════════╗
:: ║  Agent 4 v2 — Architecture-Aware Deployment Packager     ║
:: ║  Windows startup script — double-click to run            ║
:: ╚═══════════════════════════════════════════════════════════╝

title Agent 4 v2 — Deployment Packager

set BACKEND_PORT=8004
set FRONTEND_PORT=3001
set "SCRIPT_DIR=%~dp0"
cd /d "%SCRIPT_DIR%"

echo.
echo ═══════════════════════════════════════════════════════
echo   Agent 4 v2 — Architecture-Aware Deployment Packager
echo ═══════════════════════════════════════════════════════
echo.

:: ── Check Python ──────────────────────────────────────────────
python --version >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Python not found.
    echo.
    echo   Download from: https://www.python.org/downloads/
    echo   Make sure to check "Add Python to PATH" during install.
    pause
    exit /b 1
)
for /f "tokens=2" %%v in ('python --version 2^>^&1') do (
    echo [OK] Python found: %%v
)

:: ── Check Node.js ─────────────────────────────────────────────
node --version >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Node.js not found.
    echo.
    echo   Download from: https://nodejs.org/
    pause
    exit /b 1
)
for /f %%v in ('node --version 2^>^&1') do (
    echo [OK] Node.js found: %%v
)

:: ── Kill old processes on our ports ───────────────────────────
for %%p in (%BACKEND_PORT% %FRONTEND_PORT%) do (
    for /f "tokens=5" %%pid in ('netstat -ano 2^>nul ^| findstr ":%%p " ^| findstr "LISTENING"') do (
        echo [INFO] Stopping old process on port %%p (PID %%pid)
        taskkill /F /PID %%pid >nul 2>&1
    )
)

:: ── Create directories ─────────────────────────────────────────
if not exist "output"       mkdir output
if not exist "logs"         mkdir logs

:: ── Setup Python venv ─────────────────────────────────────────
if not exist "backend\venv" (
    echo [INFO] Creating Python virtual environment...
    python -m venv backend\venv
    if errorlevel 1 (
        echo [ERROR] Failed to create virtual environment.
        pause
        exit /b 1
    )
    echo [OK] Virtual environment created
)

:: ── Install Python packages ────────────────────────────────────
echo [INFO] Installing Python packages...
call backend\venv\Scripts\activate.bat

pip install fastapi==0.111.0 uvicorn[standard]==0.29.0 jinja2==3.1.4 python-dotenv==1.0.1 pydantic==2.7.1 --quiet 2>logs\pip.log
if errorlevel 1 (
    echo [ERROR] Package installation failed. See logs\pip.log
    type logs\pip.log
    pause
    exit /b 1
)
echo [OK] Core packages installed

pip install pika==1.3.2 --quiet 2>nul && (
    echo [OK] pika installed (RabbitMQ support enabled^)
) || (
    echo [WARN] pika not installed (RabbitMQ disabled^)
)

:: ── Copy .env ─────────────────────────────────────────────────
if not exist "backend\.env" (
    copy backend\.env.example backend\.env >nul
    echo [OK] .env created from .env.example
)

:: ── Install frontend packages ──────────────────────────────────
if not exist "frontend\node_modules" (
    echo [INFO] Installing frontend packages (this takes ~30 seconds^)...
    cd frontend
    npm install --silent 2>>..\logs\npm.log
    if errorlevel 1 (
        echo [ERROR] npm install failed. See logs\npm.log
        cd ..
        pause
        exit /b 1
    )
    cd ..
    echo [OK] Frontend packages installed
)

:: ── Start Backend ──────────────────────────────────────────────
echo.
echo [INFO] Starting Backend on port %BACKEND_PORT%...
start "Agent4-Backend (port %BACKEND_PORT%)" cmd /k ^
    "cd /d backend && call venv\Scripts\activate.bat && ^
     uvicorn main:app --host 0.0.0.0 --port %BACKEND_PORT% --reload ^
     >> ..\logs\backend.log 2>&1 & echo Backend started on port %BACKEND_PORT%"

:: ── Wait for backend health ────────────────────────────────────
echo [INFO] Waiting for backend to be ready...
set READY=0
for /l %%i in (1,1,20) do (
    timeout /t 1 /nobreak >nul
    curl -s "http://localhost:%BACKEND_PORT%/health" >nul 2>&1
    if not errorlevel 1 (
        set READY=1
        goto backend_ready
    )
    echo|set /p="."
)
:backend_ready
echo.

if "%READY%"=="0" (
    echo [ERROR] Backend did not start in 20 seconds.
    echo   Check logs\backend.log for errors.
    pause
    exit /b 1
)
echo [OK] Backend is healthy at http://localhost:%BACKEND_PORT%

:: ── Start Frontend ─────────────────────────────────────────────
echo [INFO] Starting Frontend on port %FRONTEND_PORT%...
start "Agent4-Frontend (port %FRONTEND_PORT%)" cmd /k ^
    "cd /d frontend && npm run dev 2>&1 | tee ..\logs\frontend.log"

timeout /t 4 /nobreak >nul

:: ── Done ───────────────────────────────────────────────────────
echo.
echo ═══════════════════════════════════════════════════════
echo   Agent 4 is RUNNING!
echo.
echo   Frontend:  http://localhost:%FRONTEND_PORT%
echo   Backend:   http://localhost:%BACKEND_PORT%
echo   API Docs:  http://localhost:%BACKEND_PORT%/docs
echo   Logs:      .\logs\backend.log
echo ═══════════════════════════════════════════════════════
echo.
echo   Two windows opened. Close them to stop Agent 4.
echo   Press any key to open the app in your browser...
pause >nul
start http://localhost:%FRONTEND_PORT%

call backend\venv\Scripts\deactivate.bat 2>nul
