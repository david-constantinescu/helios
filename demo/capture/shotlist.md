# Capture status
Captured (real, from the user's running simulator in Device Hub, iPhone 18 Pro HELIOS, iOS 27.2):
- shots/A05-today-day52-zoom.jpg : Today tab, "Friday - Mission day 52", "Keep an eye on / 2 changes, nothing urgent", What changed rows. Screen zoom of the Mac display (~746x1568), not a simctl full-res screenshot. Not tapped or modified.
Not captured: all clips A01-A22. Reason: computer_left_click / mouse_down / mouse_up on Device Hub fail ("Could not verify which document this window is editing"); Device Hub exposes no app windows/menu to the app_* tools; the VM cannot run xcrun simctl. Only read-only screenshots/zoom work.
To finish capture: run the brief's section 5 on the Mac with Bash + simctl (xcrun simctl io recordVideo, openurl deep links, taps via the iOS Simulator tool).

## Phase A status (2026-11-15, Sonnet session)
Captured (cfr/): A01-welcome (6 s hold, 1206x2622 @60), A08-mission-play (22 s, -demo launch: lands on Today day 44, NOT playing; not the Body/playing state the brief describes).
Shots: A01-welcome.png, A08-01..04.png.
NOT captured: A02-A07, A09-A22. Reason: no tool can tap/swipe in the simulator, and every crewhealth:// deep link raises an "Open in Helios?" prompt that needs a tap.
Tooling: ffmpeg needed DYLD_LIBRARY_PATH shim (libvpx.11 -> .12 symlink in scratchpad); recordVideo of a static screen yields ~1 frame, so pad with tpad=stop_mode=clone.
Brief vs screen: app is titled "Helios" (welcome), third feature line is "Stays on your iPhone and your Helios Hub", extra "Use my Health export file" button. Storyboard text says "Crew Health Hub".
