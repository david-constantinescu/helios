# Architecture

```
 Apple Health ──HKObserverQuery + background delivery──┐
   (anchored queries, statistics, deletions, write-back)│
 Radiation bridge (Python, ws://127.0.0.1:8765) ────────┤
 Manual entry / 60-s check-in ──────────────────────────┤──► Hub.submit ─► Ingest (QC, units, dedupe) ─► SQLite
 CSV / JSON / Apple Health export.xml (streaming SAX) ──┤                                                    │
 Mission simulator (seeded, same pipeline) ─────────────┘                    dirty days (debounce 250 ms) ◄──┘
                                                                                     │
                       Aggregate ─► Baseline ─► Status ─► Patterns ─► Roll-up ─► Guidance ─► Quests
                                                                                     │
                                                         PersonSnapshot ─► AppState (SwiftUI) ─► screens
```

- **iOS app** `ios/CrewHealthHub` — SwiftUI, Swift Charts, HealthKit, SQLite3, BackgroundTasks. No packages.
  - `Model/` core types, config loader (lenient JSON), unit conversion
  - `Store/` SQLite wrapper (thread-safe) and repository (observations, daily, docs, kv, export/delete)
  - `Engine/` pure engines + `Hub` orchestrator
  - `HealthKit/` catalog of types, continuous sync, writer, demo seeder
  - `Adapters/` simulator, importers, radiation bridge client
  - `UI/` screens and components; `App/` entry, app state, notifications
  - `Resources/config/*.json` every clinical number and sentence, with `source`/`verified`
- **Bridge** `bridge/` — asyncio + websockets server with simulated / Radiacode / GMC drivers.

Storage: `observations` (indexed by person/metric/ts, unique dedupe key, external id), `daily` aggregates, `docs`
(JSON documents: persons, missions, statuses, events, prompts, acks, badges, settings), `kv` (HealthKit anchors).
The database file uses `completeUntilFirstUserAuthentication` protection so HealthKit background deliveries can write
while the phone is locked, and is excluded from backups (local-only by design).
