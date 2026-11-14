# Roadmap: hardware — “Helios Station” (concept only, not built)

A compact, modular station for a habitat or rover that bundles the measurements the software already understands.
It would start from proven commercial medical-grade sensors; flight qualification is a separate, later programme.
Every module would plug in through the existing adapter layer without redesign.

**Modules:** compute hub (SBC + touchscreen running the software and bridge, encrypted storage) · vitals bay (BLE/USB
BP cuff, pulse oximeter, thermometer, glucometer) · personal dosimetry dock · wearable dock/relay (no cloud) ·
environment node (CO₂, temperature, humidity, pressure) · crew ID & feedback (NFC badges, light bar, gentle prompts).

**Data flow:** sensors → module adapters → hub (normalised observations) → on-device engines → touchscreen UI →
flight-surgeon summary over the mission link when available.

**Flight-version principles:** offline-first and fail-safe; radiation tolerance (ECC, watchdogs, redundant storage);
low power/heat, no loose parts, habitat-safe materials; glove- and microgravity-friendly; per-person consent.

**Phases:** now — software + adapters, simulated data, one real radiation-device demo · next — vitals bay with
commercial BLE devices, wearable docks · later — flight-constraint engineering, independent validation, collaboration
with space-medicine experts.
