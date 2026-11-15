"""Helios — runs on the Raspberry Pi.

    python -m crewhub                                  # real Uno on USB + Adafruit OLED on I2C
    python -m crewhub --serial sim --display png --png-dir /tmp/oled --host 127.0.0.1    # no hardware (a Mac)

Settings come from /etc/crewhub/config.json (see deploy/config.example.json); command-line options win.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import secrets
import signal
import socket
import sys
import time
from typing import Any, Dict, Optional

from . import environment as env
from .display import NullDisplay, OledDisplay, PngDisplay, TftDisplay
from .pages import Nav, handle, render
from .tft_pages import render as render_tft
from .protocol import SCENARIOS, Frame, Hello, Joy, Message, command
from .serial_link import FakeUno, SerialLink
from .server import HubServer
from .state import HubState
from .store import Store
from .webpush import WebPush

log = logging.getLogger("crewhub")
TOKEN_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"     # no 0/O/1/I: easy to read off a tiny screen


def primary_ip() -> str:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("10.255.255.255", 1))     # no packet is sent; this just picks the outbound interface
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


def load_token(path: str, given: Optional[str]) -> str:
    if given:
        return given.strip().upper()
    try:
        with open(path) as f:
            t = f.read().strip().upper()
            if t:
                return t
    except OSError:
        pass
    t = "".join(secrets.choice(TOKEN_ALPHABET) for _ in range(6))
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(t + "\n")
        os.chmod(path, 0o600)
    except OSError:
        log.warning("Could not save the hub code to %s", path)
    return t


class Hub:
    def __init__(self, args: argparse.Namespace, cfg: Dict[str, Any]):
        self.args, self.cfg = args, cfg
        os.makedirs(os.path.dirname(os.path.abspath(args.db)), exist_ok=True)
        self.store = Store(args.db)
        self.state = HubState(self.store, name=args.name)
        self.nav = Nav()
        self.token = load_token(args.token_file, args.token)
        joy = cfg.get("joystick") or {}
        self.joy_map = {"L": "L", "R": "R", "U": "U", "D": "D", "P": "P", "H": "H"}
        if joy.get("swap_xy"):
            self.joy_map.update({"L": "U", "R": "D", "U": "L", "D": "R"})
        if joy.get("invert_x"):
            self.joy_map["L"], self.joy_map["R"] = self.joy_map["R"], self.joy_map["L"]
        if joy.get("invert_y"):
            self.joy_map["U"], self.joy_map["D"] = self.joy_map["D"], self.joy_map["U"]
        if args.serial == "sim":
            self.link = FakeUno(self.on_message, self.on_status, time_scale=args.sim_speed)
        else:
            self.link = SerialLink(self.on_message, self.on_status, port=None if args.serial == "auto" else args.serial)
        self.push = WebPush(self.store, args.vapid_key, args.public_url or "https://helios.local")
        self.server = HubServer(self.state, self.token, args.host, args.port, send_to_uno=self.scenario,
                                public_origin=args.public_url, push=self.push)
        if args.serial == "sim":
            self.server.on_joystick = self._remote_joystick
        self.server.screen = lambda: {"page": self.nav.name, "detail": self.nav.detail, "asleep": self.nav.asleep}
        colour = args.display in ("tft", "tft-png")
        t = cfg.get("tft") or {}
        self.size = (int(t.get("width", 160)), int(t.get("height", 128))) if colour else (args.width, args.height)
        self.render = render_tft if colour else render
        self.display = self._display()
        self.net: Dict[str, Any] = {}
        self._dirty = asyncio.Event()

    def _display(self):
        a = self.args
        if a.display == "png":
            return PngDisplay(a.png_dir)
        if a.display == "tft-png":
            return PngDisplay(a.png_dir, scale=3)
        if a.display == "none":
            return NullDisplay()
        if a.display == "tft":
            try:
                return TftDisplay(**(self.cfg.get("tft") or {}))
            except Exception as e:  # noqa: BLE001 — keep serving the app even without a screen
                log.error("TFT not available (%s); continuing without a display", e)
                return NullDisplay()
        try:
            return OledDisplay(a.oled, a.width, a.height, int(str(a.i2c_address), 0), a.i2c_port, a.rotate)
        except Exception as e:  # noqa: BLE001 — keep serving the app even without a screen
            log.error("OLED not available (%s); continuing without a display", e)
            return NullDisplay()

    # --- inputs ------------------------------------------------------------------------------------------------
    async def on_status(self, connected: bool, port: Optional[str]) -> None:
        if connected != self.state.uno_connected:
            self.store.log_event("uno", "connected" if connected else "disconnected")
        self.state.uno_connected, self.state.uno_port = connected, port
        self.state.touch()
        self._dirty.set()

    async def on_message(self, msg: Message) -> None:
        if isinstance(msg, Hello):
            self.state.uno_version = msg.version
            self.state.touch()
        elif isinstance(msg, Frame):
            new = self.state.on_frame(msg)
            for a in new:
                self.store.log_event("alert", a.text)
                if a.level >= 2:
                    self.notify(f"Habitat: {a.text}", "Open Helios or check the hub's Alerts page.", a.key, a.level >= 3)
                if a.level >= 2:
                    self.nav.go("alerts")
                    self.nav.asleep = False
            await self.server.send_frame()
        elif isinstance(msg, Joy):
            await self.on_joystick(self.joy_map.get(msg.key, msg.key))
        self._dirty.set()

    async def _remote_joystick(self, key: str) -> None:
        await self.on_joystick(key)
        self._dirty.set()

    async def on_joystick(self, key: str) -> None:
        action = handle(self.nav, key, self.state)
        if not action:
            return
        if action[0] == "ack":
            k = action[1]
            self.state.mute(k)
            if k.startswith("person:"):
                await self.server.ack_person_alert(k)
        elif action[0] == "select":
            self.state.select(action[1])
        elif action[0] == "scenario":
            self.scenario(action[1])

    def notify(self, title: str, body: str, tag: str, urgent: bool) -> None:
        """Push to every subscribed device without blocking the display or the sensors."""
        if self.push.available:
            asyncio.get_running_loop().run_in_executor(None, self.push.send_all, title, body, tag, urgent)

    def scenario(self, name: str) -> bool:
        if name not in SCENARIOS:
            return False
        ok = self.link.send(command("scenario", name))
        self.store.log_event("scenario", name)
        return ok

    # --- loops -------------------------------------------------------------------------------------------------
    async def display_loop(self) -> None:
        last_records = 0.0
        while True:
            now = time.time()
            if now - last_records > 10:
                self.net = {"host": socket.gethostname().split(".")[0], "ip": primary_ip(), "port": self.args.port,
                            "token": self.token, "records": self.store.observation_count(),
                            "public": (self.args.public_url or "").split("://")[-1].strip("/")}
                last_records = now
            while self.state.new_alerts:
                a = self.state.new_alerts.pop(0)
                self.notify(a.text.split(": ", 1)[0] + ": contact your flight surgeon", a.text.split(": ", 1)[-1], a.key, True)
            if self.state.jump_to_alerts:
                self.state.jump_to_alerts = False
                self.nav.go("alerts")
                self.nav.asleep = False
            idle = now - self.nav.last_input
            if idle > self.args.home_after and self.nav.page != 0 and not self.state.alerts():
                self.nav.go("home")
            if idle > self.args.sleep_after and not self.state.alerts():
                self.nav.asleep = True
            self.display.show(self.render(self.state, self.nav, self.size, now, self.net))
            try:
                # Joystick and data changes wake this at once; otherwise refresh for the clock and blinking.
                await asyncio.wait_for(self._dirty.wait(), timeout=0.25)
            except asyncio.TimeoutError:
                pass
            self._dirty.clear()

    async def housekeeping(self) -> None:
        while True:
            await asyncio.sleep(3600)
            self.store.prune()

    async def main(self) -> None:
        stop = asyncio.Event()
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGINT, signal.SIGTERM):
            try:
                loop.add_signal_handler(sig, stop.set)
            except NotImplementedError:
                pass
        async with self.server.serve():
            log.info("Helios Hub on ws://%s:%d — code %s", self.args.host, self.args.port, self.token)
            tasks = [asyncio.create_task(t) for t in (self.link.run(), self.display_loop(), self.server.heartbeat(), self.housekeeping())]
            await stop.wait()
            self.link.stop()
            for t in tasks:
                t.cancel()
        self.state.flush_minute()
        self.display.off()
        self.store.close()
        log.info("Helios Hub stopped")


def parse_args(argv=None) -> argparse.Namespace:
    pre = argparse.ArgumentParser(add_help=False)
    pre.add_argument("--config", default="/etc/crewhub/config.json")
    known, _ = pre.parse_known_args(argv)
    cfg: Dict[str, Any] = {}
    if os.path.exists(known.config):
        with open(known.config) as f:
            cfg = json.load(f)
    o = cfg.get("oled") or {}
    p = argparse.ArgumentParser(description="Helios (Raspberry Pi)", parents=[pre])
    p.add_argument("--name", default=cfg.get("name", "Helios Hub"))
    p.add_argument("--serial", default=cfg.get("serial", "auto"), help="auto | sim | /dev/ttyACM0")
    p.add_argument("--sim-speed", type=float, default=1.0, help="sim only: scenario time multiplier")
    p.add_argument("--display", default=cfg.get("display", "oled"), choices=["oled", "tft", "png", "tft-png", "none"])
    p.add_argument("--oled", default=o.get("driver", "ssd1306"), choices=["ssd1306", "sh1106", "ssd1309"])
    p.add_argument("--width", type=int, default=o.get("width", 128))
    p.add_argument("--height", type=int, default=o.get("height", 64), choices=[32, 64])
    p.add_argument("--i2c-address", default=o.get("address", "0x3C"))
    p.add_argument("--i2c-port", type=int, default=o.get("i2c_port", 1))
    p.add_argument("--rotate", type=int, default=o.get("rotate", 0), choices=[0, 1, 2, 3])
    p.add_argument("--png-dir", default="oled-preview")
    p.add_argument("--host", default=cfg.get("host", "0.0.0.0"))
    p.add_argument("--port", type=int, default=cfg.get("port", 8765))
    p.add_argument("--token", default=cfg.get("token"), help="hub code the app must present (default: generated)")
    p.add_argument("--token-file", default=cfg.get("token_file", "/var/lib/crewhub/token"))
    p.add_argument("--db", default=cfg.get("db", "/var/lib/crewhub/hub.db"))
    p.add_argument("--public-url", default=cfg.get("public_url"), help="e.g. https://nasa.softhoarders.me (allowed web origin, push subject)")
    p.add_argument("--vapid-key", default=cfg.get("vapid_key", "/var/lib/crewhub/vapid.pem"))
    p.add_argument("--home-after", type=float, default=cfg.get("home_after_s", 180))
    p.add_argument("--sleep-after", type=float, default=cfg.get("sleep_after_s", 1800))
    p.add_argument("--verbose", action="store_true")
    a = p.parse_args(argv)
    env.apply_overrides(cfg)
    a._cfg = cfg
    return a


def main(argv=None) -> None:
    args = parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO, stream=sys.stderr,
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    asyncio.run(Hub(args, args._cfg).main())


if __name__ == "__main__":
    main()
