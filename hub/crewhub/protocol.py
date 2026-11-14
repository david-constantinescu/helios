"""Line protocol spoken by the Arduino Uno sensor node (see arduino/crew_sensors/crew_sensors.ino).

Uno → hub, one message per line:
    H,crew-sensors,<version>,<keys…>      hello
    S,<seq>,k=v,k=v,…                     sensor frame
    J,<L|R|U|D|P|H>                       joystick event
    A,<command>,ok|err                    reply to a command
Hub → Uno:
    C,hello | C,ping | C,scenario,<name> | C,rate,<ms>
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, List, Optional, Union

# Uno field → hub sensor id.
KEYS: Dict[str, str] = {
    "t": "cabin_temp", "rh": "humidity", "p": "pressure", "co2": "co2", "o2": "o2",
    "db": "noise", "lux": "light", "rad": "rad_dose_rate", "cpm": "rad_cpm",
}
SCENARIOS: List[str] = ["normal", "co2", "spike", "leak", "heat", "noise"]
SCENARIO_LABELS: Dict[str, str] = {
    "normal": "Normal day", "co2": "CO2 scrubber fault", "spike": "Radiation spike",
    "leak": "Pressure leak", "heat": "Cooling failure", "noise": "Loud fan",
}
JOY_KEYS = {"L", "R", "U", "D", "P", "H"}


@dataclass
class Hello:
    version: str
    keys: List[str] = field(default_factory=list)


@dataclass
class Frame:
    seq: int
    values: Dict[str, float]
    scenario: str = "normal"


@dataclass
class Joy:
    key: str


@dataclass
class Reply:
    command: str
    ok: bool


Message = Union[Hello, Frame, Joy, Reply]


def parse_line(raw: Union[bytes, str]) -> Optional[Message]:
    """Parses one line from the Uno. Returns None for anything malformed (boot noise, half lines, garbage)."""
    if isinstance(raw, bytes):
        raw = raw.decode("ascii", errors="replace")
    line = raw.strip()
    if len(line) < 3 or line[1] != ",":
        return None
    kind, rest = line[0], line[2:]
    parts = rest.split(",")
    if kind == "H":
        if len(parts) < 2 or parts[0] != "crew-sensors":
            return None
        return Hello(version=parts[1], keys=parts[2:])
    if kind == "J":
        return Joy(parts[0]) if parts[0] in JOY_KEYS else None
    if kind == "A":
        if len(parts) != 2 or parts[1] not in ("ok", "err"):
            return None
        return Reply(parts[0], parts[1] == "ok")
    if kind == "S":
        try:
            seq = int(parts[0])
        except ValueError:
            return None
        values: Dict[str, float] = {}
        scenario = "normal"
        for p in parts[1:]:
            k, sep, v = p.partition("=")
            if not sep:
                return None  # truncated frame
            if k == "scn":
                try:
                    scenario = SCENARIOS[int(v)]
                except (ValueError, IndexError):
                    pass
                continue
            if k not in KEYS:
                continue  # newer firmware: ignore unknown sensors
            try:
                f = float(v)
            except ValueError:
                return None
            if f != f or f in (float("inf"), float("-inf")):
                return None
            values[KEYS[k]] = f
        if not values:
            return None
        return Frame(seq=seq, values=values, scenario=scenario)
    return None


def command(*parts: str) -> bytes:
    """Encodes a hub → Uno command line."""
    text = ",".join(("C",) + parts)
    if "\n" in text or len(text) > 46:
        raise ValueError("command too long")
    return (text + "\n").encode("ascii")
