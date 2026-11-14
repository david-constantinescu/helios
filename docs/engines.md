# Engines — formulas and thresholds

All engines are pure Swift (`ios/CrewHealthHub/Engine`) with no HealthKit/UIKit dependency, covered by XCTest.
Thresholds are **engineering defaults** in `reference_ranges.json → engine`, tunable in Settings, not clinical values.

## Ingest & QC (`Ingest.swift`)
1. Schema: known metric, finite value, valid timestamp. 2. Unit normalisation to canonical units (`UnitConversion`).
3. Sanity bounds (`sanityMin/Max`) → **rejected** (audit list, never used). 4. Suspect flags: SpO₂ < 80 %, systolic ≤
diastolic (paired by `pairId` or ±60 s), implausible jump (> 10 × `minSpread` within 60 s, baseline metrics only),
before mission start when history import is off. Suspect rows are shown but excluded from aggregates/baselines.
5. Dedupe key `sha1(person|metric|ts-second|round(value,3)|adapter)`, or `hk|<uuid>` for HealthKit, or
`hkstat|metric|day` (upserted) for daily statistics. 6. Timestamps > 5 min in the future are rejected.
7. Persist, mark `(person, metric, day)` dirty → debounced (250 ms) recompute.

## Aggregation (`Aggregate.swift`)
Per local day, OK-quality rows only. `sum` (steps, exercise, water), `mean` (BP, glucose), `median` (HR, HRV, SpO₂,
temps), `last` (self-report scales), `max` (symptoms). **Sleep**: union of asleep intervals (overlapping sources are
not double counted) attributed to the night ending that day (anything ending ≥ 18:00 counts for the next day); in-bed
and awake are excluded. **Resting HR**: device daily value; else 10th percentile of rest-context HR; else lowest 5-min
median between 00:00–06:00.

## Baseline (`BaselineStatus.swift`)
Window = the `windowDays` (21) days ending `baselineLagDays` (3) before the evaluated day, minus excluded days
(illness days for vitals). The lag stops a developing change from immediately absorbing itself into “normal”. If
fewer than 5 days fall in the lagged window, the most recent 21 days are used. `median`, `MAD`,
`spread = max(1.4826·MAD, minSpread)`. **Learning** until `nDays ≥ minLearningDays` (7; 14 for body mass).
**Stale** if no data for `staleDays` (10). Device change: if the newest source's median differs from earlier sources
by > 2 × spread, a note suggests restarting learning. A baseline can be **locked** (pre-mission baseline).

## Deviation, trend, status
`z = (x − median)/spread`; directional z uses `direction` (high / low / both). `x3` = 3-day rolling median.
Trend = Theil–Sen slope over the last 14 days (≥ 5 points); `slopeNorm = slope·7/spread`, counted only when moving
away from normal.
- `escalate`: directional z ≥ 4.5 **and** absolute band ≥ watch
- `act`: x3 directional z ≥ 3 for 3 consecutive entries, **or** slopeNorm ≥ 2.5 with z ≥ 2
- `watch`: directional z ≥ 2 for 2 consecutive entries, **or** slopeNorm ≥ 1.5 with z ≥ 1
- level = max(absolute band, baseline level); `alwaysEscalate` rules cannot be downgraded.
- Confidence: low if learning / < 7 days / simulated-only; high if ≥ 14 days and a single source; else medium.
- Reasons are sentences with numbers, baseline, persistence and slope.

## Roll-up
Region/hazard = worst contributor; a **low-confidence act is shown as watch** with a note; escalate is never
downgraded. Overall = worst region + counts of distinct issues. There is no numeric health score.

## Patterns
Rules in `guidance.json → patterns` (`all` / `anyOf` / `metric+dir+days` / `adherenceBelow`). A metric is “low/high
for N days” when its directional z ≥ watchZ for N trailing entries (or, while learning, its absolute band ≥ watch).
Fired patterns add a reason and raise covered regions/hazards to at least watch.

## Radiation (`Radiation.swift`)
Background = median of non-spike samples (needs ≥ 30 min span), spread = max(1.4826·MAD, 0.1·bg). EWMA (τ = 60 s) for
display. Spike = smoothed **and** raw ≥ max(bg + 5·spread, 3·bg) held ≥ 2 min; gaps > 10 min break a candidate.
Dose = trapezoid integration, gaps > 10 min recorded as unmonitored (not interpolated). Device counter resets are
detected and the app keeps accumulating. Budget % and projection (average daily dose × remaining days).
Status: active event → act (escalate if ≥ 50 × bg sustained), ≥ 10 × bg → act, ≥ 3 × bg → watch, event ended < 24 h →
watch, budget tiers 50/75/90 % → watch/act/escalate (only when a budget is set).

## Guidance
Lookup: pattern → metric × level (falls back escalate → act → watch) → region/hazard default → generic.
Only “what changed” is generated (from reasons); everything else is verbatim config text. act/escalate always include
when-to-escalate plus the configured contact. Unverified text is always tagged **Draft**. Top 3 actions are deduplicated.

## Scheduler & quests
Prompts derive from routines (+ environment overrides): done when any routine metric is measured between the start of
the day and the grace deadline; missed after it; explicit snooze/skip/done override. Adherence = done/(done+missed)
over 14 days. Quests: XP recomputed from history; exercise credit capped at 90 min/day; no credit for less sleep,
fasting or weight loss; daily XP withheld while an escalation is unacknowledged.

## Recompute
Ingest → dirty keys → 250 ms debounce → aggregate dirty days → evaluate all metrics (today and yesterday for “what
changed”) → symptoms → radiation → prompts → patterns → roll-up → guidance → quests → persisted statuses →
`hubSnapshotsChanged`. *Settings › Rebuild from raw data* re-aggregates everything.
