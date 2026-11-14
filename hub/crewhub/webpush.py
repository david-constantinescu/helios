"""Web Push (VAPID): alerts reach any browser or Home Screen web app that subscribed at the hub's public address,
even when the Helios app is closed. Keys are generated once and kept in the hub's data folder."""
from __future__ import annotations

import base64
import json
import logging
import os
import time
from typing import Any, Dict, List, Optional

log = logging.getLogger("crewhub.push")


class WebPush:
    def __init__(self, store, key_path: str, subject: str):
        self.store, self.key_path, self.subject = store, key_path, subject
        self.public_key: Optional[str] = None
        self.available = False
        with store.lock, store.db:
            store.db.execute("CREATE TABLE IF NOT EXISTS push_subs (endpoint TEXT PRIMARY KEY, json TEXT NOT NULL, created REAL)")
        try:
            from cryptography.hazmat.primitives import serialization
            from cryptography.hazmat.primitives.asymmetric import ec
            if os.path.exists(key_path):
                with open(key_path, "rb") as f:
                    key = serialization.load_pem_private_key(f.read(), password=None)
            else:
                key = ec.generate_private_key(ec.SECP256R1())
                os.makedirs(os.path.dirname(key_path) or ".", exist_ok=True)
                with open(key_path, "wb") as f:
                    f.write(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
                os.chmod(key_path, 0o600)
            import pywebpush  # noqa: F401 — sending needs it; fail early if it is missing
            raw = key.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
            self.public_key = base64.urlsafe_b64encode(raw).rstrip(b"=").decode()
            self.available = True
        except Exception as e:  # noqa: BLE001 — push is optional; the hub works without it
            log.warning("Web push unavailable: %s", e)

    def subscribe(self, sub: Dict[str, Any]) -> bool:
        endpoint = str(sub.get("endpoint", ""))
        keys = sub.get("keys") or {}
        if not endpoint.startswith("https://") or not keys.get("p256dh") or not keys.get("auth"):
            return False
        with self.store.lock, self.store.db:
            self.store.db.execute("INSERT OR REPLACE INTO push_subs VALUES (?,?,?)", (endpoint, json.dumps(sub), time.time()))
        return True

    def unsubscribe(self, endpoint: str) -> None:
        with self.store.lock, self.store.db:
            self.store.db.execute("DELETE FROM push_subs WHERE endpoint=?", (endpoint,))

    def subscriptions(self) -> List[Dict[str, Any]]:
        with self.store.lock:
            rows = self.store.db.execute("SELECT json FROM push_subs").fetchall()
        return [json.loads(r[0]) for r in rows]

    def send_all(self, title: str, body: str, tag: str, urgent: bool) -> int:
        """Blocking (run it in an executor). Returns how many subscriptions accepted the message."""
        if not self.available:
            return 0
        from pywebpush import WebPushException, webpush
        payload = json.dumps({"title": title, "body": body, "tag": tag, "urgent": urgent})
        ok = 0
        for sub in self.subscriptions():
            try:
                webpush(sub, payload, vapid_private_key=self.key_path, vapid_claims={"sub": self.subject},
                        ttl=3600, headers={"Urgency": "high" if urgent else "normal"}, timeout=10)
                ok += 1
            except WebPushException as e:
                code = getattr(e.response, "status_code", None)
                if code in (404, 410):                  # the browser dropped this subscription
                    self.unsubscribe(sub.get("endpoint", ""))
                else:
                    log.warning("Push failed (%s): %s", code, e)
            except Exception as e:  # noqa: BLE001
                log.warning("Push failed: %s", e)
        return ok
