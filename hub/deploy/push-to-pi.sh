#!/usr/bin/env bash
# From this Mac: copy the hub (and the tunnel credentials) to the Pi and run the installer there.
#   ./deploy/push-to-pi.sh softhoarders@helios.local
# Needs SSH key login first (once):  ssh-copy-id softhoarders@<pi>
set -euo pipefail
TARGET="${1:?usage: push-to-pi.sh user@host}"
HUB_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CREDS="${TUNNEL_CREDENTIALS:-$HOME/.cloudflared/e5ffca54-3af4-4cbd-ab73-a4fd172e934b.json}"
rsync -az --delete --exclude '__pycache__' --exclude '.pytest_cache' --exclude 'oled-preview' --exclude 'tests' "$HUB_DIR/" "$TARGET:~/helios-hub/"
if [ -f "$CREDS" ]; then scp -q "$CREDS" "$TARGET:~/helios-hub/deploy/tunnel-credentials.json"; fi
ssh -t "$TARGET" 'cd ~/helios-hub && ./deploy/install.sh && rm -f deploy/tunnel-credentials.json'
