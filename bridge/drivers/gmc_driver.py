"""GQ GMC Geiger counter driver (USB serial, GQ-RFC1201 protocol) via `pygmc`.

Some GMC firmware deviates from the written spec and baud rates differ (57600 / 115200) — TODO(verify) for your unit.
Counts are converted to dose ONLY with an explicit, user-supplied calibration factor; otherwise counts are published alone.
"""
from __future__ import annotations

import asyncio
from datetime import datetime, timezone
from typing import AsyncIterator, Dict, Any, Optional

from .base import Driver


class GMCDriver(Driver):
    name = "gmc"

    def __init__(self, port: Optional[str] = None, baud: Optional[int] = None, hz: float = 1.0, cpm_to_usvh: Optional[float] = None):
        self.port = port
        self.baud = baud
        self.period = 1.0 / max(hz, 0.1)
        self.factor = cpm_to_usvh
        self.gc = None
        self._closed = False

    async def open(self) -> Dict[str, Any]:
        try:
            import pygmc  # type: ignore
        except ImportError as e:  # pragma: no cover
            raise RuntimeError("Install pygmc: pip install pygmc") from e
        def _connect():
            if self.port:
                return pygmc.connect(port=self.port, baudrate=self.baud) if self.baud else pygmc.connect(port=self.port)
            return pygmc.connect()  # auto-detect port / baud
        self.gc = await asyncio.to_thread(_connect)
        ver = None
        try:
            ver = await asyncio.to_thread(self.gc.get_version)
        except Exception:  # noqa: BLE001
            pass
        return {"device": f"GQ GMC {ver or ''}".strip(), "serial": None}

    async def samples(self) -> AsyncIterator[Dict[str, Any]]:
        while not self._closed:
            cpm = await asyncio.to_thread(self.gc.get_cpm)
            s: Dict[str, Any] = {"ts": datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
                                 "count_rate_cpm": float(cpm), "count_rate_cps": float(cpm) / 60.0, "quality": "ok"}
            if self.factor:
                s["dose_rate_uSv_h"] = float(cpm) * self.factor  # labelled, user-configured calibration
            yield s
            await asyncio.sleep(self.period)

    async def close(self) -> None:
        self._closed = True
