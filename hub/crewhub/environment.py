"""Habitat sensor definitions and status levels.

Levels: 0 OK, 1 Watch, 2 Act, 3 Call (escalate) — the same scale the app uses.
Bands are the hub's defaults for a station-like habitat; override them in /etc/crewhub/config.json ("sensors").
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple

LEVEL_NAMES = ["OK", "WATCH", "ACT", "CALL"]
LEVEL_IDS = ["ok", "watch", "act", "escalate"]


@dataclass
class Sensor:
    id: str
    label: str
    short: str
    unit: str
    decimals: int
    # Each band: (level, low, high) — the value is at that level when outside [low, high]. Checked from the highest level down.
    bands: List[Tuple[int, Optional[float], Optional[float]]]


SENSORS: Dict[str, Sensor] = {s.id: s for s in [
    Sensor("cabin_temp", "Cabin temperature", "Temp", "°C", 1, [(3, 10, 35), (2, 16, 29), (1, 18.3, 26.7)]),
    Sensor("humidity", "Humidity", "Humid", "%", 0, [(2, 15, 85), (1, 25, 70)]),
    Sensor("pressure", "Cabin pressure", "Press", "kPa", 1, [(3, 90, None), (2, 95, None), (1, 97.9, 103)]),
    Sensor("co2", "Carbon dioxide", "CO2", "ppm", 0, [(3, None, 5300), (2, None, 4000), (1, None, 2600)]),
    Sensor("o2", "Oxygen", "O2", "%", 1, [(3, 16, 25), (2, 18, 24), (1, 19.5, 23.5)]),
    Sensor("noise", "Noise", "Noise", "dB", 0, [(2, None, 75), (1, None, 65)]),
    Sensor("light", "Light", "Light", "lux", 0, []),
    Sensor("rad_dose_rate", "Radiation dose rate", "Rad", "µSv/h", 3, []),
    Sensor("rad_cpm", "Radiation counts", "CPM", "CPM", 0, []),
]}

# Radiation is judged against the learned background, like the app: ×3 watch, ×10 act, ×50 call.
RAD_FACTORS = [(3, 50.0), (2, 10.0), (1, 3.0)]


def apply_overrides(cfg: dict) -> None:
    for sid, bands in (cfg.get("sensors") or {}).items():
        if sid in SENSORS and isinstance(bands, list):
            SENSORS[sid].bands = [(int(b[0]), b[1], b[2]) for b in bands]


def level(sensor_id: str, value: Optional[float], background: Optional[float] = None) -> int:
    if value is None:
        return 0
    if sensor_id == "rad_dose_rate":
        if not background or background <= 0:
            return 0
        ratio = value / background
        for lvl, factor in RAD_FACTORS:
            if ratio >= factor:
                return lvl
        return 0
    s = SENSORS.get(sensor_id)
    if not s:
        return 0
    for lvl, lo, hi in sorted(s.bands, key=lambda b: -b[0]):
        if (lo is not None and value < lo) or (hi is not None and value > hi):
            return lvl
    return 0


def fmt(sensor_id: str, value: Optional[float], unit: bool = True) -> str:
    if value is None:
        return "--"
    s = SENSORS.get(sensor_id)
    d = s.decimals if s else 1
    text = f"{value:.{d}f}"
    return f"{text} {s.unit}" if unit and s else text
