#!/usr/bin/env python3
"""Helios bridge — exposes a radiation detector to the Helios app over a local WebSocket.

Protocol (JSON, one message per frame):
  bridge → app: hello | sample | heartbeat | error | spectrum
  app → bridge: subscribe {"hz": 1} | reset_cum (simulated driver only)

Safety: binds to 127.0.0.1 by default, validates the WebSocket Origin against an allowlist, supports a shared
token, writes nothing to disk unless --log is given, and makes no outbound network connections.
Binding to any non-loopback address (e.g. to reach a real iPhone on your LAN) REQUIRES --token.

Examples:
  python bridge.py --driver simulated
  python bridge.py --driver simulated --scenario spike
  python bridge.py --driver radiacode --usb
  python bridge.py --driver radiacode --bluetooth-mac AA:BB:CC:DD:EE:FF
  python bridge.py --driver gmc --port /dev/ttyUSB0 --baud 115200
Options: --host 127.0.0.1 --ws-port 8765 --hz 1 --allow-origin app://crew-health-hub --token XYZ --log samples.csv
"""
from __future__ import annotations

import argparse
import asyncio
import csv
import ipaddress
import json
import logging
import signal
import sys
from datetime import datetime, timezone
from typing import Any, Dict, Optional, Set
from urllib.parse import parse_qs, urlparse

try:
    from websockets.asyncio.server import serve, ServerConnection
    from websockets.http11 import Request
except ImportError:  # pragma: no cover
    sys.exit("This bridge needs websockets>=13: pip install -r requirements.txt")

from drivers.base import Driver

VERSION = "1.0"
DEFAULT_ORIGINS = ["app://crew-health-hub", "http://localhost:8080", "http://127.0.0.1:8080"]
log = logging.getLogger("crew-health-bridge")


def iso_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def make_driver(args: argparse.Namespace) -> Driver:
    if args.driver == "simulated":
        from drivers.simulated_driver import SimulatedDriver
        return SimulatedDriver(hz=args.hz, scenario=args.scenario, spike_after_s=args.spike_after)
    if args.driver == "radiacode":
        from drivers.radiacode_driver import RadiacodeDriver
        return RadiacodeDriver(bluetooth_mac=None if args.usb else args.bluetooth_mac, hz=args.hz)
    if args.driver == "gmc":
        from drivers.gmc_driver import GMCDriver
        return GMCDriver(port=args.port, baud=args.baud, hz=args.hz, cpm_to_usvh=args.cpm_to_usvh)
    raise SystemExit(f"Unknown driver {args.driver}")


def is_loopback(host: str) -> bool:
    if host in ("localhost",):
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


class Bridge:
    def __init__(self, args: argparse.Namespace, driver: Driver):
        self.args = args
        self.driver = driver
        self.clients: Set[ServerConnection] = set()
        self.hello: Dict[str, Any] = {"type": "hello", "bridge": "crew-health-bridge", "version": VERSION,
                                      "drivers": ["radiacode", "gmc", "simulated"], "device": None, "serial": None}
        self.allowed_origins = set(args.allow_origin or DEFAULT_ORIGINS)
        self.log_writer = None
        self._stop = asyncio.Event()

    # --- connection gate: Origin allowlist + optional token -------------------------------------------------
    def check_request(self, connection: ServerConnection, request: Request):
        origin = request.headers.get("Origin")
        if origin is not None and origin not in self.allowed_origins:
            log.warning("Rejected origin %s", origin)
            return connection.respond(403, "Origin not allowed\n")
        if origin is None and not is_loopback(self.args.host):
            return connection.respond(403, "Origin header required\n")
        if self.args.token:
            auth = request.headers.get("Authorization", "")
            query_token = parse_qs(urlparse(request.path).query).get("token", [None])[0]
            if auth != f"Bearer {self.args.token}" and query_token != self.args.token:
                log.warning("Rejected connection: bad or missing token")
                return connection.respond(401, "Token required\n")
        return None

    async def handler(self, ws: ServerConnection) -> None:
        self.clients.add(ws)
        log.info("Client connected (%d total)", len(self.clients))
        try:
            await ws.send(json.dumps(self.hello))
            # Demo convenience (simulated driver only): replay recent history so the app can learn a background.
            if self.args.backfill and hasattr(self.driver, "backfill"):
                for sample in self.driver.backfill(self.args.backfill):  # type: ignore[attr-defined]
                    await ws.send(json.dumps({"type": "sample", **sample}))
            async for raw in ws:
                try:
                    msg = json.loads(raw)
                except (TypeError, ValueError):
                    continue
                if msg.get("type") == "subscribe":
                    log.info("Client subscribed at %s Hz", msg.get("hz", 1))
                elif msg.get("type") == "reset_cum" and hasattr(self.driver, "cum"):
                    self.driver.cum = 0.0  # type: ignore[attr-defined]
                    log.info("Cumulative dose counter reset by client")
        finally:
            self.clients.discard(ws)
            log.info("Client disconnected (%d total)", len(self.clients))

    async def broadcast(self, payload: Dict[str, Any]) -> None:
        if not self.clients:
            return
        text = json.dumps(payload)
        for ws in list(self.clients):
            try:
                await ws.send(text)
            except Exception:  # noqa: BLE001 - a dead client must not stop the others
                self.clients.discard(ws)

    async def heartbeat(self) -> None:
        while not self._stop.is_set():
            await self.broadcast({"type": "heartbeat", "ts": iso_now()})
            await asyncio.sleep(1.0)

    async def run_driver(self) -> None:
        backoff = 1.0
        while not self._stop.is_set():
            try:
                info = await self.driver.open()
                self.hello.update({"device": info.get("device"), "serial": info.get("serial"),
                                   "simulated": self.driver.name == "simulated"})
                log.info("Driver %s opened: %s", self.driver.name, info)
                await self.broadcast(self.hello)
                backoff = 1.0
                async for sample in self.driver.samples():
                    if self._stop.is_set():
                        break
                    payload = {"type": "sample", **sample}
                    await self.broadcast(payload)
                    if self.log_writer:
                        self.log_writer.writerow([payload.get(k, "") for k in ("ts", "dose_rate_uSv_h", "count_rate_cpm", "dose_cum_uSv")])
            except Exception as e:  # noqa: BLE001
                log.error("Driver error: %s", e)
                await self.broadcast({"type": "error", "code": "device_lost", "message": str(e)})
                try:
                    await self.driver.close()
                except Exception:  # noqa: BLE001
                    pass
                await asyncio.sleep(backoff)
                backoff = min(backoff * 2, 30.0)

    async def main(self) -> None:
        if self.args.log:
            f = open(self.args.log, "a", newline="")
            self.log_writer = csv.writer(f)
            self.log_writer.writerow(["ts", "dose_rate_uSv_h", "count_rate_cpm", "dose_cum_uSv"])
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGINT, signal.SIGTERM):
            try:
                loop.add_signal_handler(sig, self._stop.set)
            except NotImplementedError:  # Windows
                pass
        async with serve(self.handler, self.args.host, self.args.ws_port, process_request=self.check_request):
            log.info("Helios bridge %s listening on ws://%s:%d (driver=%s)", VERSION, self.args.host, self.args.ws_port, self.driver.name)
            tasks = [asyncio.create_task(self.run_driver()), asyncio.create_task(self.heartbeat())]
            await self._stop.wait()
            for t in tasks:
                t.cancel()
            await self.driver.close()
        log.info("Bridge stopped")


def parse_args(argv=None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Helios radiation bridge")
    p.add_argument("--driver", choices=["simulated", "radiacode", "gmc"], default="simulated")
    p.add_argument("--usb", action="store_true", help="Radiacode over USB (default)")
    p.add_argument("--bluetooth-mac", help="Radiacode Bluetooth MAC address")
    p.add_argument("--port", help="Serial port for GMC (e.g. /dev/ttyUSB0, COM3); auto-detect if omitted")
    p.add_argument("--baud", type=int, help="GMC baud rate (57600 or 115200); auto-detect if omitted")
    p.add_argument("--cpm-to-usvh", type=float, help="GMC: user calibration factor CPM→µSv/h (no default by design)")
    p.add_argument("--scenario", choices=["background", "spike"], default="background", help="Simulated driver scenario")
    p.add_argument("--spike-after", type=float, default=30.0, help="Simulated spike start (seconds after launch)")
    p.add_argument("--backfill", type=float, default=0, help="Simulated only: send this many minutes of past background samples to each new client")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--ws-port", type=int, default=8765, help="WebSocket port (default 8765)")
    p.add_argument("--hz", type=float, default=1.0)
    p.add_argument("--allow-origin", action="append", help="Allowed WebSocket Origin (repeatable)")
    p.add_argument("--token", help="Shared token clients must present")
    p.add_argument("--log", help="Append samples to this CSV file")
    p.add_argument("--config", help="TOML config file (Python 3.11+)")
    p.add_argument("--verbose", action="store_true")
    a = p.parse_args(argv)
    if a.config:
        try:
            import tomllib  # type: ignore
        except ImportError:
            p.error("--config needs Python 3.11+ (tomllib); pass options on the command line instead")
        with open(a.config, "rb") as fh:
            for k, v in tomllib.load(fh).items():
                if getattr(a, k.replace("-", "_"), None) in (None, False):
                    setattr(a, k.replace("-", "_"), v)
    if not is_loopback(a.host) and not a.token:
        p.error("Binding to a non-loopback address requires --token")
    return a


def main(argv=None) -> None:
    args = parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO, stream=sys.stderr,
                        format="%(asctime)s %(levelname)s %(message)s")
    driver = make_driver(args)
    asyncio.run(Bridge(args, driver).main())


if __name__ == "__main__":
    main()
