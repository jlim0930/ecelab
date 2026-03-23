#!/usr/bin/env bash
# ==============================================================================
# ECE Lab — Web UI Launcher
# ==============================================================================
# Starts the ECE Lab web interface and opens it in the default browser.
#
# Usage:
#   ./web.sh          # Start on default port 3000
#   ./web.sh 8080     # Start on custom port
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEB_DIR="${SCRIPT_DIR}/web"
PORT="${1:-3000}"

# --- Colors ------------------------------------------------------------------
if [[ -t 1 ]] && command -v tput &>/dev/null && tput colors &>/dev/null; then
  GREEN="$(tput setaf 2)"; BLUE="$(tput setaf 14)"; RED="$(tput setaf 1)"
  YELLOW="$(tput setaf 3)"; RESET="$(tput sgr0)"
else
  GREEN="" BLUE="" RED="" YELLOW="" RESET=""
fi

log_info()  { echo "${GREEN}[INFO]${RESET}  $*"; }
log_error() { echo "${RED}[ERROR]${RESET} $*" >&2; }
log_warn()  { echo "${YELLOW}[WARN]${RESET}  $*"; }

# --- Check Node.js -----------------------------------------------------------
if ! command -v node &>/dev/null; then
  log_error "Node.js is required but not installed."
  echo ""
  echo "  Install via:"
  echo "    macOS:   ${BLUE}brew install node${RESET}"
  echo "    Ubuntu:  ${BLUE}curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - && sudo apt-get install -y nodejs${RESET}"
  echo "    WSL:     ${BLUE}curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - && sudo apt-get install -y nodejs${RESET}"
  echo ""
  exit 1
fi

NODE_VERSION="$(node -v | sed 's/v//' | cut -d. -f1)"
if [[ "$NODE_VERSION" -lt 18 ]]; then
  log_error "Node.js 18+ is required. Found: $(node -v)"
  exit 1
fi

# --- Install dependencies if needed ------------------------------------------
if [[ ! -d "${WEB_DIR}/node_modules" ]]; then
  log_info "Installing dependencies (first run only)..."
  cd "$WEB_DIR" && npm install --silent 2>&1 | tail -1
  cd "$SCRIPT_DIR"
fi

# --- Check if port is in use -------------------------------------------------
if command -v lsof &>/dev/null && lsof -i ":${PORT}" &>/dev/null; then
  log_warn "Port ${PORT} is already in use."
  # Try to find an open port
  for p in 3001 3002 3003 8080 8081; do
    if ! lsof -i ":${p}" &>/dev/null 2>&1; then
      PORT="$p"
      log_info "Using port ${BLUE}${PORT}${RESET} instead."
      break
    fi
  done
fi

# --- Open browser (platform-aware) -------------------------------------------
open_browser() {
  local url="http://localhost:${PORT}"
  case "$(uname -s)" in
    Darwin*)
      open "$url" 2>/dev/null || true
      ;;
    Linux*)
      if grep -qi microsoft /proc/version 2>/dev/null; then
        # WSL — use Windows browser
        cmd.exe /c start "$url" 2>/dev/null \
          || powershell.exe -Command "Start-Process '$url'" 2>/dev/null \
          || true
      else
        xdg-open "$url" 2>/dev/null \
          || sensible-browser "$url" 2>/dev/null \
          || true
      fi
      ;;
  esac
}

# --- Cleanup on exit ----------------------------------------------------------
cleanup() {
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

# --- Start the server ---------------------------------------------------------
log_info "Starting ECE Lab UI on ${BLUE}http://localhost:${PORT}${RESET}"
echo ""

cd "$WEB_DIR"
npx next dev -p "$PORT" &
SERVER_PID=$!

# Wait a moment for the server to start, then open the browser
sleep 3
open_browser

log_info "ECE Lab UI is running. Press ${BLUE}Ctrl+C${RESET} to stop."
echo ""

# Wait for the server process
wait "$SERVER_PID"
