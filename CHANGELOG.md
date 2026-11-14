# Changelog

## 1.0.0 — 2026-11-14
- Native iOS app (SwiftUI) replacing the PWA plan so Apple Health can be read and kept in sync continuously.
- Continuous two-way Apple Health sync: anchored queries with persisted anchors, deletions, observer queries with
  background delivery, statistics for steps/exercise, foreground and BGAppRefresh re-sync, write-back.
- Engines: ingest/QC/dedupe, aggregation, baselines, deviation/trend, status, patterns, roll-up, radiation, guidance,
  scheduler, quests. 38 unit tests.
- Screens: onboarding, Today, Body map, Trends, Hazards, Check-in, Manual entry, Guidance, Quests, Sources, Apple
  Health sync, Simulator, Import, Radiation sensor, Crew, Export, Settings, About.
- Python radiation bridge (simulated / Radiacode / GMC drivers) with Origin + token checks; 5 tests.
