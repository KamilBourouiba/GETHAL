#!/usr/bin/env bash
#--------------------------------------------------------------------
# Local-LLM-SaaS zero‑cost installer  •  v2025‑06‑25‑c
#--------------------------------------------------------------------
#  Tested on:
#   • Ubuntu 22.04 / Fedora 40
#   • macOS 14 (Intel & Apple‑Silicon)
#   • Windows 10/11 (Git‑Bash or WSL2 + Docker Desktop)
#--------------------------------------------------------------------
set -euo pipefail

APP_NAME="Local LLM Chat"
MODEL="llama3:8b"                 # default Ollama model
NATIVE_PORT_UI=3000
INTERNAL_PORT_UI=8080             # Open WebUI default
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"

#───────────────────────── helpers ─────────────────────────
need() { command -v "$1" >/dev/null 2>&1; }
log()  { printf "\e[1;34m▶ %s\e[0m\n" "$*"; }
err()  { printf "\e[31m❌ %s\e[0m\n" "$*" >&2; exit 1; }

#───────────────────────── arg‑parse ───────────────────────
SKIP_DOCKER_CHECK=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-docker-check) SKIP_DOCKER_CHECK=1 ; shift ;;
    -m|--model)          MODEL="$2" ; shift 2 ;;
    -h|--help)
      cat <<EOF
Usage: install.sh [options]
  -m, --model <tag>          Ollama model tag to pre‑pull (default: $MODEL)
      --skip-docker-check    Assume Docker & Compose are already installed
  -h, --help                 Show this help
EOF
      exit 0 ;;
    *) err "Unknown option $1" ;;
  esac
done

#──────────────────── Dynamic Docker detection ────────────

DOCKER_OK=0
if need docker; then
  if docker system info &>/dev/null; then
    DOCKER_OK=1               # CLI & daemon good
  else
    # macOS: if CLI present, prefer launching existing Docker Desktop instead of reinstalling via brew
    if [[ "$OS" == darwin* && -d "/Applications/Docker.app" ]]; then
      log "Docker CLI found but daemon not running — starting Docker Desktop…"
      open -g -a Docker || true
      SECS=0
      until docker system info &>/dev/null || [[ $SECS -gt 60 ]]; do sleep 2; SECS=$((SECS+2)); done
      if docker system info &>/dev/null; then
        DOCKER_OK=1
      else
        err "Docker Desktop didn't start within 60 s. Please open it manually, then re‑run with --skip-docker-check"
      fi
    elif [[ "$OS" == linux* ]]; then
      sudo systemctl start docker || true
      sleep 3
      docker system info &>/dev/null && DOCKER_OK=1
    fi
  fi
fi

if [[ $SKIP_DOCKER_CHECK -eq 1 ]]; then
  log "--skip-docker-check active — skipping Docker validation."
  DOCKER_OK=1
fi

#──────────────────── Docker install (only if CLI missing) ─
remove_stale_docker_links() {
  # Remove any symlink or binary that can break brew cask.
  for l in /usr/local/bin/docker* /usr/local/bin/kubectl.docker /usr/local/bin/compose*; do
    [[ -e "$l" || -L "$l" ]] && sudo rm -f "$l" 2>/dev/null || true
  done
}

install_docker() {
  log "Installing Docker Engine + Compose (no CLI detected)…"
  if [[ "$OS" == linux* ]]; then
    if need apt-get; then
      sudo apt-get update
      sudo apt-get install -y ca-certificates curl gnupg lsb-release
      sudo mkdir -p /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/$(. /etc/os-release; echo "$ID")/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(. /etc/os-release; echo "$ID") $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
      sudo apt-get update && sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    elif need dnf; then
      sudo dnf install -y dnf-plugins-core
      sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
      sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    else
      err "Unsupported Linux distro — install Docker manually."
    fi
    sudo systemctl enable --now docker
    sudo usermod -aG docker "$USER" || true
  elif [[ "$OS" == darwin* ]]; then
    if ! need brew; then
      log "Installing Homebrew…"
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      eval "$($(brew --prefix)/bin/brew shellenv)"
    fi

    remove_stale_docker_links
    brew install --cask docker-desktop
    open -g -a Docker || true
    log "Waiting for Docker Desktop to start (max 60 s)…"
    SECS=0
    until docker system info &>/dev/null || [[ $SECS -gt 60 ]]; do sleep 3; SECS=$((SECS+3)); done
    [[ $SECS -gt 60 ]] && err "Docker failed to start after installation."
  else
    err "Unsupported OS for automatic Docker install."
  fi
}

if [[ $DOCKER_OK -eq 0 ]]; then
  install_docker
else
  log "Docker daemon is running — installation skipped."
fi

#──────────────────── Generate docker-compose.yml ─────────
cat > docker-compose.yml <<YAML
version: "3.9"
services:
  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    restart: unless-stopped
    ports:
      - "11434:11434"
    volumes:
      - ollama:/root/.ollama
  webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: open-webui
    restart: unless-stopped
    environment:
      - OLLAMA_BASE_URL=http://ollama:11434
    ports:
      - "${NATIVE_PORT_UI}:${INTERNAL_PORT_UI}"
    depends_on:
      - ollama
  chroma:
    image: ghcr.io/chroma-core/chroma:latest
    container_name: chromadb
    restart: unless-stopped
    ports:
      - "8001:8000"
volumes:
  ollama:
YAML

#──────────────────── Boot the stack ─────────────────────
log "Booting local‑LLM stack (first run pulls ≈8 GB)…"
docker compose pull --quiet
docker compose up -d

#──────────────────── Wait for WebUI health ───────────────
printf "⌛ Waiting for WebUI "; until curl -fs http://localhost:${NATIVE_PORT_UI}/health &>/dev/null; do printf "."; sleep 2; done; echo " ready."

#──────────────────── Electron desktop wrapper ───────────
build_app() {
  log "Bundling Electron desktop app…"
  if ! need node || [[ $(node -v | cut -d. -f1 | tr -d v) -lt 18 ]]; then
    log "Installing Node LTS…"
    if [[ "$OS" == darwin* ]]; then brew install node@20;
    elif [[ "$OS" == linux* ]]; then curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash - && sudo apt-get install -y nodejs; fi
  fi
  npm install -g nativefier >/dev/null 2>&1

  TMP_DIR=$(mktemp -d)
  nativefier "http://localhost:${NATIVE_PORT_UI}" "${APP_NAME}" \
            --internal-urls ".*" --single-instance --tray \
            --disable-dev-tools --overwrite --platform "$OS" --arch "$ARCH" \
            -o "$TMP_DIR" >/dev/null

  case "$OS" in
    darwin*)
      sudo mv "$TMP_DIR"/*.app "/Applications/${APP_NAME}.app"
      log "Desktop app installed to /Applications."
      ;;
    linux*)
      chmod +x "$TMP_DIR"/*.AppImage
      sudo mv "$TMP_DIR"/*.AppImage "/usr/local/bin/${APP_NAME// /-}.AppImage"
      log "AppImage placed in /usr/local/bin."
      ;;
    *) # Windows Git-Bash / MSYS
      EX
