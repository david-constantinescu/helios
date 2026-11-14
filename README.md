# Helios

*Your own flight surgeon, when Earth is too far to call.*

An offline-first **iPhone app** that lets an astronaut assess their own health far from Earth. It keeps
**continuously in sync with Apple Health** (iPhone + Apple Watch), plugs in a consumer radiation detector through a
small local bridge, accepts manual measurements and file imports, compares each person with **their own baseline**,
and shows the result on an interactive **body map** and **five-hazard** dashboard. It explains what changed in plain
language, says what to do and when to call the flight surgeon, and exports a one-page **flight-surgeon summary**.

Built for the NASA Space Apps Challenge 2026 — *Create Health Monitoring Software for Astronauts on Space Missions*.

The **Helios Hub** is the centre of the habitat: a **Raspberry Pi Zero WH** with an **Adafruit OLED**, a
**PS2-style joystick** and an **Arduino Uno** that streams the habitat's sensors. It stores everything, shows it on
its screen and is the server the app connects to. See [hub/README.md](hub/README.md).

## Why native iOS (deviation from the original PWA spec)

The build brief described a vanilla-JS PWA. A web app **cannot read HealthKit**, so the only way to meet the
requirement “connect to Apple Health, always keep syncing and stay in sync” is a native app. The spec's data model,
engines, configuration files, copy library and screens were ported to **Swift / SwiftUI** one-to-one; the config JSON
format is unchanged. No third-party dependencies: Apple frameworks only (SwiftUI, Swift Charts, HealthKit, SQLite3,
BackgroundTasks).

## Quick start

Requirements: Xcode 26+ (tested with Xcode 27.2) and an iOS 18+ simulator or iPhone. Liquid Glass appears on iOS 26+.

```bash
cd ios
xcodebuild -project CrewHealthHub.xcodeproj -scheme CrewHealthHub -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

Or open `ios/CrewHealthHub.xcodeproj` in Xcode and press Run. The welcome screen offers three paths:
**Connect Apple Health**, **Explore the demo mission** (opens at mission day 44) and **Use my Health export file**.

## Use your own health data

**On your iPhone (live, keeps syncing):**
1. Xcode › Settings › Accounts: sign in with your Apple ID.
2. Open the project, select the CrewHealthHub target › Signing & Capabilities, pick your Team.
   If the bundle ID is taken, change it (e.g. `com.yourname.crewhealth`).
3. Connect your iPhone, enable Developer Mode (Settings › Privacy & Security), trust the Mac, choose the iPhone as run
   destination and press Run. Tap **Connect Apple Health** and allow access.
   If Xcode refuses the HealthKit Background Delivery entitlement for a free account, remove that key from
   `ios/Support/CrewHealthHub.entitlements`; sync then happens whenever the app opens and in background refresh.

**On the simulator (import):** in the Health app on your iPhone tap your picture › *Export All Health Data*, AirDrop
`export.zip` to the Mac and drag it onto the simulator window (or save it to Files), then in the app use
*Use my Health export file* / *Profile › Data › Import Health export*. The importer streams the zip (Zip64 and
multi-GB exports supported), keeps one source per day for steps and exercise so iPhone + Watch aren't double counted,
and downsamples heart rate to 5-minute medians. Nothing leaves the device.

## Apple Health: continuous two-way sync

| Mechanism | What it does |
|---|---|
| `HKAnchoredObjectQuery` per type, anchor persisted in SQLite | Fetches only new/changed samples since the last sync, in 5,000-sample batches. |
| Deleted objects | Health UUIDs are stored as the observation's external id; deletions in Health remove the local rows and re-aggregate those days. |
| `HKObserverQuery` + `enableBackgroundDelivery(.immediate)` for **every** type, registered at app launch | Changes are pulled in while the app is open **and** when iOS wakes it in the background. |
| `HKStatisticsCollectionQuery` (cumulative sum, separate-by-source) | Steps and exercise minutes are de-duplicated across iPhone + Watch; an anchored query detects which days changed. |
| Foreground re-sync + `BGAppRefreshTask` | Safety net if a background delivery was missed. |
| Write-back | Manual BP, temperature, glucose, weight, SpO₂, water, sleep, symptoms and mood (State of Mind, iOS 18) are saved to Health; the HK UUID is the dedupe key so the sync never duplicates them. |
| Database file protection `completeUntilFirstUserAuthentication` | Background deliveries can write while the phone is locked (after first unlock). |

Types (90, all read-only except the core write-back set). They're catalogued once in
`HealthKit/HealthTypes.swift`, and both live sync and the export importer use that catalog:
- **Core:** heart rate (with motion context), resting HR, HRV (SDNN), SpO₂, respiratory rate, blood pressure, body
  temperature, sleeping wrist temperature, glucose, body mass, water, steps, exercise minutes.
- **Heart:** walking HR, HR recovery, VO₂ max, AFib history, perfusion index, high/low/irregular-rhythm and
  low-fitness notifications.
- **Breathing:** breathing disturbances, sleep-apnea notifications, FVC/FEV₁/peak flow, inhaler use.
- **Body:** body fat, BMI, lean mass, height, waist, basal temperature.
- **Activity:** active/resting energy, walking/running, cycling and swimming distance, flights, stand minutes and
  hours, time in daylight, physical effort, workouts, mindful minutes.
- **Mobility:** walking speed, step length, asymmetry, double support, stair speeds, six-minute walk, walking
  steadiness, falls.
- **Hearing & environment:** environmental and headphone audio, loud-environment notifications, UV, handwashing.
- **Nutrition:** energy, protein, carbohydrate, fat, sugar, fibre, sodium, potassium, calcium, vitamin D, iron,
  caffeine, alcohol, blood alcohol.
- **Other:** insulin, electrodermal activity, sleep stages (deep, REM, core, awake, in bed) and 11 symptom
types, and State of Mind. *Profile › Data › Advanced › Data types and sync log* shows per-type counts, background-delivery state and a live log.

Verified on the iOS 18.2 simulator:
- initial backfill (≈2,000 samples across 15 types) and steps/exercise day totals for the whole window;
- **live updates within seconds** while the app is open (a new heart-rate sample every 10 s);
- **deletions** in Health removed from the app; relaunch with **no duplicates**;
- **write-back**: a blood-pressure entry made in the app appears in the Health app, and is stored once here;
- a value typed into the **Health app** by hand is imported on return to the foreground (labelled *manual*).

Health export import verified on the iOS 27.2 simulator: a 3-month `export.zip` (≈3 MB of XML) unzips, imports into
the *Me* profile and drives Today, Body and Trends — including a real sleep-drop escalation in that data.

Not verifiable on the simulator: **background wake-ups**. `enableBackgroundDelivery` succeeds for every type, but the
simulator did not wake the backgrounded app for a new sample within 30 s; on a real iPhone iOS delivers these
updates (frequency is decided by iOS — e.g. steps at most hourly). The foreground re-sync and `BGAppRefreshTask`
cover anything missed.

The *Demo tools* (simulator, or dev mode on a device) seed 30 days of tagged synthetic samples into the empty simulator
Health store. They show as **SIMULATED** here, but other apps would treat them as real — never use them on a personal
iPhone. History defaults to the last **365 days** (*Apple Health sync › History to import*, up to 10 years); extending
it re-reads the older data.

## Notifications and the Action button

- **Notifications:**
  - urgent alerts (time-sensitive);
  - new changes to watch;
  - habitat alerts from the hub;
  - a daily check-in reminder.

  You choose them in Profile › Notifications. The hub also sends Web Push to any device subscribed at
  nasa.softhoarders.me.
- **Action button:** Helios provides a **Start daily check-in** App Shortcut. On an iPhone with an Action button, go
  to Settings › Action Button › Shortcut and choose *Helios › Daily check-in*. It also works from Siri ("Start my
  Helios check-in"), Spotlight and the Shortcuts app.
- **Your normal from day one:** baselines come straight from your imported Apple Health history. There is no
  learning period.

## Helios Hub (Raspberry Pi)

The Pi reads the Uno's sensors and joystick, keeps everything in SQLite, drives a 10-page OLED UI, and serves the app
over Wi-Fi on port 8765 (`helios.local`). In the app, go to **Profile › Data › Helios Hub**, enter the address and the
code from the hub's Connect page, and tap Connect. Every observation for every person is uploaded, along with each
person's analysis. The app shows the hub's habitat sensors on the Hazards tab, and alerts acknowledged on the hub's
joystick are acknowledged on the phone. Wiring, setup and protocols are in [hub/README.md](hub/README.md).

Verified on this Mac against the iOS 27.2 simulator, with the hub running against a simulated Uno:
- upload of all 21,146 observations (both people) with exact counts on both sides;
- David's status on the OLED;
- live cabin air in the app;
- a scenario triggered from the app;
- a radiation alert shown on the OLED, acknowledged with the joystick and cleared on the phone.

Not verified here: the real Pi, I2C OLED, Uno USB link and joystick hardware.

## Radiation bridge (standalone detector on a laptop)

```bash
cd bridge
pip install -r requirements.txt
python bridge.py --driver simulated --backfill 40 --scenario spike   # no hardware
python bridge.py --driver radiacode --usb                            # Radiacode 10x
python bridge.py --driver gmc --port /dev/tty.usbserial-XXXX          # GQ GMC
```

Then *More › Data sources › Radiation sensor › Connect*. The simulator reaches the Mac at `127.0.0.1`. A real iPhone
needs the Mac's LAN address, and the bridge refuses non-loopback binding without `--token`.

## What's in the box

- **Engines** (pure Swift, unit-tested): ingest + QC + dedupe, daily aggregation (sleep night attribution and
  overlap merging, BP pairing, resting-HR derivation), robust personal baselines (median/MAD), deviation + Theil–Sen
  trend, explainable status rules, compound patterns, region/hazard/overall roll-up, radiation (background, EWMA,
  spike detection, trapezoid dose with gaps, counter resets, budget), guidance with verified gate, scheduler,
  quests/badges with safety caps.
- **Screens**: onboarding, Today, Body map (front/back + list), Trends (baseline bands, reference shading, events,
  compare mode, data table, CSV), Hazards (+ radiation panel), Check-in (60 s), Manual entry, Guidance
  (Now/Learn/Escalation/Playbooks), Quests, Data sources, Apple Health sync, Simulator, File import (CSV/TSV/JSON/
  Apple Health `export.xml`), Radiation sensor, Crew (consent-based), Export (JSON/HTML/CSV/print), Settings, About.
- **Simulator**: seedable 180-day mission with David producing the storyline (sleep → heart/brain → radiation event → mood
  dip → exercise lapse), speeds 1×…5 days/s, jump, inject events, auto-pause on escalation.

## Privacy

All data lives on the device in SQLite (excluded from backups, file-protected) and, when connected, on your own Crew
Hub. Hub connections need the code shown on the hub's screen. There are no accounts, cloud servers, analytics or
CDNs. *Settings › Export all data* and *Delete all data* are always available. Every clinical number lives in
`ios/CrewHealthHub/Resources/config/*.json` with its `source`; see [docs/verify-register.md](docs/verify-register.md).

## Tests

- iOS: 47 XCTest cases (units, QC, dedupe, aggregation, baselines, every status branch, roll-up, patterns, radiation,
  guidance, scheduler, quests, CSV/JSON/Apple Health XML importers, export.zip extraction incl. Zip64, data
  descriptors and a 150:1-compressed export, and the Health type catalog: every unit compatible with its type, every
cumulative type truly cumulative, every type read-only and known to the config, export unit conversion). All pass on
the iOS 27.2 simulator.
- Helios Hub: `cd hub && python -m pytest -q tests` (25 tests: Uno line parser incl. boot noise and half lines,
  habitat levels, radiation background, every OLED page at 128×64 and 128×32, joystick navigation, storage, server code
  gate, upload/snapshot/scenario/acknowledgement round trip).
- Bridge: `python bridge/tests/test_bridge.py` (protocol, Origin/token rejection, reconnect).

## Docs

[architecture](docs/architecture.md) · [engines](docs/engines.md) · [adapters](docs/adapters.md) ·
[method](docs/method.md) · [sources](docs/sources.md) · [verify register](docs/verify-register.md) ·
[demo script](docs/demo-script.md) · [hardware roadmap](docs/hardware-roadmap.md)

## Licence

MIT (see [LICENSE](LICENSE)). No third-party code is bundled in the iOS app. The bridge uses `websockets` (BSD) and
optionally `radiacode` (MIT) and `pygmc` (MIT) — TODO(verify) licences of the versions you install.

The Helios Hub uses `websockets` (BSD), `luma.oled` (MIT), `pyserial` (BSD) and Pillow (HPND). The OLED font
(`hub/crewhub/font5x7.py`) is the classic 5×7 font from the Adafruit GFX Library (BSD, notice kept in the file).
