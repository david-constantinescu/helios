# Capture status
Captured (real, from the user's running simulator in Device Hub, iPhone 18 Pro HELIOS, iOS 27.2):
- shots/A05-today-day52-zoom.jpg : Today tab, "Friday - Mission day 52", "Keep an eye on / 2 changes, nothing urgent", What changed rows. Screen zoom of the Mac display (~746x1568), not a simctl full-res screenshot. Not tapped or modified.
Not captured: all clips A01-A22. Reason: computer_left_click / mouse_down / mouse_up on Device Hub fail ("Could not verify which document this window is editing"); Device Hub exposes no app windows/menu to the app_* tools; the VM cannot run xcrun simctl. Only read-only screenshots/zoom work.
To finish capture: run the brief's section 5 on the Mac with Bash + simctl (xcrun simctl io recordVideo, openurl deep links, taps via the iOS Simulator tool).
