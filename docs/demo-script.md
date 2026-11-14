# Demo script (~90 s)

Prep: build & run on the simulator; onboarding with *Apple Health* and *Simulated mission* on. In *More › Apple Health
sync › Demo tools* tap **Seed 30 days**. Start `python bridge/bridge.py --driver simulated --backfill 40 --scenario
spike --spike-after 120` (or a real detector).

1. **0:00** “Mars is 3–22 light-minutes away each way. Nobody can phone a flight surgeon.” Body tab: figure, colours.
2. **0:15** “It plugs into what people already wear.” *Apple Health sync*: live log, per-type counts, background
   delivery bells; start the live writer and watch heart-rate samples arrive within seconds.
3. **0:30** Switch to the simulated crew member, *Play* at 1 day/s: sleep amber (~day 25) → heart & brain amber
   (~day 40). Tap the heart: reasons with numbers, actions, how to measure.
4. **0:55** Radiation: bridge connected (honesty label). The spike turns radiation red; the escalation sheet is sticky
   until “I've reported this”; the playbook opens; the dose is logged. (The simulator auto-pauses at day 60 too.)
5. **1:15** *More › Flight-surgeon export* → generate → share the HTML/JSON/CSV, or print to PDF.
6. **1:25** “Offline-first, data stays on the device, any sensor plugs in through an adapter.”

Pitch lines: “Compares you with *you*, not a textbook.” / “Honest by design: we label what's simulated, what's a demo
sensor, and what's draft guidance.”
