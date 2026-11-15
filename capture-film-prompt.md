# Prompt: produce an Apple-style animated demo film of Crew Health Hub (self-contained)

Paste **everything below the line** into a brand-new Claude Code session. It assumes no other context. The session needs Bash and the iOS Simulator tool.

---

# MISSION BRIEF

You are a **motion designer and iOS engineer**. Produce a **polished, dynamic, Apple-keynote-style animated demo film** of the iPhone app **Crew Health Hub** for the judges of the **NASA Space Apps Challenge 2026**.

**The look**
- Deep black/navy space, huge confident typography, one idea per beat.
- The phone floats with a soft shadow and a gentle 3D tilt; spring physics everywhere.
- The camera pushes into the UI to magnify the detail that matters. Light sweeps across the glass.
- Calm, premium, precise. Never busy.

**Two jobs**
1. **Capture.** Drive the real app on the iOS Simulator and record clean, deterministic footage and screenshots.
2. **Compose.** Build an animated film around that footage in code (Remotion, or an ffmpeg fallback) and render the final videos.

**Everything shown must be real app behaviour.** Graphics may frame, magnify and explain footage. They must never fake a feature, a screen, a number or a status.

This brief contains everything you need. It was written from the source code and checked on this Mac on **2026-11-15**. If anything here disagrees with what you see on screen, **trust the screen**, adapt, and note the difference in your report.

---

## 0. WHERE THINGS ARE

**Project root (absolute path; quote it, because it contains spaces):**

```
/Users/thechallenger_/Downloads/nasa/crew-health-hub
```

In shell, set it once and reuse it:

```bash
ROOT="/Users/thechallenger_/Downloads/nasa/crew-health-hub"
```

If that folder doesn't exist, stop and ask the user where the project is now. It may have been moved to a permanent folder.

| Path (relative to ROOT) | What it is |
|---|---|
| `ios/CrewHealthHub.xcodeproj` | Xcode project, scheme **`CrewHealthHub`** |
| `ios/CrewHealthHub/App/CrewHealthHubApp.swift` | App entry and **deep-link handler** `handle(url:)` (§3.3) |
| `ios/CrewHealthHub/UI/*.swift` | All screens (RootView, TodayView, BodyMapView, TrendsView, HazardsView, CheckInView, ManualEntryView, HealthConnectView, SourcesView, GuidanceQuestsView, ExportView, SettingsAboutView, WelcomeView) |
| `ios/CrewHealthHub/UI/Components.swift` | Colour tokens (§6.1) |
| `ios/CrewHealthHub/Resources/config/*.json` | Metrics, hazards, regions, guidance, strings. All app wording comes from here |
| `ios/CrewHealthHub/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png` | App icon (use it on the title and end card) |
| `bridge/bridge.py` | Python radiation bridge (WebSocket) |
| `README.md`, `docs/project-overview.md`, `docs/demo-script.md` | What's built, the story, and the approved pitch lines. **Read all three first** |

**Your output folder:** `"$ROOT/demo/"`. Create it. Everything you make goes here and nowhere else.

---

## 1. VERIFIED ENVIRONMENT (checked 2026-11-15; re-check quickly)

- **The Debug build succeeds** with the command in §3.1. There are only Swift concurrency warnings, which you can ignore. The app lands at `/tmp/chh-film-build/Build/Products/Debug-iphonesimulator/CrewHealthHub.app`.
- **Booted simulator:** "iPhone 18 Pro HELIOS", UDID `8378B3B6-407D-4B65-BB08-6B1C1C9C733E`, **iOS 27.2**.
  - Also available: iPhone 18 Pro Max, iPhone 17, iPhone Air, iPad Pro 13" / 11" (M5), iPad Air, iPad mini.
  - Re-check with `xcrun simctl list devices`.
- **Tools present:** `ffmpeg`/`ffprobe` (`/usr/local/bin`), `node` v23.6 + `npm`/`npx`, `python3` 3.10 with `websockets` 14.2 (the bridge runs as is), `xcodebuild`/`xcrun`, Keynote.app, Blender.app.
- **Fonts:** SF Pro Display / SF Pro Text are installed in `/Library/Fonts/SF-Pro-*.otf`.
- **Text to speech:** macOS `say` has **no Premium/Enhanced voices** installed. A TTS voice-over would sound basic, so prefer captions only (§8).
- **Not installed:** Remotion (an npm package; ask before installing, §7), `moviepy`, ImageMagick.

---

## 2. HARD RULES

1. **Don't modify anything outside `"$ROOT/demo/"`.**
   - No app source, config, project or docs edits.
   - If the app misbehaves, stop, screenshot it, and report. Don't fix app code.
   - Another developer session may be working on this project, so use your own build folder (`/tmp/chh-film-build`) and never delete other build outputs.
2. **iOS Simulator only.** Never install on, or write Health data to, a physical iPhone. The app's Health demo data is synthetic and would pollute a real Health store.
3. **No personal data** in any frame. Use only the app's synthetic, seeded data.
4. **Never tap any of these:**
   - "Delete all data…", "Delete everything", "Reset to defaults"
   - "Remove simulated mission", "Restart mission" / "Restart from day 0" (unless you are deliberately resetting off-camera)
   - "Undo last import", "Rebuild from raw data"
5. **Honesty is part of the brand.**
   - The app's **SIMULATED** labels must stay visible whenever simulated data is on screen. Never crop or cover them.
   - Show the radiation-device label and "Draft guidance, not yet reviewed" at least once each.
   - The end card must say: **"Decision support only. Not a medical device."**
6. **No invented medical or scientific claims.** On-screen text comes only from the app's own strings, `README.md`, `docs/demo-script.md`, `docs/project-overview.md`, and the exact lines in the storyboard (§6.5).
7. **Only show what's built.** Planned items may appear only as plain typography in one "Next" beat, never as UI. Planned items are:
   - Arduino/Raspberry Pi hardware
   - iPad Commander mode
   - Mission Control with light-time delay
   - Live Activity / Dynamic Island
   - widgets
   - AI features
8. **Brand and trademark safety.**
   - Use Apple *style*, not Apple *branding*: no Apple logo, no "Shot on iPhone", no implied endorsement.
   - No NASA insignia or Space Apps logo unless the user supplies the file and approves it. Plain text "Built for the NASA Space Apps Challenge 2026" is fine.
   - Draw the phone frame yourself in code. Don't download Apple's product bezels.
   - Don't export SF Symbols as standalone artwork. Symbols that appear inside the app footage are fine.
9. **Fonts.** Use the local SF Pro files for rendering on this Mac only. Never copy them into `demo/` or any deliverable folder.
10. **No copyrighted music.** Render without music unless the user supplies a track with a licence.
11. **Ask the user once before installing anything** (e.g. npm packages). Pin exact versions released at least two weeks ago; never `latest`.
12. **Nothing leaves this Mac.** No uploads, no cloud services.
13. **Clean up everything you start:** recordings, the bridge, the live heart-rate writer, the status-bar override.
14. **Never claim something worked unless you saw it** in a screenshot or an extracted frame.

---

## 3. HOW TO CONTROL THE APP (complete manual)

### 3.1 Build, install, launch
```bash
UDID=8378B3B6-407D-4B65-BB08-6B1C1C9C733E      # or another iPhone you boot
cd "$ROOT/ios"
xcodebuild -project CrewHealthHub.xcodeproj -scheme CrewHealthHub -configuration Debug \
  -destination "id=$UDID" -derivedDataPath /tmp/chh-film-build build -quiet
APP=/tmp/chh-film-build/Build/Products/Debug-iphonesimulator/CrewHealthHub.app
xcrun simctl uninstall $UDID org.spaceapps.crewhealthhub   # fresh state (ignore error if not installed)
xcrun simctl install $UDID "$APP"
xcrun simctl launch $UDID org.spaceapps.crewhealthhub
xcrun simctl terminate $UDID org.spaceapps.crewhealthhub   # when needed
```

- **Debug is required.** The automation deep links (§3.3) are compiled only into Debug builds.
- **Bundle ID:** `org.spaceapps.crewhealthhub`. **URL scheme:** `crewhealth://`.
- **Launch argument `-demo`:** starts the demo mission immediately. Run it with `xcrun simctl launch $UDID org.spaceapps.crewhealthhub -demo`.
- **Live panel:** open it with the iOS Simulator tool, action `attach`, so the user can watch.
  - Use that tool's `screenshot`, `tap`, `swipe` and `text` actions.
  - Coordinates are in **device points**. The `launch`/`attach` result reports the point size, and screenshots come back at pixel size (×3 on Pro phones).
- **Clean status bar:**
  ```bash
  xcrun simctl status_bar $UDID override --time 9:41 --dataNetwork wifi --wifiBars 3 --cellularBars 4 --batteryState charged --batteryLevel 100
  xcrun simctl ui $UDID appearance dark
  ```
  The app forces dark mode anyway. Clear the override at the end with `xcrun simctl status_bar $UDID clear`.

### 3.2 What the UI looks like (iOS 26+ "Liquid Glass" design; this simulator runs iOS 27.2)

**First launch: Welcome screen (`WelcomeView`)**
- A pulsing ECG glyph, the title **"Crew Health"**, and the line **"Your own flight surgeon, when Earth is too far to call."**
- Three feature lines:
  - "Learns your normal from Apple Health"
  - "Spots changes early and tells you why"
  - "Everything stays on this iPhone"
- Two buttons at the bottom:
  - **"Connect Apple Health"** (white capsule). Requests HealthKit permission.
    - A system sheet appears. Turn all categories on (the "Turn On All" control) and confirm with **Allow**. The wording may vary by iOS version, so read the screen.
    - The app then creates the person **"Me"** (mission "My mission", environment "Space station") and opens **Today**.
  - **"Explore the demo mission"** (glass capsule). Sets up the seeded simulated mission (seed 42, station), fast-forwards to **day 44** (heart strain building), and opens **Today**. It does **not** auto-play.

**Main UI: 4 tabs at the bottom**
- **Today** · **Body** · **Trends** · **Hazards**
- **Top-right toolbar on every tab:** a round gradient **avatar** with the person's initial (accessibility label "Profile, data sources and settings"). It opens the **Profile** sheet.
  - **Today** also has a **"+"** menu (accessibility "Log") with **Daily check-in** and **Add a measurement**.
  - **Body** also has a **list/figure toggle** ("Show list" / "Show figure").

**Demo player (only when a simulated mission is the current person)**
- On iOS 26+ it sits in the **tab bar's bottom accessory**, like the Music app's mini player. It **minimises when you scroll down**; scroll up to restore it.
- It shows ✨ **"Mission day N"** and "Playing · 1 day/s", "Demo mission" or "Paused for an alert".
- Two buttons:
  - **⏩ (accessibility "Demo options")** opens a menu:
    - **Speed** picker: 1×, 60×, 600×, 3600×, 1 day/s, 5 days/s
    - **Jump to:** "Day 27 · short sleep", "Day 44 · heart strain", "Day 60 · radiation event", "Day 95 · isolation", "Day 122 · exercise lapse"
    - **Trigger now:** "Radiation spike", "Short sleep", "Mood dip"
    - "Restart mission" (destructive; don't use on camera)
  - **▶︎ / ❚❚ (accessibility "Play demo" / "Pause demo").**

**Today tab**
1. Hero card: date · "Mission day N", the overall status with a one-line summary, and "Compared with your own normal".
2. **"What changed"**: rows with reasons.
3. Metric tiles.
4. **Daily check-in** card with a **Start** button (when it is due).
5. **"Next steps"**.
6. A sync pill for the Apple Health owner.

**Body tab**
- A **Front | Back** segmented control at the top-left, the body figure with regions coloured by status, and a summary row underneath.
- **Tapping a region** opens a half-height sheet showing:
  - the region name and its hazards line
  - the reason text, with numbers when the status is Watch or above
  - **Measure now** and **See trend** buttons
  - **"What you can do"** with a list of actions
  - an escalation contact line
- Drag the sheet down to close it.
- The 8 regions are: brain, eyes, heart, lungs, gut, bones & muscle, immune & skin, whole body.

**Trends tab**
- Chart of one indicator with the **personal baseline band**, reference shading, events and a range picker.
- Top menu ("Chart options"):
  - Toggles: "Raw samples", "Data table"
  - Submenus: "Compare with", "All indicators" (pick the metric here), "Export CSV"
- **See trend** on Body sets the metric and switches here.

**Hazards tab**
- At the top, a **radiation hero card** (live µSv/h) that opens **Radiation detail**.
- Below it, the 5 hazard rows: **Space radiation, Isolation & confinement, Distance from Earth, Gravity fields, Hostile closed environments**. Each opens a hazard detail.
- **Radiation detail** has these sections:
  - **Dose** (and budget)
  - **Events** (start, "Peak … µSv/h · N min · … µSv")
  - **During an event** (numbered steps)
  - a **"Connect a detector"** / "Detector: …" button
  - the radiation-device honesty label

**Radiation source screen** ("Connect a detector", also under Profile → Devices & imports → radiation row)
- A URL field, default `ws://127.0.0.1:8765`.
- **"Connect to bridge"** / "Disconnect".
- **"Use simulated radiation"**, then **"Trigger test spike"** and "Stop simulated detector".
- Text: "On the Mac running the simulator:", followed by the bridge command.

**Profile sheet** (from the avatar; "Done" button top-right)
- Header: initial, name, "mission · environment".
- A **"Viewing"** picker appears when there is more than one person. The Apple Health owner is shown as **"Me (me)"**; the simulated crew have their own names.
- **Data** section:
  - **Apple Health**: shows "Live"/"On" in green when connected.
  - **Devices & imports**: radiation, file import, manual entry, demo mission.
  - **Demo mission**: jump slider, Jump, inject buttons, Restart, Remove.
- **Care** section: **Guidance**, **Quests**, **Crew**, **Share with flight surgeon**.
- Then **Settings** and **About**.

**Apple Health screen (`HealthConnectView`)**
- Per-type rows with sample counts, under **"Reading"**.
- "Save my measurements to Health" toggle.
- History picker: 1 year / 2 years / Everything.
- **"Demo data (simulator)"**, shown only in the simulator:
  - **"Add 30 days of sample data"** (reads "Writing…" while it runs)
  - **"Stream live heart rate"** / "Stop live heart rate"

**Daily check-in** (sheet, 3 steps)
1. **"How are you feeling?"** ("Takes about a minute"): tap a mood. **Continue** is disabled until a mood is picked.
2. **"Last night"**: "Asleep … h … min", pre-filled "From your Apple Watch" when data exists. Then **"Any symptoms?"**: tap a symptom chip once for mild, again for moderate/severe, a third time to clear.
3. Scheduled measurements, or "No measurements are scheduled for today."

The bottom button reads **Continue** on steps 1–2 and **Log check-in** on step 3. A result screen follows; finish with **Done**.

**Add measurement** (sheet, title "Add measurement")
- Pickers: Indicator, value field(s), Unit, "Measured at", Activity (Rest / After exercise / Unknown).
- Toggles: "Fasting", "I measured this now".
- For symptoms: a Symptom picker and a Severity picker (Mild/Moderate/Severe).
- Shows **"Also saved to Apple Health"** when write-back applies.
- Toolbar: **Close** (left) and **Save** (right).

**Escalation screen (full-screen, sticky)**
- It appears **automatically** whenever the current person has an unacknowledged escalation, and covers everything until acknowledged.
- **Radiation version** shows:
  - a pulsing atom, **"RADIATION EVENT"**, **"Move to the shelter"**, and an explanation
  - three stat tiles: **µSv/h now**, **× background**, **elapsed**
  - 4 numbered playbook steps
  - a note field
  - a red **"Contact flight surgeon"** button, which shows a "How to reach them" alert; tap OK
  - **"I’ve reported this"** (with a typographic apostrophe), which dismisses it
- **Other version:** "NEEDS ATTENTION", "Contact your flight surgeon".
- If an escalation pops up during a scene where you don't want it, acknowledge it off-camera and re-take.

**Share with flight surgeon (`ExportView`)**
- **Crew member** picker.
- **Period**: 7 days / 14 days / 30 days / Mission.
- Section toggles: Status overview, Baselines vs current, Deviations and patterns, Radiation log and dose, Symptoms, Adherence, Notes.
- **"Generate summary"**, then rows **"Share HTML — …"**, "Share JSON — …", "Share CSV — …".
- **"Print / save as PDF"** opens the iOS print sheet, which has a preview. Cancel it.

**Other screens**
- **Crew:** toggles "Share status with crew", "Share health values", "Share radiation dose" (off by default) and a crew list.
- **Guidance:** a segmented picker with Now / Learn / Escalation / Playbooks, sources, a "Draft guidance" label, and "Red-flag symptoms — contact now".
- **Quests:** "Level N", streaks, "… XP · cosmetic only".
- **Settings:** Environment; units; reminders; "Auto-pause simulator on escalation"; "Dev mode"; **Export all data (JSON)**; plus the dangerous buttons from §2.
- **About & method:** version, method, sources, "Roadmap: hardware (concept only)".

### 3.3 Automation deep links (Debug build only)

Run: `xcrun simctl openurl $UDID "crewhealth://<host>/<path>?<query>"`

If iOS shows an **"Open in …?" confirmation**, tap **Open**, and always do this **off-camera** (pause or trim). Wait about 1–3 s after each link before acting.

| Deep link | Effect |
|---|---|
| `crewhealth://demo?seed=42&speed=86400&scenario=full_mission` | Set up the simulated mission (seed 42), select its crew member, switch to **Body**, and **play** at 1 day/s |
| `crewhealth://sim/play` · `crewhealth://sim/pause` | Play / pause the mission |
| `crewhealth://sim/jump?day=N` | Jump forward to mission day N (jumps only forward) |
| `crewhealth://sim/restart` | Restart the mission from day 0 (off-camera only) |
| `crewhealth://sim/select` | Select the simulated crew member |
| `crewhealth://person/hk` | Select the Apple Health owner ("Me") |
| `crewhealth://hk/seed?days=30` | Write N days of **tagged synthetic** samples into the simulator's Health store. Requires Health permission to be granted first. Takes a few seconds |
| `crewhealth://hk/live/start` · `/live/stop` | Start/stop writing a synthetic heart-rate sample about every 10 s |
| `crewhealth://hk/sync` | Force a full Health sync now |
| `crewhealth://hk/delete-last` · `/delete-seeded` | Delete the last / all seeded samples (cleanup) |
| `crewhealth://radiation/connect` · `/disconnect` | Connect/disconnect the WebSocket bridge |
| `crewhealth://radiation/simulated` | Use the in-app simulated detector instead of the bridge |
| `crewhealth://debug/manual-bp?sys=121&dia=79` | Write a manual BP for "Me" (also saved to Health) |
| `crewhealth://debug/export` | Write summary.json/.html/.csv into the app's Documents folder. Find it with `xcrun simctl get_app_container $UDID org.spaceapps.crewhealthhub data` + `/Documents` |
| `crewhealth://tab/today` · `/body` · `/trends` · `/hazards` | Switch tab |

### 3.4 State model and gotchas
- **Two kinds of person:**
  - **"Me"**: the Apple Health owner, real-style data from the simulator's Health store.
  - **Simulated crew member(s)**: generated by the demo mission and labelled SIMULATED.
  - Switch with the Profile "Viewing" picker, or with `person/hk` / `sim/select`.
- **The live radiation bridge records for "Me"** (the Health owner), not for the simulated crew. For the bridge scene, select "Me" first.
  - The **simulated crew member** has its own scripted radiation event on **day 60**. That is the most reliable way to get the full-screen **RADIATION EVENT** escalation.
- **Escalations are per person and sticky.** Auto-pause on escalation is on by default, so the demo player shows "Paused for an alert".
- **Seeding Health needs permission first.** Order: Connect Apple Health → `hk/seed?days=30` → wait for the "Reading" counts to settle (or `hk/sync`).
- **Jumping only goes forward.** To go back, use `sim/restart` (off-camera), then jump.
- **Fresh state:** uninstall and reinstall the app.
  - This does **not** clear the simulator's Health store. Use `hk/delete-seeded` before uninstalling if you need clean Health data.
  - To fully wipe the simulator, use `xcrun simctl erase $UDID`, but only on a **non-default** simulator you booted yourself, and ask the user first.
- **The demo player minimises on scroll.** Scroll up a little before you need its buttons.
- **The body figure's region hit areas are drawn shapes.** Take a screenshot and tap the centre of the coloured region.
  - Heart: centre-left of the chest on the front view.
  - Brain: head. Lungs: upper chest, either side. Gut: abdomen. Eyes: face.
- **Animations:** the app uses springs and glass effects. Wait about 1 s after every navigation before taking a screenshot or recording a hold.

### 3.5 Radiation bridge
```bash
cd "$ROOT/bridge"
python3 bridge.py --driver simulated --backfill 40 --scenario spike --spike-after 120   # spike 120 s after launch
# options: --scenario background|spike  --spike-after <sec>  --backfill <minutes of past samples>  --hz 1  --verbose
```
- Run it in the background and keep the PID.
- It listens on `ws://127.0.0.1:8765`, which the simulator reaches directly.
- The protocol sends `hello`, `sample` (dose rate, CPS, CPM, cumulative dose) and `heartbeat`.
- To time the spike, start (or restart) the bridge so `--spike-after` lands inside your recording.
- In the app, select "Me", then Hazards → radiation card → **Connect a detector** → **Connect to bridge** (or `radiation/connect`).
- **Fallback:** **Use simulated radiation** → **Trigger test spike**.

---

## 4. DELIVERABLES (`$ROOT/demo/`)

| File | Spec |
|---|---|
| `out/crew-health-hub-film-16x9.mp4` | **Main film, about 2:20**, 1920×1080, 60 fps, H.264 High, yuv420p, about 16–20 Mbps, `+faststart`, silent AAC track |
| `out/crew-health-hub-film-16x9-4k.mp4` | 3840×2160 at 30 fps. Only if the 1080p render took under about 20 min; otherwise skip it and say so |
| `out/crew-health-hub-60s.mp4` | 60 s cut, 1080p60 |
| `out/crew-health-hub-teaser-9x16.mp4` | 30 s vertical teaser, 1080×1920 at 60 fps |
| `out/poster-16x9.png`, `out/poster-9x16.png` | Hero stills |
| `out/captions.srt` | All on-screen text (and VO, if any) |
| `out/voiceover-script.md` | Timed narration for a human presenter |
| `out/contact-sheet.png` | One frame every 2 s of the main film, tiled |
| `capture/` | `raw/`, `cfr/`, `shots/`, `taps.json`, `shotlist.md` |
| `film/` | Remotion project source, plus a README on how to re-render |
| `REPORT.md` | See §10 |

---

## 5. PHASE A: CAPTURE

### 5.1 Setup
1. Re-check the environment (§1). Build and install (§3.1). Open the live panel (`attach`). Apply the status bar override.
2. Create `demo/capture/{raw,cfr,shots}`.
3. **Dry run (not recorded).** Walk through every shot in §5.2.
   - Take screenshots and work out the tap coordinates. Write them to `capture/shotlist.md`.
   - Confirm each "Must capture" item exists. Note any "Open in…?" prompts.
4. **Reset for the real takes:** delete seeded Health data, then uninstall and reinstall.

### 5.2 Shot list

**How to shoot**
- **Each shot is its own clip. Record 2 takes, keep the best.**
- Hold **2 s still** at the start and end of every clip.
- Wait **1.2–1.5 s** between actions. Use slow swipes (≥ 0.8 s).
- Do deep links **off-camera** (before you start recording) unless noted.

| Clip | Start state (off-camera) | On-camera actions | Must capture |
|---|---|---|---|
| `A01-welcome` | Fresh install, app launched | Hold 4 s | Welcome title, tagline, 3 feature lines, both buttons |
| `A02-health-connect` | A01 | Tap **Connect Apple Health** → turn all on → **Allow** → Today appears | Permission sheet, then Today for "Me" |
| `A03-health-sync` | `hk/seed?days=30`, wait about 10 s, then `hk/sync` | Avatar → **Apple Health**. Hold, slow scroll through the counts | Per-type counts, "Live"/background state |
| `A04-live-hr` | On the Apple Health screen | Tap **Stream live heart rate**. Hold **25 s** (count increments about every 10 s). Tap **Stop live heart rate** | The heart-rate count increasing |
| `A05-today-me` | Close the sheets, Today tab | Hold, slow scroll top → bottom → top | Mission day, status hero, "Compared with your own normal", What changed, Next steps |
| `A06-checkin` | Today | **+** → Daily check-in → mood → **Continue** → one symptom once (mild) → **Continue** → **Log check-in** → **Done** | "How are you feeling?", "Takes about a minute", the 3 steps |
| `A07-manual-bp` | Today | **+** → Add a measurement → Indicator: blood pressure → 118 / 76, Activity: Rest → **Save** | "Also saved to Apple Health" |
| `A08-mission-play` | `crewhealth://demo?seed=42&speed=86400` (lands on Body, playing) | Hold 10 s | Demo player "Mission day N · Playing · 1 day/s", regions changing colour, SIMULATED label |
| `A09-body-heart` | `sim/jump?day=44`, `sim/pause`, Body tab, Front | Tap the **heart** region → hold on the sheet → slow scroll → drag closed → tap **Back**, hold → tap **Front** | Region level word + colour, reasons **with numbers**, What you can do, Measure now, See trend |
| `A10-trends` | Body → heart → **See trend** (or Trends → Chart options → All indicators → resting heart rate) | Hold. Change the range. Briefly toggle **Data table** on and off | The **personal baseline band** and the deviation |
| `A11-hazards` | Hazards tab (simulated person) | Hold, slow scroll | All 5 hazards with level words |
| `A12-radiation-event` | `sim/jump?day=59`, `sim/play` at 1 day/s, and **start recording just before day 60** | Let the event happen. The **full-screen RADIATION EVENT** appears and the player auto-pauses. Hold 5 s. Scroll the steps | "RADIATION EVENT", "Move to the shelter", µSv/h now, × background, elapsed, steps |
| `A13-acknowledge` | Continue from A12 | Tap **Contact flight surgeon** → OK → type a short note ("Reported to CAPCOM") → **I’ve reported this** | The sticky alert being acknowledged |
| `A14-radiation-detail` | After A13: Hazards → radiation card | Hold, slow scroll Dose → Events → During an event | Event row with peak and dose, the radiation-device honesty label |
| `A15-bridge-live` *(optional)* | `person/hk` (Me). Start the bridge with `--spike-after 45`. Hazards → radiation card → Connect a detector → **Connect to bridge** | Hold through the spike (about 60 s) | Live µSv/h rising, device label |
| `A16-guidance` | Avatar → Guidance | Now → Learn → Escalation → Playbooks | "Draft guidance, not yet reviewed", sources |
| `A17-quests` | Avatar → Quests | Hold | "XP · cosmetic only" |
| `A18-crew` | Avatar → Crew | Hold | Toggles off by default; the wording about never sharing health values |
| `A19-export` | Avatar → Share with flight surgeon | Period **30 days** → **Generate summary** → hold on the share rows → **Print / save as PDF** → hold on the preview → Cancel | The summary rows and the print preview of the summary |
| `A20-settings-about` | Avatar → Settings, then back → About | Slow scroll. **Don't tap anything dangerous** | Export all data, units, About & method |
| `A21-body-hero` | `sim/restart` off-camera → `sim/jump?day=10` → `sim/pause` → Body, Front | Hold 12 s with no interaction | A calm hero shot for the title and end card |
| `A22-ipad` *(optional)* | Boot "iPad Pro 13-inch (M5)", install the same build, `-demo` launch | Hold on Body and Today | The app on iPad. **Not** "Commander" (that isn't built) |

### 5.3 Recording
```bash
cd "$ROOT/demo/capture"
xcrun simctl io $UDID recordVideo --codec=h264 --force raw/A05-today-me_t1.mov &   # keep PID: REC=$!
# … perform the actions …
kill -INT $REC; wait $REC     # ALWAYS SIGINT, then wait, or the file is corrupt
```

**After each clip**
- Take **full-resolution screenshots** of the key moments: `xcrun simctl io $UDID screenshot shots/A05-02.png`. You need them for zoom focus rects and for checking numbers.
- Convert to constant 60 fps, because simulator video has a variable frame rate:
  ```bash
  ffmpeg -y -i raw/A05-today-me_t1.mov -vf "fps=60,format=yuv420p" -c:v libx264 -crf 14 -preset slow -an cfr/A05-today-me.mp4
  ```
- Check with `ffprobe` (resolution, fps, duration). Extract 3 frames and **look at them**. Re-shoot if any "Must capture" item is missing.

### 5.4 Tap log (`capture/taps.json`)
For every tap and swipe, record the wall-clock time you sent it, relative to when that clip's recording started:

```json
{"clip":"A09-body-heart","t":3.42,"type":"tap","x":150,"y":330,"unit":"pt","screen":{"wPt":402,"hPt":874}}
```

Swipes add `"x2","y2","duration"`. The film uses this log to draw tap ripples at the right time and place.

### 5.5 End of capture
- Run `hk/live/stop`, kill the bridge, and clear the status bar.
- Keep the app installed until the film is done, in case you need re-shoots.

---

## 6. PHASE B: DESIGN SYSTEM AND STORY

### 6.1 Colours (exact values from `UI/Components.swift`)

| Token | Hex | Use |
|---|---|---|
| bg | `#0B0F17` | Base background. Film backgrounds use a radial `#05070D → #0B0F17` |
| elev1 / elev2 | `#121826` / `#1A2234` | Cards in graphics |
| line | `#263048` | Hairlines |
| text | `#E8EDF7` | Headlines |
| dim | `#9AA6BF` | Sub-lines and labels |
| accent | `#5AC8FA` | Brand accent, data-flow lines, sweeps |
| warm | `#FFB347` | Secondary accent |
| ok / watch / act / escalate / unknown | `#3DDC97` / `#FFD166` / `#FF9F4A` / `#FF5D73` / `#7F8AA3` | Status colours |

- A status colour is never used without its word: OK / Watch / Act / Escalate.
- Text contrast must be at least 4.5:1.

### 6.2 Typography
- **Headlines:** SF Pro Display Semibold/Bold, 96–140 px at 1080p, tracking −2%, line-height 1.05. **At most 7 words.**
- **Sub-lines:** SF Pro Display Regular, 40–48 px, `dim` colour, at most 12 words.
- **Pills:** SF Pro Text Medium, 24–28 px, uppercase, +6% tracking.
- **Placement:** text goes in the left or right third, opposite the phone. Never over busy UI.
- **Reveal, per word:** opacity 0→1, translateY 24→0 px, blur 10→0 px, over 0.6 s, 70 ms stagger, ease `cubic-bezier(0.22,1,0.36,1)`.
- **Exit:** fade and move up 12 px over 0.35 s.
- **Hold:** at least 1.5 s after the reveal finishes.

### 6.3 Motion language
- **Springs** (Remotion `spring`): `{damping:200, stiffness:120, mass:1}`. Use one overshoot (`{damping:18, stiffness:90}`) only on the title.
- **Camera:** every shot has a slow push-in, scale 1.00→1.05. No dead-static frames.
- **Phone entrance:** rise 120 px with a fade-in, `rotateY −14°→−6°`, `rotateX 6°→2°`, `perspective 2400px`, then drift to 0°. Add a soft contact shadow underneath.
- **Zoom callout:**
  - The phone scales 1.0→2.2 around a focus point taken from a measured screenshot rect, while the rest dims to 40% with a vignette.
  - Optionally add a rounded "lens" card with a 1 px `accent` hairline.
  - In over 0.7 s with a spring, then hold, then out over 0.6 s.
- **Transitions** (at most 3 types in the whole film):
  - match cut with a 0.25 s screen crossfade
  - soft mask wipe over 0.5 s
  - push-through zoom into an element
- **Light sweep:** a diagonal (12°), 20%-wide white gradient at 8% opacity, crossing over 0.9 s. Use it only on the title, the first phone reveal and the end card.
- **Background:**
  - Seeded starfield: 200–300 points at 0.2–0.6 opacity, drifting 4 px/s, with about 5% twinkling.
  - A soft `accent` glow behind the phone at 6–10% opacity.
- **Tap ripple:** at each `taps.json` point, a ring growing 0→56 px (2 px white at 70%, fading out) over 0.45 s, plus a 14 px dot at 50% fading over 0.25 s.
- **Numbers in graphics must equal the footage value** at that moment. Read it from your screenshot.
- **Restraint:** one moving idea at a time, and at least 0.5 s of stillness between beats.

### 6.4 Components (Remotion + TypeScript)

| Component | Notes |
|---|---|
| `Starfield`, `Glow` | Seeded (mulberry32, seed 42). Never use `Math.random()` |
| `PhoneFrame` | Code-drawn generic phone: body radius about 13% of width, 3-stop edge gradient `#3A3F4A → #8A8F99 → #2A2E36`, 1 px inner highlight, screen radius about 11.5%, black pill cutout. The screen aspect ratio must **exactly** match the clip (`ffprobe`). Never stretch |
| `ScreenClip` | `OffthreadVideo` with `startFrom`/`endAt` |
| `Headline`, `SubLine`, `Pill` | |
| `ZoomCallout`, `TapRipple`, `LightSweep` | |
| `LightTime` | Two glowing dots labelled "Earth" and "Mars", far apart, with an `accent` pulse and trail travelling between them |
| `DataFlow` | Dashed accent lines with travelling dots from two simple rounded-rectangle glyphs (a watch and a phone) into the phone. No product artwork |
| `HazardRings` | 5 ring segments around the phone, labelled with the hazard names, coloured by the **real** status in the footage, each with its level word |
| `DocFan` | 3 cards made from **real** export screenshots, fanning out of the phone |
| `EndCard` | `icon-1024.png` in a squircle with a shadow; "Crew Health Hub"; "Your own flight surgeon, when Earth is too far to call."; "Built for the NASA Space Apps Challenge 2026"; small "Decision support only. Not a medical device."; fade to black |

### 6.5 Storyboard: main film (about 2:20 at 60 fps). Use this text exactly

| # | Time | Visual & motion | On-screen text | Footage |
|---|---|---|---|---|
| 1 | 0:00–0:08 | Black → starfield. `LightTime`: a pulse crosses from Earth to Mars | "Mars is 3–22 light-minutes away." → "Each way." | — |
| 2 | 0:08–0:14 | The pulse fades, slow push on empty space | "Nobody can phone a flight surgeon." | — |
| 3 | 0:14–0:22 | App icon springs in with overshoot and a light sweep. Name reveals word by word | "Crew Health Hub" / sub: "Your own flight surgeon, when Earth is too far to call." | — |
| 4 | 0:22–0:32 | Phone entrance + sweep. A21 hero, then match cut to A05 Today | "Your health, at a glance." | A21, A05 |
| 5 | 0:32–0:46 | `DataFlow` into the phone. A03 counts → A04 live HR, with a **ZoomCallout** on the count ticking up. Pill "LIVE" | "Always in sync with Apple Health." / sub: "Not just once. Continuously." | A03, A04 |
| 6 | 0:46–0:58 | Push-through into Trends, **ZoomCallout** on the baseline band | "Compared with you." / sub: "Not a textbook." | A10 |
| 7 | 0:58–1:12 | A08 days advancing (≤2× ramp, banner readable), then A09 heart tap with a TapRipple and a ZoomCallout on the reasons. SIMULATED label stays in frame | "See what changed. And why." | A08, A09 |
| 8 | 1:12–1:20 | A06 at a gentle 1.5× ramp, 3 step dots in sync | "A one-minute daily check-in." | A06 |
| 9 | 1:20–1:30 | `HazardRings` around A11 | "Five hazards. One view." | A11 |
| 10 | 1:30–1:46 | Glow shifts `accent`→`escalate` over 1 s, slow concentric pulses. A12 alert, ZoomCallout on "µSv/h now" (value matches the footage) | "When it matters," → "it escalates." | A12 |
| 11 | 1:46–1:56 | A13 acknowledge with a TapRipple, glow back to `accent`, then A14 radiation detail with the device label | "Clear steps. Who to call." | A13, A14 |
| 12 | 1:56–2:04 | A19 export, `DocFan` of the real summary | "One page for the flight surgeon." | A19 |
| 13 | 2:04–2:10 | A18/A20 with a lock glyph drawn on | "Offline-first. Your data stays on your device." | A18, A20 |
| 14 | 2:10–2:15 | Three **real** crops slide in with a 120 ms stagger: the SIMULATED label, "Draft guidance, not yet reviewed" (A16), the radiation-device label (A14) | "Honest by design." | crops |
| 15 | 2:15–2:18 | Small `dim` typography under a "Next" pill. Nothing UI-like | "Next: habitat sensors · crew console · Mission Control" | — |
| 16 | 2:18–2:24 | `EndCard`, fade to black | §6.4 | — |

- **Optional:** if A22 was shot, add a 4 s iPad beat after beat 4 with the text "On iPhone and iPad."
- **60 s cut:** beats 1 (shortened to 5 s), 3, 5, 7, 10, 12, 14 and 16. Keep ≥1.5 s holds.
- **30 s vertical teaser (9:16):** beats 3 → 5 → 7 → 10 → 16. The phone fills about 80% of the height, text goes above and below it, headlines 110–130 px.
- **Voice-over script (`voiceover-script.md`):** one sentence per beat, reusing the on-screen line. Example: "Mars is three to twenty-two light-minutes away. Each way."

---

## 7. PHASE C: BUILD AND RENDER

1. **Ask once:** "OK to install Remotion via npm in `demo/film/` (pinned versions)?"
   - On yes, scaffold a TypeScript Remotion project with exact versions of `remotion`, `@remotion/cli`, `react`, `react-dom` and `typescript`. Pin to versions released ≥ 2 weeks ago.
   - Check the Remotion licence terms: it's free for individuals and small teams. Mention this in the report.
2. **Layout:**
   - `src/Root.tsx` with compositions `Main16x9` (1920×1080 @ 60), `Main4K` (3840×2160 @ 30), `Cut60` and `Teaser9x16` (1080×1920 @ 60).
   - `src/theme.ts` (tokens, springs, easing).
   - `src/components/*`
   - `src/beats/*`: one beat per file, each exporting its frame duration.
   - `src/data/taps.json` and `src/data/focus.json` (zoom focus rects in screen pixels).
   - `public/clips/*.mp4` (copies of `capture/cfr`), `public/shots/*.png`, `public/icon-1024.png`.
3. **Fonts:** load them with `@font-face` pointing at `local("SF Pro Display")` or the local `/Library/Fonts` paths. Hold rendering until the fonts load (`delayRender`/`continueRender`). Never copy the font files.
4. **Timeline:** use `<Series>` for beats and overlaps for transitions.
5. **Iterate with stills** before full renders:
   ```bash
   npx remotion still Main16x9 stills/b07.png --frame=<n>
   ```
   Open the PNG and check it.
6. **Render:**
   ```bash
   npx remotion render Main16x9 ../out/crew-health-hub-film-16x9.mp4 --codec=h264 --crf=16 --pixel-format=yuv420p
   npx remotion render Cut60 ../out/crew-health-hub-60s.mp4 --codec=h264 --crf=16
   npx remotion render Teaser9x16 ../out/crew-health-hub-teaser-9x16.mp4 --codec=h264 --crf=16
   ```
   Then for each output: `ffmpeg -i X.mp4 -c copy -movflags +faststart X.fs.mp4`, and replace the original.
7. **ffmpeg-only fallback** (if npm is declined):
   - Pre-render the background, stars and phone frame as PNGs with a small Python script.
   - Composite with `overlay`, push-ins with `zoompan`, text with `drawtext` (the SF Pro path and `alpha` fade expressions), and transitions with `xfade`.
   - Keep the same storyboard and text. Say in the report that springs and 3D tilt were simplified.

---

## 8. AUDIO
- **Default:** no music, and a silent stereo AAC 48 kHz track.
- **Music:** only a user-supplied track with a licence. Fade in over 1 s and out over 2 s, and normalise to −16 LUFS / −1 dBTP:
  ```bash
  ffmpeg -i in.mp4 -af loudnorm=I=-16:TP=-1:LRA=11 -c:v copy out.mp4
  ```
- **Voice-over:** the default is **none**. Only installed basic `say` voices exist, which sound robotic. If the user asks for TTS anyway, render each line separately, place it at beat start + 0.3 s, and **disclose it as synthetic** in the report.
- **Optional SFX:** soft UI ticks synthesised with ffmpeg `sine` plus an envelope, at −28 dBFS, synced to `taps.json`. No sampled sounds.

---

## 9. QA (all of this before reporting)
1. **Contact sheet:**
   ```bash
   ffmpeg -i out/crew-health-hub-film-16x9.mp4 -vf "fps=0.5,scale=480:-1,tile=6x8" -frames:v 1 out/contact-sheet.png
   ```
   **Open it**, then look at 10+ individual full-size frames.
2. **Every headline** matches §6.5 exactly, has no typos, and is held ≥ 1.5 s.
3. **Honesty labels:**
   - SIMULATED is visible in every beat that shows simulated data.
   - The radiation-device label appears in beat 11 or 14.
   - "Draft guidance" appears in beat 14.
   - The disclaimer is on the end card.
4. **Graphics match footage:** every number or level in graphics matches the footage. List each one in the report with its source screenshot.
5. **Clean frames:** no stretched footage, no UI clipped by the frame corners, status bar at 9:41 with full battery, and no Xcode, simulator chrome, desktop or personal data.
6. **Motion:** 60 fps confirmed with `ffprobe`, no jitter, at most 3 transition types.
7. **Brand safety:** no Apple logo, no NASA insignia (unless supplied and approved), no copyrighted music.
8. **Durations:**
   - main film 2:10–2:30
   - 60 s cut 55–65 s
   - teaser 28–32 s
   - all files play, with `+faststart` set
9. `captions.srt` covers every on-screen line.

---

## 10. REPORT (`demo/REPORT.md` + a short summary in chat)
- Output paths, durations, resolutions and file sizes, plus the beat list with timestamps.
- Tool versions: Xcode, simulator model and iOS, node, Remotion, ffmpeg. The Remotion licence note. TTS/music disclosure.
- Every graphic number or level, and its source screenshot.
- Re-shoots, failures, and anything left out, with reasons. For example:
  - background Health wake-ups can't be shown on the simulator
  - Dynamic Island / iPad Commander / hardware / AI aren't built, so they appear only in "Next"
- Any difference between this brief and the real UI.
- How to re-render: `cd "$ROOT/demo/film" && npx remotion render Main16x9 …`.

## 11. TROUBLESHOOTING
- **Build fails:** stop and report the last 30 lines of output. Don't edit app code.
- **Deep link does nothing:** you're probably on a Release build or the app isn't running. Launch it, wait 2 s, retry. If an "Open in…?" alert appeared, tap Open.
- **Health counts stay at 0:** permission wasn't granted. Go to Profile → Apple Health; if it shows a connect button, connect. Then `hk/seed`, then `hk/sync`.
- **No escalation at day 60:** make sure the simulated person is selected (`sim/select`), the mission is **playing** through day 60, and auto-pause is on (Settings). If needed, use the Demo options menu → Trigger now → **Radiation spike**.
- **The escalation won't go away:** tap "I’ve reported this". It is intentionally sticky.
- **The bridge won't connect:** check the bridge is running (`lsof -i :8765`), the URL field reads `ws://127.0.0.1:8765`, and "Me" is selected. Fall back to **Use simulated radiation**.
- **Corrupt video:** you stopped recording without SIGINT. Re-record.
- **Wrong taps:** re-take the screenshot and recompute coordinates in points (pixels ÷ 3 on Pro phones).
