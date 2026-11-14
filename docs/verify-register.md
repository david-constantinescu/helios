# Verify register

Every item below is a stand-in that must be checked by a human against an official source before the app is used for
anything beyond a demo. Nothing here is clinical truth. Status: **open** unless marked otherwise.

| # | Item | Where | Owner | Status | Source to check |
|---|---|---|---|---|---|
| a1 | All metric `howToMeasure`, `whyItMatters` text and `source` fields | `ios/CrewHealthHub/Resources/config/metrics.json` | Medical reviewer | open | NASA / flight-surgeon material |
| a2 | Reference range bands (resting HR, BP, SpO₂, temperature, glucose, sleep, resp. rate, mood/stress, cabin CO₂/temp) | `reference_ranges.json → ranges` | Medical reviewer | open | NASA / medical guidelines |
| a3 | `alwaysEscalate` rules (red-flag symptoms, SpO₂ < 88, temp > 40, glucose < 54) | `reference_ranges.json` | Medical reviewer | open | Flight-surgeon procedures |
| a4 | Symptom severity → level mapping | `reference_ranges.json → symptomLevels` | Medical reviewer | open | — |
| a5 | Every guidance block (metrics, regions, hazards, patterns, playbooks, escalation page, red-flag list) | `guidance.json` | Medical reviewer | open | NASA HRP, mission procedures |
| a6 | Region function text | `regions.json` | Medical reviewer | open | NASA HRP |
| a7 | Routine cadences and environment overrides | `routines.json`, `environments.json` | Mission ops | open | Mission plan |
| a8 | Engine thresholds (watchZ 2, actZ 3, escalateZ 4.5, persistence, trend, window 21, lag 3, learning 7) — engineering defaults | `reference_ranges.json → engine` | Data science | open | Tuning with real data |
| b | Apple Health record identifiers and units (export.xml mapping and HealthKit types) | `HealthKit/HealthTypes.swift`, `Adapters/Importers.swift` | iOS dev | open | Real device export (iOS 17/18) |
| b2 | Sleeping wrist temperature is absolute °C (Health app shows deviation) | `HealthTypes.swift` | iOS dev | open | HealthKit docs |
| b3 | State of Mind valence → mood 1–5 mapping (3 + 2·valence) | `HealthSync.convert` | Behavioural health | open | — |
| c1 | Glucose factor 18.016 mg/dL per mmol/L | `Model/UnitConversion.swift` | Medical reviewer | open | Lab standard |
| c2 | µR/h → µSv/h ≈ 0.01 (approximate, radiation-type dependent) | `UnitConversion.swift` | Radiation | open | Device / health-physics reference |
| d | Radiacode `dose_rate` units and scale (`DOSE_RATE_TO_USV_H = 1.0` placeholder) | `bridge/drivers/radiacode_driver.py` | Hardware | open | radiacode library docs + device screen |
| e | GMC protocol variant, baud and firmware quirks for the specific unit; CPM→µSv/h only via user calibration | `bridge/drivers/gmc_driver.py` | Hardware | open | GQ-RFC1201, pygmc docs |
| f | Fitbit Web API retirement timeline and Google Health API access status | `SourcesView` copy, `README` | PM | open | developers.google.com/health |
| g | CSA radiation-monitoring explainer wording | `radiation.json → explainer` | Radiation | open | CSA “Monitoring Radiation for Astronaut Health” |
| h | Five-hazard explainers, related risks, countermeasures | `hazards.json` | Medical reviewer | open | NASA HRP Five Hazards |
| i | Mission dose budget / limits and alert tiers (50/75/90 % and ×3/×10/×50 background) | `radiation.json`, Settings | Radiation | open | Official agency guidance |
| j | Simulated radiation background (0.10 µSv/h) and spike shape (×80, 20-min ramp, 2-h decay) — illustrative | `MissionSimulator.swift`, `bridge/drivers/simulated_driver.py` | — | by design (labelled simulated) | — |
| k | Fitbit export column names for the `fitbit-export` preset | `Importers.swift` | iOS dev | open | Real Fitbit export |
