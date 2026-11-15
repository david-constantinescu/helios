#!/usr/bin/env bash
# Installs the Helios Hub on a Raspberry Pi (Pi Zero W / WH, Raspberry Pi OS Bookworm or Bullseye, Lite is fine).
#   cd crew-health-hub/hub && ./deploy/install.sh
# Re-run it after copying a new version; your config, hub code and data are kept.
set -euo pipefail
HUB_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN_AS="${SUDO_USER:-$USER}"
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

say "Installing system packages"
sudo apt-get update -qq
sudo apt-get install -y -qq python3-venv python3-pip python3-pil python3-serial python3-cryptography python3-spidev python3-lgpio i2c-tools avahi-daemon rsync curl

say "Enabling SPI (colour TFT) and I2C (optional OLED)"
if command -v raspi-config >/dev/null; then sudo raspi-config nonint do_i2c 0; sudo raspi-config nonint do_spi 0; fi
BOOTCFG=/boot/firmware/config.txt; [ -f "$BOOTCFG" ] || BOOTCFG=/boot/config.txt
if [ -f "$BOOTCFG" ] && ! grep -q '^dtparam=i2c_arm_baudrate' "$BOOTCFG"; then
  echo 'dtparam=i2c_arm_baudrate=1000000' | sudo tee -a "$BOOTCFG" >/dev/null
fi
sudo usermod -aG dialout,i2c,spi,gpio "$RUN_AS"

if [ "${KEEP_HOSTNAME:-0}" != "1" ] && [ "$(hostname)" != "helios" ] && command -v raspi-config >/dev/null; then
  say "Setting the hostname to helios (the app looks for helios.local; KEEP_HOSTNAME=1 to skip)"
  sudo raspi-config nonint do_hostname helios
fi

say "Installing the hub to /opt/crewhub"
sudo mkdir -p /opt/crewhub/app /etc/crewhub /var/lib/crewhub
sudo rsync -a --delete --exclude tests --exclude '__pycache__' --exclude 'oled-preview' "$HUB_DIR/crewhub" "$HUB_DIR/requirements.txt" /opt/crewhub/app/
[ -d /opt/crewhub/venv ] || sudo python3 -m venv --system-site-packages /opt/crewhub/venv
sudo /opt/crewhub/venv/bin/pip install -q --upgrade pip
sudo /opt/crewhub/venv/bin/pip install -q -r /opt/crewhub/app/requirements.txt
[ -f /etc/crewhub/config.json ] || sudo cp "$HUB_DIR/deploy/config.example.json" /etc/crewhub/config.json
# An older config (OLED) gets the colour-screen settings added and switched on; existing values are kept otherwise.
sudo python3 - "$HUB_DIR/deploy/config.example.json" <<'PY'
import json, sys
new = json.load(open(sys.argv[1])); path = "/etc/crewhub/config.json"
cur = json.load(open(path))
if "tft" not in cur:
    cur["tft"] = new["tft"]; cur["display"] = "tft"
    json.dump(cur, open(path, "w"), indent=2); print("Config: colour TFT enabled")
PY
sudo chown -R "$RUN_AS:$RUN_AS" /var/lib/crewhub

say "Starting the service and advertising it on the network"
sed "s/@USER@/$RUN_AS/g" "$HUB_DIR/deploy/crewhub.service" | sudo tee /etc/systemd/system/crewhub.service >/dev/null
sudo cp "$HUB_DIR/deploy/crewhub.avahi.service" /etc/avahi/services/crewhub.service
sudo systemctl daemon-reload
sudo systemctl enable --now avahi-daemon crewhub
sudo systemctl restart crewhub avahi-daemon
sleep 4

if [ -f "$HUB_DIR/deploy/tunnel-credentials.json" ] || [ -f /etc/cloudflared/helios-hub.json ]; then
  say "Cloudflare tunnel (public address)"
  sudo mkdir -p /etc/cloudflared
  [ -f "$HUB_DIR/deploy/tunnel-credentials.json" ] && sudo install -m 600 "$HUB_DIR/deploy/tunnel-credentials.json" /etc/cloudflared/helios-hub.json
  if ! command -v cloudflared >/dev/null; then
    case "$(uname -m)" in aarch64) ASSET=arm64;; armv7l) ASSET=armhf;; *) ASSET=arm;; esac   # Pi Zero (armv6l): "arm"
    sudo curl -fsSL -o /usr/local/bin/cloudflared "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ASSET"
    sudo chmod +x /usr/local/bin/cloudflared
  fi
  if ! cloudflared --version >/dev/null 2>&1; then
    echo "cloudflared does not run on this CPU ($(uname -m)); the hub still works on the local network." >&2
  else
    TUNNEL_ID=$(sudo python3 -c 'import json;print(json.load(open("/etc/cloudflared/helios-hub.json"))["TunnelID"])')
    HOSTNAME_PUBLIC=$(python3 -c 'import json,urllib.parse;print(urllib.parse.urlparse(json.load(open("/etc/crewhub/config.json")).get("public_url","https://nasa.softhoarders.me")).netloc)')
    sed -e "s/@TUNNEL@/$TUNNEL_ID/" -e "s/@HOST@/$HOSTNAME_PUBLIC/" "$HUB_DIR/deploy/cloudflared.yml" | sudo tee /etc/cloudflared/config.yml >/dev/null
    sudo cp "$HUB_DIR/deploy/cloudflared-helios.service" /etc/systemd/system/cloudflared-helios.service
    sudo systemctl daemon-reload
    sudo systemctl enable --now cloudflared-helios
    sudo systemctl restart cloudflared-helios
    echo "Public address: https://$HOSTNAME_PUBLIC"
  fi
fi

say "Done"
echo "Hub code (enter it in the app: Profile > Data > Helios Hub):  $(sudo cat /var/lib/crewhub/token 2>/dev/null || echo 'shown on the OLED')"
echo "Status:  systemctl status crewhub    Logs:  journalctl -u crewhub -f"
echo "Reboot once so the I2C, group and hostname changes take effect:  sudo reboot"
