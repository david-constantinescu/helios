"""WebSocket server for the iPhone app.

Speaks the radiation-bridge protocol the app already understands (hello / sample / heartbeat) and adds:
  hub → app : env (habitat sensors + levels), upload_ack, env_history, ack_alert (an alert acknowledged on the OLED)
  app → hub : client, upload (observations), snapshot (the app's analysis per person), scenario, env_history, reset_cum
Security: the WebSocket Origin must be the app's (or a local page), and every connection must present the hub token
(Authorization: Bearer <token> or ?token=<token>). The token is shown on the OLED "Hub + connect" page.
"""
from __future__ import annotations

import asyncio
import hmac
import itertools
import json
import logging
import time
from typing import Any, Callable, Dict, Optional, Set
from urllib.parse import parse_qs, urlparse

import os

from websockets.asyncio.server import ServerConnection, serve
from websockets.datastructures import Headers
from websockets.http11 import Request, Response

from . import environment as env
from .state import Client, HubState, iso

log = logging.getLogger("crewhub.server")
VERSION = "1.0"
ALLOWED_ORIGINS = {"app://crew-health-hub", "http://localhost:8080", "http://127.0.0.1:8080"}
MAX_ROWS = 5000
WEB_DIR = os.path.join(os.path.dirname(__file__), "web")
STATIC = {"/": ("index.html", "text/html; charset=utf-8"), "/index.html": ("index.html", "text/html; charset=utf-8"),
          "/sw.js": ("sw.js", "text/javascript; charset=utf-8"), "/manifest.webmanifest": ("manifest.webmanifest", "application/manifest+json"),
          "/icon-180.png": ("icon-180.png", "image/png"), "/icon-192.png": ("icon-192.png", "image/png"), "/icon-512.png": ("icon-512.png", "image/png")}


class HubServer:
    def __init__(self, state: HubState, token: str, host: str = "0.0.0.0", port: int = 8765,
                 send_to_uno: Optional[Callable[[str], bool]] = None, public_origin: Optional[str] = None, push=None):
        self.state, self.token, self.host, self.port = state, token, host, port
        self.origins = set(ALLOWED_ORIGINS) | ({public_origin.rstrip("/")} if public_origin else set())
        self.push = push
        self.send_to_uno = send_to_uno or (lambda name: False)
        self.sockets: Dict[int, ServerConnection] = {}
        self.devices: Dict[int, str] = {}
        self.link_diag: Callable[[], Dict[str, Any]] = lambda: {}
        self.on_joystick: Optional[Callable[[str], Any]] = None     # set only with the simulated Uno (testing without hardware)
        self.screen: Callable[[], Dict[str, Any]] = lambda: {}
        self._ids = itertools.count(1)

    # --- connection gate ---------------------------------------------------------------------------------------
    def _authorized(self, request: Request) -> bool:
        auth = request.headers.get("Authorization", "")
        query = parse_qs(urlparse(request.path).query).get("token", [""])[0]
        given = auth[7:] if auth.startswith("Bearer ") else query
        return bool(self.token) and hmac.compare_digest(given.strip().upper(), self.token.upper())

    def _static(self, path: str):
        name, ctype = STATIC[path]
        try:
            with open(os.path.join(WEB_DIR, name), "rb") as f:
                body = f.read()
        except OSError:
            return None
        headers = Headers([("Content-Type", ctype), ("Content-Length", str(len(body))),
                           ("Cache-Control", "no-cache" if name in ("index.html", "sw.js") else "max-age=86400"),
                           ("X-Content-Type-Options", "nosniff"), ("Referrer-Policy", "no-referrer")])
        if name == "index.html":
            headers["Content-Security-Policy"] = "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'unsafe-inline'; img-src 'self'; connect-src 'self' wss: ws:"
        return Response(200, "OK", headers, body)

    def check_request(self, connection: ServerConnection, request: Request):
        path = urlparse(request.path).path
        upgrade = request.headers.get("Upgrade", "").lower() == "websocket"
        if not upgrade and path in STATIC:
            # The web app itself is public; everything it shows needs the hub code over the WebSocket.
            return self._static(path) or connection.respond(404, "Not found\n")
        origin = request.headers.get("Origin")
        same_site = origin is not None and urlparse(origin).netloc == request.headers.get("Host", "")   # the hub's own web app
        if origin is not None and origin not in self.origins and not same_site:
            return connection.respond(403, "Origin not allowed\n")
        if not self._authorized(request):
            return connection.respond(401, "Hub code required\n")
        if path == "/status":
            return connection.respond(200, json.dumps(self.status(), indent=1) + "\n")
        return None

    def status(self) -> Dict[str, Any]:
        s = self.state
        return {"hub": s.name, "version": VERSION, "uptime_s": int(time.time() - s.started),
                "uno": {"connected": s.uno_connected, "port": s.uno_port, "version": s.uno_version, "link": self.link_diag(),
                        "joystick": dict(s.joy)},
                "phones": [c.name for c in s.clients.values()], "env": s.env_payload(),
                "persons": [{"key": k, "name": (v.get("person") or {}).get("name")} for k, v in s.snapshots.items()],
                "observations": s.store.observation_count(), "alerts": [a.text for a in s.alerts()], "screen": self.screen()}

    def hello(self) -> Dict[str, Any]:
        s = self.state
        return {"type": "hello", "bridge": "crew-hub", "version": VERSION, "drivers": ["arduino"],
                "device": f"{s.name} sensors", "serial": s.uno_port, "simulated": False,
                "hub": {"name": s.name, "uno": s.uno_connected, "observations": s.store.observation_count()},
                "push_key": self.push.public_key if self.push and self.push.available else None}

    # --- per connection ----------------------------------------------------------------------------------------
    async def handler(self, ws: ServerConnection) -> None:
        cid = next(self._ids)
        self.sockets[cid] = ws
        self.state.clients[cid] = Client(cid, "iPhone")
        self.state.touch()
        log.info("Phone connected (%d)", len(self.sockets))
        try:
            await ws.send(json.dumps(self.hello()))
            if self.state.latest:
                await ws.send(json.dumps(self.state.env_payload()))
            async for raw in ws:
                try:
                    msg = json.loads(raw)
                except (TypeError, ValueError):
                    continue
                if isinstance(msg, dict):
                    reply = await self.on_message(cid, msg)
                    if reply:
                        await ws.send(json.dumps(reply))
        finally:
            self.sockets.pop(cid, None)
            self.devices.pop(cid, None)
            self.state.clients.pop(cid, None)
            self.state.touch()
            log.info("Phone disconnected (%d)", len(self.sockets))

    async def on_message(self, cid: int, msg: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        t = msg.get("type")
        s = self.state
        if t == "client":
            self.devices[cid] = str(msg.get("device_id") or cid)
            if cid in s.clients:
                s.clients[cid].name = str(msg.get("name") or "iPhone")[:40]
            s.touch()
            return None
        device = self.devices.get(cid, str(cid))
        if t == "upload":
            person = msg.get("person") or {}
            key = f"{device}:{person.get('id', 'me')}"
            s.store.upsert_person(key, device, str(person.get("id", "me")), str(person.get("name", "Crew"))[:40], str(person.get("role", "crew")))
            rows = (msg.get("rows") or [])[:MAX_ROWS]
            stored = s.store.insert_observations(key, rows)
            removed = s.store.delete_observations(key, [str(u) for u in (msg.get("deleted") or [])][:MAX_ROWS])
            return {"type": "upload_ack", "seq": msg.get("seq"), "stored": stored, "removed": removed,
                    "total": s.store.observation_count(key), "hub_total": s.store.observation_count()}
        if t == "snapshot":
            person = msg.get("person") or {}
            key = f"{device}:{person.get('id', 'me')}"
            s.store.upsert_person(key, device, str(person.get("id", "me")), str(person.get("name", "Crew"))[:40], str(person.get("role", "crew")))
            s.set_snapshot(key, msg, bool(msg.get("current")))
            return None
        if t == "scenario":
            name = str(msg.get("name", ""))
            ok = self.send_to_uno(name)
            return {"type": "scenario_ack", "name": name, "ok": ok}
        if t == "env_history":
            minutes = max(1, min(int(msg.get("minutes", 60) or 60), 60 * 24 * 30))
            since = time.time() - minutes * 60
            series = {k: s.store.env_history(k, since) for k in env.SENSORS}
            return {"type": "env_history", "minutes": minutes, "series": series}
        if t == "joystick" and self.on_joystick and str(msg.get("key")) in ("L", "R", "U", "D", "P", "H"):
            await self.on_joystick(str(msg["key"]))
            return None
        if t == "push_subscribe" and self.push:
            ok = self.push.subscribe(msg.get("subscription") or {})
            return {"type": "push_ack", "ok": ok}
        if t == "web_state":
            p = s.person() or {}
            person = None
            if p:
                person = {"name": (p.get("person") or {}).get("name", "Crew"), "level": int((p.get("overall") or {}).get("level", 0) or 0),
                          "title": (p.get("overall") or {}).get("title", ""), "day": (p.get("mission") or {}).get("day")}
            return {"type": "web_state", "person": person, "alerts": [{"text": a.text, "level": a.level} for a in s.alerts()]}
        if t == "reset_cum":
            s.cum_dose = 0.0
            return None
        return None   # subscribe, heartbeat replies, unknown

    # --- outbound ----------------------------------------------------------------------------------------------
    async def broadcast(self, payload: Dict[str, Any]) -> None:
        if not self.sockets:
            return
        text = json.dumps(payload)
        for cid, ws in list(self.sockets.items()):
            try:
                await ws.send(text)
            except Exception:  # noqa: BLE001 — a dead socket must not block the others
                self.sockets.pop(cid, None)

    async def send_frame(self) -> None:
        s = self.state
        rate = s.latest.get("rad_dose_rate")
        if rate is not None:
            await self.broadcast({"type": "sample", "ts": iso(s.latest_ts or time.time()), "dose_rate_uSv_h": rate,
                                  "count_rate_cpm": s.latest.get("rad_cpm"), "dose_cum_uSv": round(s.cum_dose, 4), "quality": "ok"})
        await self.broadcast(s.env_payload())

    async def ack_person_alert(self, alert_key: str) -> None:
        """An alert acknowledged with the joystick: tell the phone that owns that person to record the acknowledgement."""
        rest = alert_key[len("person:"):]
        person_key = next((pk for pk in self.state.snapshots if rest.startswith(pk + ":")), None)
        if person_key is None:
            return
        original = rest[len(person_key) + 1:]
        device, _, pid = person_key.partition(":")
        await self.broadcast({"type": "ack_alert", "device_id": device, "person_id": pid, "key": original, "via": "hub"})

    async def heartbeat(self) -> None:
        while True:
            await self.broadcast({"type": "heartbeat", "ts": iso(time.time())})
            await asyncio.sleep(5)

    def serve(self):
        return serve(self.handler, self.host, self.port, process_request=self.check_request, max_size=8 * 1024 * 1024)
