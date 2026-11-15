"""USB serial link to the Arduino Uno, plus an in-process fake Uno for running the hub without hardware."""
from __future__ import annotations

import asyncio
import glob
import logging
import math
import random
import time
from typing import Awaitable, Callable, List, Optional

from .protocol import SCENARIOS, Frame, Hello, Message, parse_line

log = logging.getLogger("crewhub.serial")
OnMessage = Callable[[Message], Awaitable[None]]
OnStatus = Callable[[bool, Optional[str]], Awaitable[None]]


def candidate_ports() -> List[str]:
    """Uno = /dev/ttyACM0 on Linux (/dev/serial/by-id is stable across replugs); /dev/cu.usbmodem* on a Mac."""
    ports = sorted(glob.glob("/dev/serial/by-id/*Arduino*")) + sorted(glob.glob("/dev/ttyACM*")) + \
        sorted(glob.glob("/dev/ttyUSB*")) + sorted(glob.glob("/dev/cu.usbmodem*"))
    return ports


class SerialLink:
    def __init__(self, on_message: OnMessage, on_status: OnStatus, port: Optional[str] = None, baud: int = 115200):
        self.on_message, self.on_status = on_message, on_status
        self.port, self.baud = port, baud
        self.ser = None
        self._stop = False
        self.rx_lines = self.rx_ok = self.rx_bad = 0          # what the Uno has been sending, for diagnosing a silent link
        self.last_raw = ""
        self.last_ok: Optional[float] = None

    def diag(self) -> dict:
        return {"baud": self.baud, "lines": self.rx_lines, "ok": self.rx_ok, "bad": self.rx_bad, "last_raw": self.last_raw,
                "last_ok_age_s": None if self.last_ok is None else round(time.time() - self.last_ok, 1)}

    async def run(self) -> None:
        import serial  # pyserial
        loop = asyncio.get_running_loop()
        backoff = 1.0
        while not self._stop:
            port = self.port or next(iter(candidate_ports()), None)
            if not port:
                await self.on_status(False, None)
                await asyncio.sleep(2)
                continue
            try:
                self.ser = serial.Serial(port, self.baud, timeout=1)
                # Opening the port resets the Uno; wait for its bootloader, then drop whatever it printed.
                await asyncio.sleep(2.0)
                self.ser.reset_input_buffer()
                self.ser.write(b"C,hello\n")
                log.info("Uno on %s", port)
                await self.on_status(True, port)
                backoff = 1.0
                last_data = time.time()
                while not self._stop:
                    raw = await loop.run_in_executor(None, self.ser.readline)
                    if not raw:
                        if time.time() - last_data > 10:
                            raise IOError("no data from the Uno for 10 s")
                        continue
                    last_data = time.time()
                    self.rx_lines += 1
                    self.last_raw = "".join(ch if 32 <= ord(ch) < 127 else "?" for ch in raw[:80].decode("latin-1"))
                    msg = parse_line(raw)
                    if msg is not None:
                        self.rx_ok += 1
                        self.last_ok = time.time()
                        await self.on_message(msg)
                    else:
                        self.rx_bad += 1
            except Exception as e:  # noqa: BLE001 — unplugged, permissions, reset: retry
                log.warning("Serial %s: %s", port, e)
                await self.on_status(False, port)
                try:
                    if self.ser:
                        self.ser.close()
                except Exception:  # noqa: BLE001
                    pass
                self.ser = None
                await asyncio.sleep(backoff)
                backoff = min(backoff * 2, 15.0)

    def send(self, data: bytes) -> bool:
        try:
            if self.ser:
                self.ser.write(data)
                return True
        except Exception as e:  # noqa: BLE001
            log.warning("Serial write failed: %s", e)
        return False

    def stop(self) -> None:
        self._stop = True


class FakeUno:
    """Behaves like the sketch: hello, 1 Hz sensor frames, scenarios. Joystick events come from `press()`."""

    def __init__(self, on_message: OnMessage, on_status: OnStatus, rate_s: float = 1.0, seed: int = 7, time_scale: float = 1.0):
        self.on_message, self.on_status = on_message, on_status
        self.rate_s, self.time_scale = rate_s, time_scale
        self.rng = random.Random(seed)
        self.scenario = "normal"
        self.scenario_start = time.time()
        self.t0 = time.time()
        self.seq = 0
        self.co2, self.temp, self.rh, self.p, self.o2 = 600.0, 22.4, 44.0, 101.3, 20.9
        self._stop = False

    def _n(self) -> float:
        return self.rng.gauss(0, 0.33)

    def _minutes(self) -> float:
        return (time.time() - self.scenario_start) * self.time_scale / 60

    def frame(self) -> Frame:
        phase = ((time.time() - self.t0) * self.time_scale / 60 % 24) / 24
        lights = 6 <= phase * 24 < 22
        m = self._minutes()
        heat = min(6.0, m * 1.5) if self.scenario == "heat" else 0
        self.temp += (22.0 + 0.6 * math.sin(phase * 2 * math.pi) + heat - self.temp) * 0.05 + self._n() * 0.03
        self.rh += (42 + 6 * (1 if lights else 0.4) - self.rh) * 0.03 + self._n() * 0.15
        self.p += ((101.3 - min(12.0, m * 0.8) if self.scenario == "leak" else 101.3) - self.p) * 0.08 + self._n() * 0.02
        scrub = 0.0006 if self.scenario == "co2" else 0.0032
        self.co2 = min(8000, max(380, self.co2 + (2.2 if lights else 1.2) - (self.co2 - 420) * scrub + self._n() * 6))
        self.o2 += ((20.9 - (0.02 * m if self.scenario == "leak" else 0)) - self.o2) * 0.05 + self._n() * 0.02
        rad = 0.10 + self._n() * 0.012
        if self.scenario == "spike":
            rad += 8.0 * m / 2 if m < 2 else 8.0 * math.exp(-(m - 2) / 4.0)
            if m > 30:
                self.scenario = "normal"
        rad = max(0.01, rad)
        values = {
            "cabin_temp": round(self.temp, 2), "humidity": round(self.rh, 1), "pressure": round(self.p, 2),
            "co2": round(self.co2), "o2": round(self.o2, 2),
            "noise": round((56 if lights else 48) + (22 if self.scenario == "noise" else 0) + self._n() * 3, 1),
            "light": round(320 + self._n() * 15 if lights else 2 + abs(self._n())),
            "rad_dose_rate": round(rad, 3), "rad_cpm": round(max(0.0, rad * 180 + self._n() * 4)),
        }
        self.seq += 1
        return Frame(self.seq, values, self.scenario)

    async def run(self) -> None:
        await self.on_status(True, "simulated")
        await self.on_message(Hello("1.0-sim", []))
        while not self._stop:
            await self.on_message(self.frame())
            await asyncio.sleep(self.rate_s)

    def send(self, data: bytes) -> bool:
        parts = data.decode().strip().split(",")
        if len(parts) == 3 and parts[1] == "scenario" and parts[2] in SCENARIOS:
            self.scenario, self.scenario_start = parts[2], time.time()
        return True

    def stop(self) -> None:
        self._stop = True
