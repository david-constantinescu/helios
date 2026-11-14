"""Radiacode 10x driver wrapping the open-source `radiacode` library (cdump/radiacode).

TODO(verify): the library reports `dose_rate` in the device's native units. Check the library docs/examples and
compare with the device's on-screen value before trusting the µSv/h scale (see docs/verify-register.md).
"""
from __future__ import annotations

import asyncio
from datetime import datetime, timezone
from typing import AsyncIterator, Dict, Any, Optional

from .base import Driver

# PLACEHOLDER: multiply library dose_rate by this to get µSv/h. Verify against the device before use.
DOSE_RATE_TO_USV_H = 1.0  # TODO(verify unit and scale)


class RadiacodeDriver(Driver):
    name = "radiacode"

    def __init__(self, bluetooth_mac: Optional[str] = None, hz: float = 1.0):
        self.mac = bluetooth_mac
        self.period = 1.0 / max(hz, 0.1)
        self.dev = None
        self._closed = False

    async def open(self) -> Dict[str, Any]:
        try:
            from radiacode import RadiaCode  # type: ignore
        except ImportError as e:  # pragma: no cover - hardware optional
            raise RuntimeError("Install the radiacode package: pip install radiacode") from e
        # USB is the safest option on macOS; Bluetooth needs the device MAC.
        self.dev = await asyncio.to_thread(lambda: RadiaCode(bluetooth_mac=self.mac) if self.mac else RadiaCode())
        serial = None
        try:
            serial = await asyncio.to_thread(self.dev.serial_number)
        except Exception:  # noqa: BLE001 - optional metadata
            pass
        return {"device": "RadiaCode-10x", "serial": serial}

    async def samples(self) -> AsyncIterator[Dict[str, Any]]:
        while not self._closed:
            records = await asyncio.to_thread(self.dev.data_buf)
            for rec in records or []:
                # Real-time records expose count_rate and dose_rate (TODO(verify) attribute names for your version).
                dose_rate = getattr(rec, "dose_rate", None)
                count_rate = getattr(rec, "count_rate", None)
                if dose_rate is None and count_rate is None:
                    continue
                ts = getattr(rec, "dt", None) or datetime.now(timezone.utc)
                if ts.tzinfo is None:
                    ts = ts.replace(tzinfo=timezone.utc)
                s: Dict[str, Any] = {"ts": ts.isoformat(timespec="seconds").replace("+00:00", "Z"), "quality": "ok"}
                if dose_rate is not None:
                    s["dose_rate_uSv_h"] = float(dose_rate) * DOSE_RATE_TO_USV_H
                if count_rate is not None:
                    s["count_rate_cps"] = float(count_rate)
                    s["count_rate_cpm"] = float(count_rate) * 60
                yield s
            await asyncio.sleep(self.period)

    async def close(self) -> None:
        self._closed = True
