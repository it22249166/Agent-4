#!/bin/bash
# ╔══════════════════════════════════════════════════════════════╗
# ║  Agent 4 v2 — Architecture-Aware Deployment Packager        ║
# ║  Mac / Linux startup script                                  ║
# ║  Usage: bash start.sh                                        ║
# ╚══════════════════════════════════════════════════════════════╝

# DO NOT use set -e — we handle errors manually with clear messages

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

BACKEND_PORT=8004
FRONTEND_PORT=3001
BACKEND_DIR="$SCRIPT_DIR/backend"
FRONTEND_DIR="$SCRIPT_DIR/frontend"
VENV_DIR="$BACKEND_DIR/venv"
BACK_PID=""
FRONT_PID=""
SHUTDOWN_DONE=0

# ── Colours ────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

print_ok()   { echo -e "  ${GREEN}✓${NC}  $1"; }
print_fail() { echo -e "  ${RED}✗${NC}  $1"; }
print_info() { echo -e "  ${CYAN}→${NC}  $1"; }
print_warn() { echo -e "  ${YELLOW}!${NC}  $1"; }

pause_if_interactive() {
    if [ -t 0 ]; then
        echo ""
        read -r -p "Press Enter to close... " _
    fi
}

echo ""
echo -e "${BOLD}Agent 4 v2 — Architecture-Aware Deployment Packager${NC}"
echo "══════════════════════════════════════════════════════"

# ── Step 1: Find Python 3 ──────────────────────────────────────
PYTHON_CMD=""
for cmd in python3.12 python3.11 python3.10 python3.9 python3; do
    if command -v "$cmd" &>/dev/null; then
        VER=$("$cmd" --version 2>&1 | grep -o '[0-9]*\.[0-9]*' | head -1)
        MAJOR=$(echo "$VER" | cut -d. -f1)
        MINOR=$(echo "$VER" | cut -d. -f2)
        if [ "$MAJOR" -ge 3 ] && [ "$MINOR" -ge 9 ]; then
            PYTHON_CMD="$cmd"
            print_ok "Python found: $cmd ($VER)"
            break
        fi
    fi
done

if [ -z "$PYTHON_CMD" ]; then
    print_fail "Python 3.9+ not found."
    echo ""
    echo "  Install Python from https://www.python.org/downloads/"
    echo "  macOS: brew install python@3.11"
    pause_if_interactive
    exit 1
fi

# ── Step 2: Find Node.js ───────────────────────────────────────
if ! command -v node &>/dev/null; then
    print_fail "Node.js not found."
    echo ""
    echo "  Install Node.js from https://nodejs.org/"
    echo "  macOS: brew install node"
    pause_if_interactive
    exit 1
fi
print_ok "Node.js found: $(node --version)"

# ── Step 3: Kill any old processes on our ports ────────────────
for port in $BACKEND_PORT $FRONTEND_PORT; do
    pids=$(lsof -ti tcp:$port 2>/dev/null || true)
    if [ -n "$pids" ]; then
        print_info "Port $port busy — stopping old process..."
        echo "$pids" | xargs kill -9 2>/dev/null || true
        sleep 1
    fi
done

# ── Step 4: Create output dir ──────────────────────────────────
mkdir -p "$SCRIPT_DIR/output"
mkdir -p "$SCRIPT_DIR/logs"

# ── Step 5: Setup Python venv ──────────────────────────────────
if [ ! -d "$VENV_DIR" ]; then
    print_info "Creating Python virtual environment..."
    "$PYTHON_CMD" -m venv "$VENV_DIR"
    if [ $? -ne 0 ]; then
        print_fail "Failed to create venv. Try: $PYTHON_CMD -m pip install virtualenv"
        pause_if_interactive
        exit 1
    fi
    print_ok "Virtual environment created"
fi

# ── Step 6: Install/upgrade Python packages ────────────────────
print_info "Installing Python packages..."

# Activate venv
source "$VENV_DIR/bin/activate"

# Upgrade pip silently
"$VENV_DIR/bin/pip" install --quiet --upgrade pip 2>/dev/null

# Install packages — continue even if pika fails (RabbitMQ optional)
"$VENV_DIR/bin/pip" install \
    "fastapi==0.111.0" \
    "uvicorn[standard]==0.29.0" \
    "jinja2==3.1.4" \
    "python-dotenv==1.0.1" \
    "pydantic==2.11.3" \
    --quiet 2>&1

if [ $? -ne 0 ]; then
    print_fail "Failed to install required packages."
    echo "  Try manually: cd backend && source venv/bin/activate && pip install fastapi uvicorn jinja2 python-dotenv pydantic"
    pause_if_interactive
    exit 1
fi
print_ok "Core packages installed (fastapi, uvicorn, jinja2, pydantic)"

# Try pika separately — optional
"$VENV_DIR/bin/pip" install "pika==1.3.2" --quiet 2>/dev/null \
    && print_ok "pika installed (RabbitMQ support enabled)" \
    || print_warn "pika not installed (RabbitMQ disabled — use POST /package directly)"

deactivate

# ── Step 7: Copy .env if missing ──────────────────────────────
if [ ! -f "$BACKEND_DIR/.env" ]; then
    cp "$BACKEND_DIR/.env.example" "$BACKEND_DIR/.env"
    print_ok ".env created from .env.example"
fi

# ── Step 8: Install frontend packages ─────────────────────────
NEXT_BIN="$FRONTEND_DIR/node_modules/.bin/next"
if [ ! -d "$FRONTEND_DIR/node_modules" ] || [ ! -x "$NEXT_BIN" ]; then
    print_info "Installing frontend Node.js packages (this takes ~30s)..."
    cd "$FRONTEND_DIR"
    npm install --silent 2>/dev/null
    if [ $? -ne 0 ]; then
        print_fail "npm install failed."
        echo "  Try manually: cd frontend && npm install"
        pause_if_interactive
        exit 1
    fi

    if [ ! -x "$NEXT_BIN" ]; then
        print_fail "Frontend dependency check failed: next binary not found after install."
        echo "  Try manually: cd frontend && rm -rf node_modules package-lock.json && npm install"
        pause_if_interactive
        exit 1
    fi

    cd "$SCRIPT_DIR"
    print_ok "Frontend packages installed"
fi

# ── Step 9: Start backend ──────────────────────────────────────
print_info "Starting Backend on port $BACKEND_PORT..."
cd "$BACKEND_DIR"
source "$VENV_DIR/bin/activate"
"$VENV_DIR/bin/uvicorn" main:app \
    --host 0.0.0.0 \
    --port $BACKEND_PORT \
    --reload \
    --log-level info \
    > "$SCRIPT_DIR/logs/backend.log" 2>&1 &
BACK_PID=$!
deactivate
cd "$SCRIPT_DIR"

# ── Step 10: Wait for backend to be healthy ────────────────────
print_info "Waiting for backend to be ready..."
READY=0
for i in $(seq 1 20); do
    sleep 1
    if curl -s "http://localhost:$BACKEND_PORT/health" > /dev/null 2>&1; then
        READY=1
        break
    fi
    echo -n "."
done
echo ""

if [ $READY -eq 0 ]; then
    print_fail "Backend did not start in 20 seconds."
    echo ""
    echo "  Check the log: cat logs/backend.log"
    echo "  Last 20 lines:"
    tail -20 "$SCRIPT_DIR/logs/backend.log" 2>/dev/null || echo "  (no log found)"
    kill $BACK_PID 2>/dev/null
    pause_if_interactive
    exit 1
fi
print_ok "Backend is healthy at http://localhost:$BACKEND_PORT"

# ── Step 11: Start frontend ────────────────────────────────────
print_info "Starting Frontend on port $FRONTEND_PORT..."
cd "$FRONTEND_DIR"
npm run dev > "$SCRIPT_DIR/logs/frontend.log" 2>&1 &
FRONT_PID=$!
cd "$SCRIPT_DIR"

sleep 3

# ── Done ───────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}Agent 4 is running!${NC}"
echo "══════════════════════════════════════════════════════"
echo -e "  ${CYAN}Frontend:${NC}  http://localhost:$FRONTEND_PORT"
echo -e "  ${CYAN}Backend:${NC}   http://localhost:$BACKEND_PORT"
echo -e "  ${CYAN}API Docs:${NC}  http://localhost:$BACKEND_PORT/docs"
echo -e "  ${CYAN}Logs:${NC}      ./logs/backend.log  ./logs/frontend.log"
echo ""
echo "  Press Ctrl+C to stop all services."
echo "══════════════════════════════════════════════════════"

# ── Cleanup on Ctrl+C / terminal close ────────────────────────
cleanup() {
    if [ "$SHUTDOWN_DONE" -eq 1 ]; then
        return
    fi
    SHUTDOWN_DONE=1

    echo ""
    echo "Stopping Agent 4..."

    if [ -n "$BACK_PID" ]; then
        kill "$BACK_PID" 2>/dev/null || true
    fi
    if [ -n "$FRONT_PID" ]; then
        kill "$FRONT_PID" 2>/dev/null || true
    fi

    # Kill any remaining processes on our ports.
    lsof -ti tcp:"$BACKEND_PORT" 2>/dev/null | xargs kill -9 2>/dev/null || true
    lsof -ti tcp:"$FRONTEND_PORT" 2>/dev/null | xargs kill -9 2>/dev/null || true

    echo "Stopped."
}

on_interrupt() {
    cleanup
    exit 0
}

trap cleanup EXIT HUP
trap on_interrupt INT TERM

wait $BACK_PID $FRONT_PID
WAIT_STATUS=$?

if [ $WAIT_STATUS -ne 0 ]; then
    print_fail "A service stopped unexpectedly. Check logs/backend.log and logs/frontend.log"
else
    print_warn "Services stopped."
fi

pause_if_interactive
exit $WAIT_STATUS
