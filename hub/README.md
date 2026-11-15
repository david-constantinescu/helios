# Helios Hub — Raspberry Pi Zero + Arduino Uno + colour TFT (or OLED)

The hub is the centre of the habitat. It runs entirely on the Pi:

- **Arduino Uno** — simulates the habitat's sensors (cabin temperature, humidity, pressure, CO₂, O₂, noise, light,
  radiation dose rate and counts) and reads the **PS2-style joystick**. It streams both to the Pi over USB.
- **Raspberry Pi Zero WH** — stores everything in SQLite (sensor history plus a copy of every health record from the
  iPhones), judges the habitat readings, drives the **OLED**, and is the **server for the app**.
- **iPhone app** — connects to the hub over Wi-Fi. It sends all of each person's data and the app's analysis, and
  shows the habitat sensors. An alert acknowledged on the hub with the joystick is acknowledged on the phone too.

```
 joystick ──► Arduino Uno ──USB──► Raspberry Pi Zero WH ──I2C──► Adafruit OLED
                                        │  SQLite · status · pages
                                        └──Wi-Fi (WebSocket :8765)──► iPhone app (all Apple Health data)
```

## Wiring

**Joystick → Uno.** The Pi has no analog inputs, so the stick goes on the Uno.

| Joystick (KY-023) | Arduino Uno |
|---|---|
| GND | GND |
| +5V | 5V |
| VRx | A0 |
| VRy | A1 |
| SW | D2 (internal pull-up) |

**Uno → Pi.** Use a USB cable from the Uno into the Pi Zero's **USB** port (the inner one, not PWR) through a
micro-USB OTG adapter. The Uno shows up as `/dev/ttyACM0` and is powered by the Pi.

**Colour screen → Pi (SPI)** — the Adafruit 1.8" TFT (ST7735R, 160×128). Power it from **3.3 V**.

| TFT pin | Pi pin | GPIO |
|---|---|---|
| VCC | 17 (3.3 V) | – |
| GND | 20 | – |
| SCK | 23 | 11 |
| MOSI | 19 | 10 |
| MISO | 21 (optional) | 9 |
| TFT_CS | 24 | 8 (CE0) |
| D/C | 22 | 25 |
| RESET | 18 | 24 |
| LITE (backlight) | 1 (3.3 V) | – |
| CARD_CS | leave empty | – |

Pins 18/20/22/24 and 17/19/21/23 are two straight runs of four on the header. SPI is turned on by the installer.

If the first picture is wrong, stop the hub and run the labelled test pattern — every symptom is one config setting
under `tft` in `/etc/crewhub/config.json`:

```bash
sudo systemctl stop crewhub && python3 -m crewhub.tft_check --hold 60 --bgr 0     # try --invert 1, --rotate 3, --col-offset 2 --row-offset 1
```

| Symptom | Setting |
|---|---|
| Red and blue swapped | `bgr` true ↔ false |
| Black and white swapped | `invert` |
| Upside down / mirrored | `rotate` 1 ↔ 3 |
| 1–2 px junk line on one edge | `col_offset` / `row_offset` (green-tab boards: 1 and 2) |
| Garbage or black screen | lower `speed_hz` (8000000) and check the wires |

**OLED → Pi (I2C).** Optional alternative (`"display": "oled"`). Power the OLED from **3.3 V**, not 5 V.

| Adafruit OLED | Pi Zero header |
|---|---|
| VIN / VCC | pin 1 (3.3 V) |
| GND | pin 6 (GND) |
| SDA | pin 3 (GPIO 2) |
| SCL | pin 5 (GPIO 3) |
| RST (if present) | leave unconnected, or pin 7 with a pull-up |

Most Adafruit boards (0.96"/1.3" 128×64 SSD1306, PiOLED 128×32) work with the default settings. For an SH1106 board,
a 128×32 screen or address 0x3D, change `oled` in `/etc/crewhub/config.json`. `i2cdetect -y 1` shows the address.

## 1. Flash the Uno

```bash
arduino-cli compile --fqbn arduino:avr:uno arduino/crew_sensors
arduino-cli upload  --fqbn arduino:avr:uno -p /dev/cu.usbmodem* arduino/crew_sensors
```

You can also open `arduino/crew_sensors/crew_sensors.ino` in the Arduino IDE and upload it. It uses 28% of flash and
18% of RAM. To use a real sensor later, replace that sensor's `read…()` function; nothing else changes.

## 2. Set up the Pi

1. With Raspberry Pi Imager, write **Raspberry Pi OS Lite (32-bit)**. In the settings, set the hostname to `helios`,
   enter your Wi-Fi network and enable SSH.
2. Copy this folder to the Pi and run the installer:
   ```bash
   scp -r hub pi@helios.local:~/crew-hub
   ssh pi@helios.local
   cd ~/crew-hub && ./deploy/install.sh && sudo reboot
   ```
   The installer:
   - enables I2C at 400 kHz;
   - adds your user to the `dialout` and `i2c` groups;
   - installs the hub into `/opt/crewhub`;
   - starts it as the `crewhub` systemd service;
   - advertises it on the network as `helios.local` (`_helios._tcp`).
3. After the reboot the OLED shows the home page. Push the joystick right to the **Connect** page to see the hub's
   address and its 6-character **hub code**.

Useful commands: `journalctl -u crewhub -f` (logs), `sudo systemctl restart crewhub`, and
`curl -H "Authorization: Bearer <code>" http://helios.local:8765/status`.

### Or from this Mac in one step

Once key login works (`ssh-copy-id softhoarders@<pi>`, typed by you once), run:

```bash
./deploy/push-to-pi.sh softhoarders@helios.local
```

It copies the hub and the Cloudflare tunnel credentials, then runs the installer. The installer also sets up
`cloudflared`, so the hub is always reachable at **https://nasa.softhoarders.me**:
- the app connects there over a secure WebSocket (`wss://`);
- the same address serves the Helios web app, which can push alerts with Web Push (VAPID).

## 3. Connect the app

In the app, go to **Profile › Data › Helios Hub**. Enter `helios.local` (or the IP address shown on the hub) and the
hub code, then tap **Connect**. The phone uploads everything it holds for every person, in batches the hub
acknowledges. After that, new data follows within seconds. The app reconnects automatically after restarts or Wi-Fi
drops.

## Using the hub

| Joystick | Action |
|---|---|
| Left / right | Previous / next page |
| Up / down | Move through a list |
| Press | Open a reading's 30-minute or 14-day graph · acknowledge an alert · choose a person · run a scenario |
| Hold (0.7 s) | Back to home; on home, turn the screen off |

The pages are:

- **Home** — the person's overall status, alerts, cabin status and radiation.
- **Alerts** — press to acknowledge the highlighted alert, which also acknowledges it on the phone.
- **Cabin air** — temperature, humidity, pressure, CO₂, O₂, noise and light.
- **Radiation** — dose rate, × background, a 15-minute graph and the total dose.
- **Vitals**, **Activity** and **Health** — every Apple Health measurement the phone has, grouped.
- **Crew** — who's shown.
- **Demo** — a CO₂ scrubber fault, radiation spike, pressure leak, cooling failure or loud fan, played out by the Uno.
- **Connect** — address, code, links and uptime.

New alerts bring the screen to the Alerts page. An unacknowledged "call" alert makes the header flash. The screen
returns home after 3 minutes and turns off after 30 minutes, unless an alert is active.

## HDMI display (1080p / 720p)

`"display": "hdmi"` draws the same ten pages, laid out for a TV: a page rail on the left and, on list pages, the highlighted
row's number and chart beside the list. It writes straight to the framebuffer (`/dev/fb0`) and only the rectangles that changed.

* Resolution: `hdmi.mode` in `/etc/crewhub/config.json` (default `1920x1080@60`; use `1280x720@60` if the Pi Zero 2 W struggles).
  The installer adds `video=HDMI-A-1:<mode>e` to `/boot/firmware/cmdline.txt` so the framebuffer exists even before a monitor is plugged in. Reboot after changing it.
* Frame rate: `hdmi.fps` (default 30) is the tick of the draw loop. A frame is only drawn when something on screen changed.
* Speed check on the Pi: `python3 tools/hdmi_bench.py` (memory only) or `--fb /dev/fb0` (real screen); previews: `python3 tools/preview_hdmi.py out_dir --size 1920x1080`.

## Fast screen updates

The hub drives SSD1306 and SH1106 panels with its own driver (`crewhub/oled_fast.py`). For each frame it sends only
the changed column span of each changed 8-pixel row, so a clock tick is a few dozen bytes instead of 1 KB. I2C runs
at 1 MHz. If a panel shows noise at that speed, set `dtparam=i2c_arm_baudrate=400000` in
`/boot/firmware/config.txt`. Joystick input redraws immediately.

## Alerts on any device (Web Push)

Open https://nasa.softhoarders.me and enter the hub code. On iPhone, use Share › Add to Home Screen, open Helios from
there and tap **Allow alerts on this device**. The hub then pushes habitat alerts and every person's urgent alerts
to that device, even when the app is closed. The VAPID keys are generated on first start in `/var/lib/crewhub/`.

## Without hardware (any Mac or PC)

```bash
pip install -r requirements.txt
python -m crewhub --serial sim --display png --png-dir oled-preview --host 127.0.0.1 --token TEST12 \
                  --db /tmp/hub.db --token-file /tmp/hub-token
python tools/preview.py pages.png          # every OLED page on one sheet (add --height 32 for a 128x32 screen)
python -m pytest -q tests                   # 29 tests: parser, levels, pages, storage, server
```

In the iOS Simulator, connect the app to `127.0.0.1` with code `TEST12`. `oled-preview/oled.png` always shows the
current screen. With `--serial sim`, the app or a test client can also send `{"type":"joystick","key":"R"}` to
drive the screen.

## Protocols

**Uno → Pi** (115200 baud, one line per message):

| Message | Meaning |
|---|---|
| `H,crew-sensors,1.0,…` | Hello |
| `S,<seq>,t=22.4,rh=45,p=101.3,co2=612,o2=20.9,db=52,lux=310,rad=0.112,cpm=19,scn=0` | Sensor frame, once a second |
| `J,L\|R\|U\|D\|P\|H` | Joystick event |

**Pi → Uno:** `C,scenario,<normal|co2|spike|leak|heat|noise>`, `C,rate,<ms>`, `C,ping`.

**App ↔ hub** (WebSocket, port 8765). It's a superset of the radiation-bridge protocol. Every connection needs the
app's Origin and the hub code.

- Hub → app: `hello`, `sample` (radiation), `env` (sensors and levels), `upload_ack`, `ack_alert`, `heartbeat`.
- App → hub: `client`, `upload` (observations), `snapshot` (the app's analysis per person), `scenario`,
  `env_history`.

The link runs over Wi-Fi today. Because the messages are plain JSON, Bluetooth or Wi-Fi Direct can carry the same
protocol later.

## Habitat thresholds

Habitat statuses (OK / Watch / Act / Call) use station-style bands. Examples: CO₂ is Watch from 2,600 ppm, Act from
4,000 and Call from 5,300; O₂ is OK from 19.5 to 23.5%; cabin pressure is OK from 97.9 to 103 kPa. Radiation is
judged against the learned background: ×3 Watch, ×10 Act, ×50 Call. Override any band under `"sensors"` in
`config.json`, for example `"co2": [[3, null, 6000], [2, null, 4500], [1, null, 3000]]`.
