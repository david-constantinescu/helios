# Crew Health Hub film (Remotion project)

Status: pipeline built and type-checked; stills rendered in a Linux VM. No simulator footage exists yet,
so beats that need footage show a clearly labelled "No footage captured (Axx)" screen. Do not ship a render until clips exist.

Pinned: remotion / @remotion/cli 4.0.538 (released 2026-10-22), react 18.3.1, typescript 5.6.3.
Remotion licence: free for individuals and small teams; check https://remotion.pro/license for your use.

## Add footage
1. Record clips per the brief (capture-film-prompt.md section 5) and convert to CFR 60 fps into ../capture/cfr/ named `A05-today-me.mp4` etc.
2. `mkdir -p public/clips public/shots && cp ../capture/cfr/*.mp4 public/clips/ && cp ../capture/shots/*.png public/shots/`
3. `cp "<root>/ios/CrewHealthHub/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png" public/icon-1024.png`
4. `npm install && npm run scan` (maps A01..A22 prefixes to files in src/data/footage.json)
5. Fill src/data/taps.json (tap log) and src/data/focus.json (zoom rects) from ../capture/taps.json. (TapRipple, ZoomCallout, DataFlow, HazardRings, DocFan not yet implemented: see TODO below.)

## Render (on the Mac, where SF Pro is installed in /Library/Fonts; fonts are loaded via local() and never copied)
    npx remotion still src/index.ts Main16x9 stills/b04.png --frame=1500
    npx remotion render src/index.ts Main16x9 ../out/crew-health-hub-film-16x9.mp4 --codec=h264 --crf=16 --pixel-format=yuv420p
    npx remotion render src/index.ts Cut60 ../out/crew-health-hub-60s.mp4 --codec=h264 --crf=16
    npx remotion render src/index.ts Teaser9x16 ../out/crew-health-hub-teaser-9x16.mp4 --codec=h264 --crf=16
    # 4K 30 fps: add --scale=2 --every-nth-frame=2 to the Main16x9 command
    # then per file: ffmpeg -i X.mp4 -f lavfi -i anullsrc=r=48000:cl=stereo -shortest -c:v copy -c:a aac -movflags +faststart X.fs.mp4
    npm run captions     # regenerates ../out/captions.srt from src/storyboard.ts

## Implemented
Starfield (mulberry32 seed 42), Glow, Words (per-word reveal), PhoneFrame (code-drawn, 402:874 screen), LightTime, EndCard,
storyboard.ts (exact section 6.5 text, 16 beats, Cut60 and Teaser plans), phone entrance + push-in.
## TODO (not built)
TapRipple, ZoomCallout, LightSweep, DataFlow, HazardRings, DocFan, lock glyph, crops beat, SIMULATED/label overlays, beat transitions, iPad beat.
