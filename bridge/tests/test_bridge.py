"""Protocol, origin/token and reconnect tests for the bridge (run: python -m pytest tests  OR  python tests/test_bridge.py)."""
import asyncio
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import bridge  # noqa: E402
from websockets.asyncio.client import connect  # noqa: E402
from websockets.exceptions import InvalidStatus  # noqa: E402


class FlakyDriver(bridge.Driver):
    """Fails once after two samples, then recovers — exercises the reconnect path."""
    name = "flaky"

    def __init__(self):
        self.opens = 0

    async def open(self):
        self.opens += 1
        return {"device": f"Flaky#{self.opens}", "serial": None}

    async def samples(self):
        for i in range(2):
            yield {"ts": bridge.iso_now(), "dose_rate_uSv_h": 0.1 + i, "quality": "ok"}
            await asyncio.sleep(0.05)
        if self.opens == 1:
            raise RuntimeError("unplugged")
        while True:
            yield {"ts": bridge.iso_now(), "dose_rate_uSv_h": 0.2, "quality": "ok"}
            await asyncio.sleep(0.05)


def args(*extra):
    return bridge.parse_args(["--driver", "simulated", "--hz", "20", "--ws-port", "0", *extra])


class BridgeTests(unittest.IsolatedAsyncioTestCase):
    async def start(self, a, driver=None):
        b = bridge.Bridge(a, driver or bridge.make_driver(a))
        self.server = await bridge.serve(b.handler, "127.0.0.1", 0, process_request=b.check_request)
        self.port = self.server.sockets[0].getsockname()[1]
        self.tasks = [asyncio.create_task(b.run_driver()), asyncio.create_task(b.heartbeat())]
        self.b = b
        return b

    async def asyncTearDown(self):
        if not hasattr(self, "b"):
            return
        self.b._stop.set()
        for t in self.tasks:
            t.cancel()
        self.server.close()
        await self.server.wait_closed()

    async def test_protocol_hello_and_samples(self):
        await self.start(args())
        async with connect(f"ws://127.0.0.1:{self.port}", origin="app://crew-health-hub") as ws:
            hello = json.loads(await ws.recv())
            self.assertEqual(hello["type"], "hello")
            self.assertEqual(hello["bridge"], "crew-health-bridge")
            await ws.send(json.dumps({"type": "subscribe", "hz": 1}))
            kinds = set()
            for _ in range(30):
                m = json.loads(await asyncio.wait_for(ws.recv(), 2))
                kinds.add(m["type"])
                if m["type"] == "sample":
                    self.assertIn("dose_rate_uSv_h", m)
                    self.assertIn("ts", m)
                if {"sample", "heartbeat"} <= kinds:
                    break
            self.assertTrue({"sample", "heartbeat"} <= kinds)

    async def test_origin_rejected(self):
        await self.start(args())
        with self.assertRaises(InvalidStatus):
            async with connect(f"ws://127.0.0.1:{self.port}", origin="https://evil.example"):
                pass

    async def test_token_required(self):
        await self.start(args("--token", "s3cret"))
        with self.assertRaises(InvalidStatus):
            async with connect(f"ws://127.0.0.1:{self.port}", origin="app://crew-health-hub"):
                pass
        async with connect(f"ws://127.0.0.1:{self.port}", origin="app://crew-health-hub",
                           additional_headers={"Authorization": "Bearer s3cret"}) as ws:
            self.assertEqual(json.loads(await ws.recv())["type"], "hello")

    async def test_reconnect_after_driver_failure(self):
        drv = FlakyDriver()
        await self.start(args(), drv)
        async with connect(f"ws://127.0.0.1:{self.port}", origin="app://crew-health-hub") as ws:
            seen_error = False
            for _ in range(200):
                m = json.loads(await asyncio.wait_for(ws.recv(), 5))
                if m["type"] == "error":
                    seen_error = True
                if seen_error and m["type"] == "hello" and m["device"] == "Flaky#2":
                    break
            self.assertTrue(seen_error)
            self.assertEqual(drv.opens, 2)

    def test_non_loopback_requires_token(self):
        with self.assertRaises(SystemExit):
            bridge.parse_args(["--host", "0.0.0.0"])


if __name__ == "__main__":
    unittest.main()
