"""Simulated detector: Earth-background-like noise plus an optional illustrative spike (demo only)."""
from __future__ import annotations

import asyncio
import math
import random
from datetime import datetime, timezone
from typing import AsyncIterator, Dict, Any, Optional

from .base import Driver

BACKGROUND_USV_H = 0.10  # PLACEHOLDER background, illustrative only


def iso_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


class SimulatedDriver(Driver):
    name = "simulated"

    def __init__(self, hz: float = 1.0, scenario: str = "background", spike_after_s: float = 30.0,
                 seed: Optional[int] = 42, time_scale: float = 10.0):
        self.period = 1.0 / max(hz, 0.1)
        self.scenario = scenario
        self.spike_after_s = spike_after_s
        self.time_scale = time_scale  # 1 real second = time_scale event seconds during a spike
        self.rng = random.Random(seed)
        self.cum = 0.0
        self._t0 = 0.0
        self._closed = False

    async def open(self) -> Dict[str, Any]:
        self._t0 = asyncio.get_event_loop().time()
        return {"device": "Simulated detector", "serial": "SIM-0001"}

    def rate_at(self, elapsed_s: float) -> float:
        r = BACKGROUND_USV_H + self.rng.gauss(0, 0.006)
        if self.scenario == "spike" and elapsed_s >= self.spike_after_s:
            dt_min = (elapsed_s - self.spike_after_s) * self.time_scale / 60.0
            peak = BACKGROUND_USV_H * 80
            r += peak * dt_min / 20 if dt_min < 20 else peak * math.exp(-(dt_min - 20) / 120)
        return max(0.001, r)

    def backfill(self, minutes: float):
        """Past background samples (every 10 s) ending now — clearly simulated, for demos only."""
        from datetime import timedelta
        now = datetime.now(timezone.utc)
        n = int(minutes * 6)
        for i in range(n, 0, -1):
            ts = now - timedelta(seconds=10 * i)
            rate = max(0.001, BACKGROUND_USV_H + self.rng.gauss(0, 0.006))
            yield {"ts": ts.isoformat(timespec="seconds").replace("+00:00", "Z"), "dose_rate_uSv_h": round(rate, 4),
                   "count_rate_cpm": round(rate * 180, 1), "quality": "ok"}

    async def samples(self) -> AsyncIterator[Dict[str, Any]]:
        loop = asyncio.get_event_loop()
        while not self._closed:
            elapsed = loop.time() - self._t0
            rate = self.rate_at(elapsed)
            self.cum += rate * self.period / 3600.0
            cps = max(0.0, rate * 3.0 + self.rng.gauss(0, 0.3))  # illustrative counts, NOT a calibration
            yield {"ts": iso_now(), "dose_rate_uSv_h": round(rate, 4), "count_rate_cps": round(cps, 2),
                   "count_rate_cpm": round(cps * 60, 1), "dose_cum_uSv": round(self.cum, 4), "battery": 1.0, "quality": "ok"}
            await asyncio.sleep(self.period)

    async def close(self) -> None:
        self._closed = True
