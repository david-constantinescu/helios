# Helios bridge

Exposes a radiation detector to the Helios app over a **local** WebSocket (`ws://127.0.0.1:8765`).

```bash
pip install -r requirements.txt
python bridge.py --driver simulated                       # no hardware
python bridge.py --driver simulated --backfill 40 --scenario spike --spike-after 120   # demo: background + spike
python bridge.py --driver radiacode --usb                 # Radiacode 10x over USB (pip install radiacode)
python bridge.py --driver radiacode --bluetooth-mac AA:BB:CC:DD:EE:FF
python bridge.py --driver gmc --port /dev/ttyUSB0 --baud 115200   # GQ GMC (pip install pygmc)
```

Options: `--host 127.0.0.1 --ws-port 8765 --hz 1 --allow-origin app://crew-health-hub --token XYZ --log samples.csv
--cpm-to-usvh <factor>` (GMC only; no default by design) and `--config config.toml` (Python 3.11+).

**Safety:** binds to loopback by default; the WebSocket `Origin` must be on the allowlist (the iOS app sends
`app://crew-health-hub`); optional shared token (`Authorization: Bearer …` or `?token=`); non-loopback binding requires
`--token`; nothing is written to disk unless `--log`; no outbound network access.

**Protocol** (JSON per frame): `hello` (bridge, version, drivers, device, serial, simulated), `sample` (ts,
dose_rate_uSv_h, count_rate_cps, count_rate_cpm, dose_cum_uSv, battery, quality), `heartbeat` (1 s), `error`
(device_lost, …). Client → bridge: `subscribe`, `reset_cum` (simulated only).

**OS notes:** Linux serial needs your user in the `dialout` group. Windows ports are `COM3` etc. macOS Bluetooth to
Radiacode is limited; USB is the safest choice for demos. The iOS Simulator reaches the Mac at 127.0.0.1; a real
iPhone needs the Mac's LAN address with `--host 0.0.0.0 --token …`.

**Verify before trusting numbers:** Radiacode `dose_rate` units/scale and GMC firmware variants — see
`../docs/verify-register.md`.

Tests: `python tests/test_bridge.py`
