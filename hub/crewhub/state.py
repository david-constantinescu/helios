"""Live hub state shared by the serial link, the server and the display."""
from __future__ import annotations

import statistics
import time
from collections import deque
from dataclasses import dataclass, field
from typing import Any, Deque, Dict, List, Optional, Set, Tuple

from . import environment as env
from .protocol import SCENARIO_LABELS, Frame
from .store import Store


@dataclass
class Alert:
    key: str
    text: str
    level: int
    source: str              # "habitat" | "person"
    person: Optional[str] = None


@dataclass
class Client:
    id: int
    name: str
    since: float = field(default_factory=time.time)


class HubState:
    def __init__(self, store: Store, name: str = "Helios Hub"):
        self.store = store
        self.name = name
        self.started = time.time()
        # Habitat sensors
        self.latest: Dict[str, float] = {}
        self.latest_ts: Optional[float] = None
        self.levels: Dict[str, int] = {}
        self.recent: Deque[Tuple[float, Dict[str, float]]] = deque(maxlen=3600)   # last hour at 1 Hz
        self._minute: Optional[int] = None
        self._acc: Dict[str, List[float]] = {}
        self.background: Optional[float] = None
        self.scenario = "normal"
        self.cum_dose = float(store.get("cum_dose_uSv", "0") or 0)
        # Uno link
        self.uno_connected = False
        self.uno_version: Optional[str] = None
        self.uno_port: Optional[str] = None
        # Phones and people
        self.clients: Dict[int, Client] = {}
        self.snapshots: Dict[str, Dict[str, Any]] = store.snapshots()
        self.current_person: Optional[str] = store.get("current_person")
        self.muted: Set[str] = set()          # habitat alerts acknowledged on the hub (until the level changes)
        self.version = 0                      # bumps on every change the display should show
        self.jump_to_alerts = False           # a new alert arrived: the display should show it
        self.new_alerts: List[Alert] = []     # person alerts not yet pushed to subscribed devices

    def touch(self) -> None:
        self.version += 1

    # --- habitat sensor frames ---------------------------------------------------------------------------------
    def on_frame(self, f: Frame, ts: Optional[float] = None) -> List[Alert]:
        """Stores a frame, updates levels and returns alerts that just became active."""
        ts = ts or time.time()
        prev = {a.key for a in self.habitat_alerts()}
        self.latest.update(f.values)
        self.latest_ts = ts
        self.scenario = f.scenario
        self.recent.append((ts, dict(f.values)))
        rate = f.values.get("rad_dose_rate")
        if rate is not None:
            self.cum_dose += rate / 3600.0           # 1 s frames: µSv/h × h
            self._update_background()
        for k, v in f.values.items():
            self.levels[k] = env.level(k, v, self.background)
        minute = int(ts // 60)
        if self._minute is not None and minute != self._minute:
            self.flush_minute()
        self._minute = minute
        for k, v in f.values.items():
            self._acc.setdefault(k, []).append(v)
        active = {a.key for a in self.habitat_alerts(include_muted=True)}
        for key in list(self.muted):                 # a habitat mute lasts only while that alert stays at the same level
            if key.startswith("habitat:") and key not in active:
                self.muted.discard(key)
        self.touch()
        return [a for a in self.habitat_alerts() if a.key not in prev]

    def _update_background(self) -> None:
        # Background = median of the lower half of the last 30 minutes (robust to an ongoing spike); needs 2 minutes.
        rates = [v["rad_dose_rate"] for _, v in list(self.recent)[-1800:] if "rad_dose_rate" in v]
        if len(rates) < 120:
            return
        low = sorted(rates)[: max(1, len(rates) // 2)]
        bg = statistics.median(low)
        self.background = bg if self.background is None else min(self.background * 1.01 + 0.0001, bg) if bg > self.background else bg

    def flush_minute(self) -> None:
        if self._minute is None or not self._acc:
            return
        stats = {k: (sum(v) / len(v), min(v), max(v), len(v)) for k, v in self._acc.items() if v}
        self.store.add_env_minute(self._minute * 60, stats)
        self.store.set("cum_dose_uSv", f"{self.cum_dose:.4f}")
        self._acc = {}

    def series(self, sensor: str, seconds: int = 1800) -> List[float]:
        """Recent values for a sparkline: 1 Hz for the last few minutes, minute means further back."""
        now = time.time()
        live = [v[sensor] for t, v in self.recent if sensor in v and t >= now - seconds]
        if len(live) >= min(seconds, 300) * 0.5 or seconds <= 3600:
            return live
        return [m for _, m in self.store.env_history(sensor, now - seconds)]

    def ratio(self) -> Optional[float]:
        r = self.latest.get("rad_dose_rate")
        return r / self.background if r is not None and self.background else None

    # --- alerts ------------------------------------------------------------------------------------------------
    def habitat_alerts(self, include_muted: bool = False) -> List[Alert]:
        out = []
        for k, lvl in self.levels.items():
            if lvl < 2:
                continue
            key = f"habitat:{k}:{lvl}"
            if not include_muted and key in self.muted:
                continue
            s = env.SENSORS.get(k)
            label = s.label if s else k
            if k == "rad_dose_rate" and self.ratio():
                text = f"{label} {self.ratio():.0f}x background"
            else:
                text = f"{label} {env.fmt(k, self.latest.get(k))}"
            out.append(Alert(key, text, lvl, "habitat"))
        return out

    def person_alerts(self) -> List[Alert]:
        out = []
        for pkey, snap in self.snapshots.items():
            name = (snap.get("person") or {}).get("name", "Crew")
            for a in snap.get("alerts") or []:
                key = f"person:{pkey}:{a.get('key')}"
                if key not in self.muted:
                    out.append(Alert(key, f"{name}: {a.get('text', '')}", 3, "person", pkey))
        return out

    def alerts(self) -> List[Alert]:
        return sorted(self.habitat_alerts() + self.person_alerts(), key=lambda a: -a.level)

    def mute(self, key: str) -> None:
        self.muted.add(key)
        self.store.log_event("ack", key)
        self.touch()

    # --- people ------------------------------------------------------------------------------------------------
    def set_snapshot(self, person_key: str, snap: Dict[str, Any], current: bool) -> None:
        before = {a.key for a in self.person_alerts()}
        self.snapshots[person_key] = snap
        fresh = [a for a in self.person_alerts() if a.key not in before]
        if fresh:
            self.jump_to_alerts = True
            self.new_alerts.extend(fresh)
        self.store.put_snapshot(person_key, snap)
        if current or self.current_person not in self.snapshots:
            self.select(person_key)
        self.touch()

    def select(self, person_key: str) -> None:
        if person_key in self.snapshots:
            self.current_person = person_key
            self.store.set("current_person", person_key)
            self.touch()

    def person(self) -> Optional[Dict[str, Any]]:
        if self.current_person in self.snapshots:
            return self.snapshots[self.current_person]
        return next(iter(self.snapshots.values()), None)

    def overall_level(self) -> int:
        """Worst of the person's overall status and the habitat."""
        p = self.person()
        pl = int((p or {}).get("overall", {}).get("level", 0) or 0)
        hl = max([lvl for lvl in self.levels.values()] + [0])
        return max(pl, hl, 3 if self.person_alerts() else 0)

    def scenario_label(self) -> str:
        return SCENARIO_LABELS.get(self.scenario, self.scenario)

    def env_payload(self) -> Dict[str, Any]:
        return {
            "type": "env", "ts": iso(self.latest_ts or time.time()), "values": self.latest,
            "levels": {k: env.LEVEL_IDS[v] for k, v in self.levels.items()},
            "background_uSv_h": self.background, "dose_cum_uSv": round(self.cum_dose, 4),
            "scenario": self.scenario, "uno": {"connected": self.uno_connected, "version": self.uno_version},
        }


def iso(ts: float) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ts))
