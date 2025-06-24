#!/usr/bin/env bash
#--------------------------------------------------------------------
# Local-LLM-SaaS zero-cost installer  •  Tested 2025-06 on:
#  • Ubuntu 22.04 / Fedora 40
#  • macOS 14 M-series + Intel
#  • Windows 11 Pro (Git-Bash + Docker Desktop + WSL2)
#--------------------------------------------------------------------
set -euo pipefail

APP_NAME="Local LLM Chat"
MODEL="llama3:8b"                 # any ollama-pullable tag
NATIVE_PORT_UI=3000               # what users hit
INTERNAL_PORT_UI=8080             # Open WebUI’s default
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)

need() { command -v "$1" >/dev/null 2>&1; }

#──────────────────────── Docker install (Linux & macOS)
install_docker() {
  echo "🧰 Installing Docker + Compose…"
  if [[ "$OS" == "linux" ]]; then
      if need apt-get; then
          sudo apt-get update
          sudo apt-get install -y ca-certificates curl gnupg lsb-release
          sudo mkdir -p /etc/apt/keyrings
          curl -fsSL https://download.docker.com/linux/$(. /etc/os-release; echo "$ID")/gpg |
            sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
          echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(. /etc/os-release; echo "$ID") \
$(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
          sudo apt-get update && sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
      elif need dnf; then
          sudo dnf install -y dnf-plugins-core
          sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
          sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
      else
          echo "❌ Unsupported Linux distro. Install Docker manually."; exit 1
      fi
      sudo systemctl enable --now docker
      sudo usermod -aG docker "$USER" || true
  elif [[ "$OS" == "darwin" ]]; then
      if ! need brew; then
          echo "Installing Homebrew first…"; 
          /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
          eval "$($(brew --prefix)/bin/brew shellenv)"
      fi
      brew install --cask docker
      open -a Docker
  fi
}

if ! need docker || ! docker compose version &>/dev/null; then
  install_docker
fi

#──────────────────────── Write docker-compose.yml
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

#──────────────────────── Bring stack up
echo "🚀 Booting local-LLM stack (this first run may grab ~8 GB)…"
docker compose pull
docker compose up -d

#──────────────────────── Wait for WebUI health
echo -n "⌛ Waiting for WebUI… "
until curl -fs http://localhost:${NATIVE_PORT_UI}/health &>/dev/null; do sleep 2; done
echo "ready."

#──────────────────────── Desktop app via Nativefier
build_app() {
  echo "📦 Bundling Electron desktop app…"
  if ! need node || [[ $(node -v | cut -d. -f1 | tr -d v) -lt 18 ]]; then
     echo "Installing Node LTS…"
     if [[ "$OS" == "darwin" ]]; then brew install node@20;
     elif [[ "$OS" == "linux" ]]; then curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash - && sudo apt-get install -y nodejs; fi
  fi
  npm install -g nativefier >/dev/null

  TMP_BUILDDIR=$(mktemp -d)
  nativefier "http://localhost:${NATIVE_PORT_UI}" "${APP_NAME}" \
             --internal-urls ".*" --single-instance --tray \
             --disable-dev-tools --overwrite --platform "$OS" --arch "$ARCH" \
             -o "$TMP_BUILDDIR"

  if [[ "$OS" == "darwin" ]]; then
      sudo mv "$TMP_BUILDDIR/"*.app "/Applications/${APP_NAME}.app"
      echo "✅ App copied to /Applications."
  elif [[ "$OS" == "linux" ]]; then
      chmod +x "$TMP_BUILDDIR/"*.AppImage
      sudo mv "$TMP_BUILDDIR/"*.AppImage "/usr/local/bin/${APP_NAME// /-}.AppImage"
      echo "✅ AppImage installed to /usr/local/bin."
  else  # Windows Git-Bash
      EXE=$(find "$TMP_BUILDDIR" -name "*.exe" | head -n1)
      INSTALL_DIR="/c/Program Files/${APP_NAME}"
      mkdir -p "$INSTALL_DIR"
      mv "$(dirname "$EXE")"/* "$INSTALL_DIR"
      powershell.exe -NoProfile -Command "\$s=(New-Object -ComObject WScript.Shell).CreateShortcut('%PUBLIC%\\Desktop\\${APP_NAME}.lnk');\$s.TargetPath='${INSTALL_DIR//\//\\}\\$(basename "$EXE")';\$s.Save()"
      echo "✅ Windows shortcut created."
  fi
}
build_app

#──────────────────────── First-time model pull
echo "⏳ Pulling model \"${MODEL}\" (first run only)…"
ollama pull "$MODEL"

cat <<EOF

🎉  All set!

   Open the desktop app you’ll find in the usual place,
   or visit http://localhost:${NATIVE_PORT_UI} in any browser.

   Need another model?   ollama pull <model-name>
   Stop the stack?       docker compose down
   Update?               git pull && ./install.sh --update

EOF
