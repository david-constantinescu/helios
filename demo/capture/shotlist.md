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

## Update (Device Hub session)
Captured in cfr/: A01, A02 (Health permission flow), A03 (Data types counts), A04 (live HR 1,261->1,264), A05 (Today, "Me"). A06 retake pending (earlier takes ended on the "Logged" screen).
Input route: synthesized clicks at screen coords onto the Device Hub window (works only while it is the topmost window). Calibration: screen_pt = (1295 + x*0.933, 152.5 + y*0.933) for device pt (x,y). Posting events to the Device Hub pid/window while it is behind other windows does nothing. AXe v1.8.0 reports success but has no effect on iOS 27.2 (times out creating its automation session).
UI differences vs brief: profile -> Data -> Advanced -> "Data types and sync log" holds per-type counts; "Stream live heart rate" is under Advanced; "Me" has no mission day; check-in has Stress/Workload sliders, step 3 reads "Due today"; every crewhealth:// link needs the Open button tapped at (275,474) pt.
Remaining: A06 retake, A07, A09-A21 (A15, A22 optional).
