"""Driver interface for the Helios bridge (PART 7.3)."""
from __future__ import annotations

from typing import AsyncIterator, Dict, Any


class Driver:
    """A driver opens a device, yields normalised samples and closes cleanly.

    Normalised sample keys: ts (ISO-8601 UTC), dose_rate_uSv_h?, count_rate_cps?, count_rate_cpm?,
    dose_cum_uSv?, battery? (0..1), quality ("ok" | "suspect").
    """

    name = "base"

    async def open(self) -> Dict[str, Any]:
        """Open the device and return hello info: {"device": str, "serial": str | None}."""
        raise NotImplementedError

    async def samples(self) -> AsyncIterator[Dict[str, Any]]:
        raise NotImplementedError
        yield {}  # pragma: no cover  (makes this an async generator for type checkers)

    async def close(self) -> None:
        return None
