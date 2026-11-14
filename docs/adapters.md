# Adapters — how data gets in

Every adapter produces `RawObservation`s and calls `Hub.shared.submit(_:)`. Nothing bypasses the engines.

```swift
RawObservation(personId:, missionId:, ts:, metric:, value:, unit:,
               source: SourceInfo(adapter: "my_adapter", device: "Model X", kind: .device),
               context: ObsContext(...), importBatchId: nil, externalId: nil, dedupeKey: nil)
```

- Use `kind: .simulated` for anything synthetic (drives the SIMULATED badge and low confidence).
- Provide `externalId` + `dedupeKey` when the source has stable ids (enables deletion sync, idempotent re-import).
- Use `upsert: true` + `stableId` for values that change in place (e.g. daily totals).
- After deleting rows call `Hub.shared.removed(rows)` so affected days are re-aggregated.

| Adapter | File | Notes |
|---|---|---|
| Apple Health (continuous) | `HealthKit/HealthSync.swift` | Anchored + observer + background delivery + statistics; write-back via `HealthWriter`. |
| Manual / check-in | `Adapters/Importers.swift` (`ManualEntry`), `UI/CheckInView.swift` | Writes to Health first for the Health owner. |
| CSV / TSV / JSON | `Adapters/Importers.swift` (`CSVParser`, `CSVImporter`) | Auto-detect, wide/long mapping, presets, preview, undo by batch. |
| Apple Health export.xml | `AppleHealthXMLImporter` | Streaming `XMLParser`, external entities never resolved, HR downsampled to 5-min medians. For a `.zip`, expand it in Files first. |
| Radiation bridge | `Adapters/RadiationBridge.swift` + `bridge/` | WebSocket, backoff 1→30 s, 5-s heartbeat, minute medians persisted, simulated fallback. |
| Simulator | `Adapters/MissionSimulator.swift` | Seedable mulberry32 PRNG, AR(1) noise, storyline scenarios. |
| Google Health / Fitbit cloud | — | Not built (access restrictions; TODO(verify)). Use the Fitbit export preset. |
| Web Serial GMC | — | Browser-only API; on iOS use the bridge. |

**Roadmap (documentation only):** third-party iOS apps can export Health data on a schedule; with native HealthKit sync
this is unnecessary for the app itself but could feed a ground-side summary.
