"""Hub tests:  cd hub && python -m pytest -q"""
import asyncio
import json
import os
import sys
import tempfile
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import pytest  # noqa: E402
from websockets.asyncio.client import connect  # noqa: E402
from websockets.exceptions import InvalidStatus  # noqa: E402

from crewhub import environment as env  # noqa: E402
from crewhub.pages import PAGES, Nav, handle, list_items, render  # noqa: E402
from crewhub.protocol import Frame, Hello, Joy, Reply, command, parse_line  # noqa: E402
from crewhub.serial_link import FakeUno  # noqa: E402
from crewhub.server import HubServer  # noqa: E402
from crewhub.state import HubState  # noqa: E402
from crewhub.store import Store  # noqa: E402


def new_state() -> HubState:
    return HubState(Store(os.path.join(tempfile.mkdtemp(), "t.db")))


# --- protocol -------------------------------------------------------------------------------------------------

def test_parse_frame_hello_joystick_reply():
    f = parse_line(b"S,12,t=22.41,rh=45.2,p=101.32,co2=612,o2=20.91,db=52.3,lux=310,rad=0.112,cpm=19,scn=2\r\n")
    assert isinstance(f, Frame) and f.seq == 12 and f.scenario == "spike"
    assert f.values["co2"] == 612 and f.values["rad_dose_rate"] == 0.112 and f.values["cabin_temp"] == 22.41
    assert isinstance(parse_line("H,crew-sensors,1.0,t,rh"), Hello)
    assert parse_line("J,L") == Joy("L") and parse_line("J,H") == Joy("H")
    assert parse_line("A,scenario,ok") == Reply("scenario", True)


@pytest.mark.parametrize("line", [
    b"", b"\x00\xff\xfe", b"S,", b"S,abc,t=1", b"S,3,t=22.4,rh", b"S,3,t=nan", b"S,3,t=inf", b"J,X", b"J,", b"H,other,1.0",
    b"A,ping,maybe", b"garbage line", b"S,4,zz=1", b"avrdude boot noise",
])
def test_parse_rejects_noise_and_half_lines(line):
    assert parse_line(line) is None


def test_unknown_sensor_keys_are_ignored():
    f = parse_line("S,5,t=21.0,newsensor=3")
    assert f.values == {"cabin_temp": 21.0}


def test_command_encoding():
    assert command("scenario", "spike") == b"C,scenario,spike\n"
    with pytest.raises(ValueError):
        command("x" * 60)


# --- environment levels ---------------------------------------------------------------------------------------

def test_levels():
    assert env.level("co2", 800) == 0 and env.level("co2", 3000) == 1 and env.level("co2", 4500) == 2 and env.level("co2", 6000) == 3
    assert env.level("o2", 20.9) == 0 and env.level("o2", 17) == 2 and env.level("o2", 26) == 3
    assert env.level("pressure", 101.3) == 0 and env.level("pressure", 94) == 2
    assert env.level("rad_dose_rate", 0.1, 0.1) == 0 and env.level("rad_dose_rate", 0.35, 0.1) == 1
    assert env.level("rad_dose_rate", 1.2, 0.1) == 2 and env.level("rad_dose_rate", 6, 0.1) == 3
    assert env.level("rad_dose_rate", 6, None) == 0      # no background learned yet: no judgement


def test_state_learns_background_and_raises_spike_alert():
    st = new_state()
    uno = FakeUno(None, None, seed=1)
    t0 = time.time() - 600
    for i in range(400):
        st.on_frame(uno.frame(), ts=t0 + i)
    assert st.background and 0.07 < st.background < 0.13
    new = st.on_frame(Frame(999, {"rad_dose_rate": 8.0}), ts=t0 + 401)
    assert any(a.key.startswith("habitat:rad_dose_rate") and a.level == 3 for a in new)
    key = new[0].key
    st.mute(key)
    assert all(a.key != key for a in st.alerts())
    st.on_frame(Frame(1000, {"rad_dose_rate": 0.1}), ts=t0 + 402)     # level dropped → mute cleared
    assert key not in st.muted


def test_minute_rollup_is_stored():
    st = new_state()
    t0 = (int(time.time()) // 60 - 3) * 60
    for i in range(130):
        st.on_frame(Frame(i, {"co2": 600 + i}), ts=t0 + i)
    hist = st.store.env_history("co2", t0 - 1)
    assert len(hist) == 2 and hist[0][1] == pytest.approx(629.5)


# --- pages ----------------------------------------------------------------------------------------------------

def snapshot(level=0, alerts=None):
    return {"person": {"id": "david", "name": "David"}, "overall": {"level": level, "title": "All good"},
            "alerts": alerts or [], "mission": {"day": 3},
            "metrics": {"hrv": {"label": "HRV", "unit": "ms", "decimals": 0, "group": "Heart", "value": 50, "spark": [48, 50]},
                        "protein_g": {"label": "Protein", "unit": "g", "decimals": 0, "group": "Nutrition", "value": 90}}}


@pytest.mark.parametrize("height", [64, 32])
def test_every_page_renders(height):
    st = new_state()
    uno = FakeUno(None, None)
    for i in range(30):
        st.on_frame(uno.frame(), ts=time.time() - 30 + i)
    st.set_snapshot("dev:david", snapshot(3, [{"key": "metric:sleep|d", "text": "Sleep 2.5 h below usual"}]), True)
    for name in PAGES:
        nav = Nav()
        nav.go(name)
        img = render(st, nav, (128, height))
        assert img.size == (128, height) and img.mode == "1"
        assert img.getbbox() is not None, name     # something is drawn
    empty = new_state()
    for name in PAGES:
        nav = Nav(); nav.go(name)
        render(empty, nav, (128, height))            # no data at all must not crash


def test_navigation_and_actions():
    st = new_state()
    st.set_snapshot("dev:david", snapshot(3, [{"key": "metric:sleep|d", "text": "Sleep low"}]), True)
    nav = Nav()
    assert handle(nav, "R", st) is None and nav.name == "alerts"
    assert handle(nav, "L", st) is None and nav.name == "home"
    handle(nav, "L", st)
    assert nav.name == PAGES[-1]                              # wraps around
    nav.go("home")
    handle(nav, "P", st)
    assert nav.name == "alerts"                                # press on home jumps to alerts
    act = handle(nav, "P", st)
    assert act == ("ack", "person:dev:david:metric:sleep|d")
    nav.go("demo")
    handle(nav, "D", st); handle(nav, "D", st)
    assert handle(nav, "P", st) == ("scenario", "spike")
    nav.go("health")
    items = list_items(st, "health")
    assert items[0] == ("group", "Heart")
    handle(nav, "P", st)
    assert nav.detail == "hrv"                                 # group headings are skipped
    handle(nav, "D", st)
    assert nav.detail == "protein_g"
    handle(nav, "H", st)
    assert nav.name == "home" and nav.detail is None
    handle(nav, "H", st)
    assert nav.asleep
    handle(nav, "R", st)
    assert not nav.asleep and nav.name == "home"               # first input only wakes the screen


# --- server ---------------------------------------------------------------------------------------------------

def run(coro):
    return asyncio.new_event_loop().run_until_complete(coro)


async def _with_server(fn):
    st = new_state()
    sent = []
    srv = HubServer(st, "K7Q2MX", "127.0.0.1", 0, send_to_uno=lambda n: sent.append(n) or True)
    async with srv.serve() as server:
        port = server.sockets[0].getsockname()[1]
        return await fn(st, srv, port, sent)


def test_server_requires_code_and_app_origin():
    async def body(st, srv, port, sent):
        with pytest.raises(InvalidStatus) as e:
            async with connect(f"ws://127.0.0.1:{port}/", origin="app://crew-health-hub"):
                pass
        assert e.value.response.status_code == 401
        with pytest.raises(InvalidStatus) as e:
            async with connect(f"ws://127.0.0.1:{port}/?token=K7Q2MX", origin="http://evil.example"):
                pass
        assert e.value.response.status_code == 403
        async with connect(f"ws://127.0.0.1:{port}/", origin="app://crew-health-hub",
                           additional_headers={"Authorization": "Bearer k7q2mx"}) as ws:
            hello = json.loads(await ws.recv())
            assert hello["type"] == "hello" and hello["bridge"] == "crew-hub" and hello["simulated"] is False
    run(_with_server(body))


def test_upload_snapshot_scenario_roundtrip():
    async def body(st, srv, port, sent):
        async with connect(f"ws://127.0.0.1:{port}/?token=K7Q2MX", origin="app://crew-health-hub") as ws:
            await ws.recv()
            await ws.send(json.dumps({"type": "client", "device_id": "phone1", "name": "David's iPhone"}))
            rows = [["u1", "hrv", 1700000000, 52, "ms", "Watch", "device"], ["u2", "activity_steps", 1700000000, 8000, "steps", "iPhone", "device"],
                    ["bad"], ["u3", "hrv", 1700000100, float("nan")]]
            await ws.send(json.dumps({"type": "upload", "seq": 1, "person": {"id": "david", "name": "David"}, "rows": rows}))
            ack = json.loads(await ws.recv())
            assert ack == {"type": "upload_ack", "seq": 1, "stored": 2, "removed": 0, "total": 2, "hub_total": 2}
            await ws.send(json.dumps({"type": "upload", "seq": 2, "person": {"id": "david", "name": "David"}, "rows": [], "deleted": ["u1"]}))
            ack = json.loads(await ws.recv())
            assert ack["removed"] == 1 and ack["total"] == 1
            await ws.send(json.dumps(dict(snapshot(1), type="snapshot", current=True)))
            await ws.send(json.dumps({"type": "scenario", "name": "spike"}))
            reply = json.loads(await ws.recv())
            assert reply == {"type": "scenario_ack", "name": "spike", "ok": True} and sent == ["spike"]
            assert st.current_person == "phone1:david" and st.person()["person"]["name"] == "David"
            assert st.clients and list(st.clients.values())[0].name == "David's iPhone"
            await srv.ack_person_alert("person:phone1:david:metric:sleep_hours|2026-11-14")
            msg = json.loads(await ws.recv())
            while msg["type"] != "ack_alert":
                msg = json.loads(await ws.recv())
            assert msg == {"type": "ack_alert", "device_id": "phone1", "person_id": "david", "key": "metric:sleep_hours|2026-11-14", "via": "hub"}
    run(_with_server(body))


# --- fast OLED driver ------------------------------------------------------------------------------------------

class FakeBus:
    def __init__(self):
        self.writes = []

    def write(self, addr, payload):
        self.writes.append((addr, list(payload)))


def test_page_packing_matches_reference():
    import random
    from PIL import Image
    from crewhub.oled_fast import to_pages, to_pages_slow
    rnd = random.Random(4)
    for h in (64, 32):
        img = Image.new("1", (128, h))
        img.putdata([rnd.choice((0, 255)) for _ in range(128 * h)])
        assert to_pages(img) == to_pages_slow(img)


def test_delta_updates_send_only_changes():
    from PIL import Image, ImageDraw
    from crewhub.oled_fast import FastOled
    bus = FakeBus()
    oled = FastOled("ssd1306", 128, 64, 0x3C, bus=bus)
    img = Image.new("1", (128, 64))
    assert oled.show(img) == 0                          # identical frame: nothing sent
    ImageDraw.Draw(img).rectangle([100, 1, 110, 6], fill=1)
    bus.writes.clear()
    sent = oled.show(img)
    assert sent < 30                                    # one page, 11 columns (+ addressing), not 1 KB
    cmd, data = bus.writes[-2][1], bus.writes[-1][1]
    assert cmd == [0x00, 0x21, 100, 110, 0x22, 0, 0] and data[0] == 0x40 and len(data) == 12
    st = new_state()
    nav = Nav()
    full = sum(len(p) for p in __import__("crewhub.oled_fast", fromlist=["to_pages"]).to_pages(render(st, nav)))
    assert full == 1024


def test_sh1106_uses_page_addressing_with_offset():
    from PIL import Image, ImageDraw
    from crewhub.oled_fast import FastOled
    bus = FakeBus()
    oled = FastOled("sh1106", 128, 64, 0x3C, bus=bus)
    img = Image.new("1", (128, 64))
    ImageDraw.Draw(img).point((5, 20), fill=1)
    bus.writes.clear()
    oled.show(img)
    assert bus.writes[0][1] == [0x00, 0xB2, (5 + 2) & 0x0F, 0x10 | ((5 + 2) >> 4)]


def test_web_app_is_served_and_push_subscription_needs_code():
    import urllib.request
    from crewhub.webpush import WebPush

    async def body():
        st = new_state()
        push = WebPush(st.store, os.path.join(tempfile.mkdtemp(), "vapid.pem"), "https://example.test")
        srv = HubServer(st, "K7Q2MX", "127.0.0.1", 0, public_origin="https://nasa.example.test", push=push)
        async with srv.serve() as server:
            port = server.sockets[0].getsockname()[1]
            loop = asyncio.get_running_loop()
            page = await loop.run_in_executor(None, lambda: urllib.request.urlopen(f"http://127.0.0.1:{port}/").read())
            assert b"Helios" in page
            sw = await loop.run_in_executor(None, lambda: urllib.request.urlopen(f"http://127.0.0.1:{port}/sw.js"))
            assert sw.headers["Content-Type"].startswith("text/javascript")
            with pytest.raises(Exception):
                await loop.run_in_executor(None, lambda: urllib.request.urlopen(f"http://127.0.0.1:{port}/status"))
            async with connect(f"ws://127.0.0.1:{port}/?token=K7Q2MX", origin="https://nasa.example.test") as ws:
                hello = json.loads(await ws.recv())
                assert push.available and hello["push_key"] == push.public_key and len(push.public_key) > 80
                sub = {"endpoint": "https://push.example.test/abc", "keys": {"p256dh": "x" * 20, "auth": "y" * 8}}
                await ws.send(json.dumps({"type": "push_subscribe", "subscription": sub}))
                msg = json.loads(await ws.recv())
                while msg["type"] != "push_ack":
                    msg = json.loads(await ws.recv())
                assert msg["ok"] and push.subscriptions()[0]["endpoint"] == sub["endpoint"]
                await ws.send(json.dumps({"type": "push_subscribe", "subscription": {"endpoint": "http://insecure"}}))
                msg = json.loads(await ws.recv())
                while msg["type"] != "push_ack":
                    msg = json.loads(await ws.recv())
                assert msg["ok"] is False
    run(body())


# --- colour TFT -------------------------------------------------------------------------------------------------

class _Spi:
    def __init__(self):
        self.writes = []

    def writebytes2(self, data):
        self.writes.append(bytes(data))

    def close(self):
        pass


class _Gpio:
    def __init__(self):
        self.levels = {}

    def write(self, pin, level):
        self.levels[pin] = level


def test_rgb565_matches_reference():
    from PIL import Image
    from crewhub.tft_fast import to_rgb565
    cols = [(0, 0, 0), (255, 255, 255), (255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 214, 10), (10, 132, 255), (152, 152, 157)]
    img = Image.new("RGB", (len(cols), 1))
    img.putdata(cols)
    got = to_rgb565(img)
    want = b"".join((((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3)).to_bytes(2, "big") for r, g, b in cols)
    assert got == want


def test_tft_sends_only_the_changed_rectangle():
    from PIL import Image, ImageDraw
    from crewhub.tft_fast import FastTft
    spi, gpio = _Spi(), _Gpio()
    tft = FastTft(spi=spi, gpio=gpio, sleep=lambda s: None)
    assert tft.bytes_sent > 160 * 128 * 2                     # init + one full black frame
    img = Image.new("RGB", (160, 128))
    assert tft.show(img) == 0                                 # identical frame → nothing on the bus
    ImageDraw.Draw(img).rectangle([10, 20, 29, 29], fill=(255, 0, 0))
    sent = tft.show(img)
    assert sent == 5 + 5 + 1 + 20 * 10 * 2 + 1 + 4 + 4 + 0 or sent < 700    # window commands + 200 pixels, not the whole frame
    assert sent < 800
    assert gpio.levels[25] == 1                               # D/C high for pixel data


def test_tft_rotation_and_offsets_are_applied():
    from crewhub.tft_fast import BGR, FastTft, MV, MY
    spi = _Spi()
    FastTft(spi=spi, gpio=_Gpio(), rotate=1, bgr=True, col_offset=2, row_offset=1, sleep=lambda s: None)
    assert bytes([MY | MV | BGR]) in spi.writes
    assert bytes([0, 2, 0, 161]) in spi.writes                # CASET: 0+2 … 159+2
    assert bytes([0, 1, 0, 128]) in spi.writes                # RASET: 0+1 … 127+1


def _tft_frames(spike=False):
    from crewhub.tft_pages import render as tft_render
    import sys
    sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))
    from preview import sample_state
    st = sample_state(spike)
    st.started = time.time() - 60
    out = {}
    for name in PAGES:
        nav = Nav()
        nav.go(name)
        out[name] = tft_render(st, nav, (160, 128), now=time.time(), net={"token": "ABC123", "ip": "1.2.3.4"})
    return st, out


def test_tft_every_page_renders_in_colour():
    st, frames = _tft_frames()
    for name, img in frames.items():
        assert img.size == (160, 128) and img.mode == "RGB", name
        assert img.getbbox() is not None, name              # not blank
    assert frames["home"].tobytes() != frames["alerts"].tobytes()


def test_tft_lists_scroll_with_the_cursor_and_details_render():
    from crewhub.tft_pages import render as tft_render
    st, _ = _tft_frames()
    nav = Nav()
    nav.go("health")
    first = tft_render(st, nav, (160, 128)).tobytes()
    for _ in range(12):
        handle(nav, "D", st)
    moved = tft_render(st, nav, (160, 128)).tobytes()
    assert nav.top["health"] > 0
    assert moved != first
    nav.detail = "heart_rate_resting"
    assert tft_render(st, nav, (160, 128)).getbbox() is not None


def test_tft_sleep_is_black_and_splash_shows_first():
    from crewhub.tft_pages import render as tft_render
    st, _ = _tft_frames()
    nav = Nav()
    nav.asleep = True
    st.alerts = lambda: []
    assert tft_render(st, nav, (160, 128)).getbbox() is None
    nav.asleep = False
    st.started = time.time()
    assert tft_render(st, nav, (160, 128), now=time.time()).getbbox() is not None


# --- HDMI (framebuffer + widescreen pages) ----------------------------------------------------------------------

def _fb(w=64, h=32, bpp=32, stride=None):
    from crewhub.fb_fast import FastFb, FbInfo
    stride = stride or w * bpp // 8
    buf = bytearray(stride * h)
    return FastFb(info=FbInfo(w, h, bpp, stride), buf=buf), buf


def test_fb_pack_byte_orders():
    from PIL import Image
    from crewhub.fb_fast import pack
    img = Image.new("RGB", (2, 1))
    img.putdata([(255, 128, 0), (0, 64, 255)])
    assert pack(img, 32) == bytes([0, 128, 255, 0, 255, 64, 0, 0])          # little-endian XRGB8888: B, G, R, X
    assert pack(img, 24) == bytes([0, 128, 255, 255, 64, 0])
    want = [((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3) for r, g, b in ((255, 128, 0), (0, 64, 255))]
    assert pack(img, 16) == b"".join(v.to_bytes(2, "little") for v in want)


def test_fb_delta_writes_only_the_changed_rectangle_at_the_right_offset():
    from PIL import Image, ImageDraw
    fb, buf = _fb(64, 32, 32, stride=64 * 4 + 32)            # padded rows, like a real framebuffer
    img = Image.new("RGB", (64, 32))
    assert fb.show(img) == 64 * 32 * 4 and fb.show(img) == 0
    ImageDraw.Draw(img).rectangle([10, 5, 19, 9], fill=(200, 100, 50))
    assert fb.show(img) == 10 * 5 * 4
    off = 5 * fb.info.stride + 10 * 4
    assert bytes(buf[off:off + 4]) == bytes([50, 100, 200, 0])
    assert bytes(buf[off - 4:off]) == bytes(4)                # the neighbour pixel is untouched
    assert bytes(buf[9 * fb.info.stride + 19 * 4: 9 * fb.info.stride + 19 * 4 + 4]) == bytes([50, 100, 200, 0])


def test_fb_regions_merge_and_clamp():
    from PIL import Image
    fb, buf = _fb(100, 50)
    img = Image.new("RGB", (100, 50), (1, 2, 3))
    first = fb.show_regions(img, [(0, 0, 10, 10)])
    assert first == 100 * 50 * 4                              # the first frame always paints everything
    n = fb.show_regions(img, [(10, 10, 20, 20), (-5, -5, 3, 3), (90, 40, 140, 80)])
    assert 0 < n < 100 * 50 * 4
    assert fb.show_regions(img, []) == 0


def _wide_state():
    import sys
    sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))
    from preview import sample_state
    st = sample_state()
    st.started = time.time() - 60
    return st


@pytest.mark.parametrize("size", [(1280, 720), (1920, 1080), (1920, 1200)])
def test_hdmi_every_page_renders_at_any_resolution(size):
    from crewhub.hdmi_pages import render as hd_render
    st = _wide_state()
    seen = set()
    for name in PAGES:
        nav = Nav()
        nav.go(name)
        img = hd_render(st, nav, size, now=time.time(), net={"token": "ABC123", "ip": "1.2.3.4", "public": "x.me"})
        assert img.size == size and img.mode == "RGB" and img.getbbox() is not None, name
        seen.add(img.tobytes())
    assert len(seen) == len(PAGES)                            # every page looks different


def test_hdmi_retained_renderer_matches_a_fresh_render_and_only_redraws_changes():
    from crewhub.hdmi_pages import Renderer
    st = _wide_state()
    net = {"token": "ABC123", "ip": "1.2.3.4", "public": "x.me"}
    size, t = (1280, 720), time.time()
    rd = Renderer()
    nav = Nav()

    def check(label):
        img, dirty = rd.draw(st, nav, size, t, net)
        fresh, _ = Renderer().draw(st, nav, size, t, net)
        assert img.tobytes() == fresh.tobytes(), label        # retained drawing never drifts from a from-scratch frame
        return dirty

    full = check("first")
    assert full == [(0, 0, 1280, 720)]
    assert check("unchanged") == []                           # nothing changed → nothing to write
    t += 60                                                   # the clock ticks
    small = check("clock")
    assert small and sum((b[2] - b[0]) * (b[3] - b[1]) for b in small) < 0.05 * 1280 * 720
    for key in ("R", "R", "D", "D", "P", "D", "L", "R", "R", "H"):
        handle(nav, key, st)
        t += 0.1
        check("after " + key)
    nav.toast = ("Radiation spike", t)
    check("toast on")
    t += 3
    check("toast off")
    nav.asleep = True
    st.alerts = lambda: []
    assert check("sleep") and rd.draw(st, nav, size, t, net)[0].getbbox() is None


def test_hdmi_header_flashes_red_for_a_call_now_alert():
    from crewhub.hdmi_pages import Renderer
    st = _wide_state()
    nav = Nav()
    on, _ = Renderer().draw(st, nav, (1280, 720), now=1000.25, net={})
    off, _ = Renderer().draw(st, nav, (1280, 720), now=1000.75, net={})
    assert on.getpixel((400, 40)) != off.getpixel((400, 40))


def test_hub_widescreen_loop_draws_changes_only(tmp_path, monkeypatch):
    import crewhub.main as hub_main

    class FakeHdmi:
        size, fps, generation = (1280, 720), 30, 1

        def __init__(self, **cfg):
            self.frames = []

        def ready(self):
            return True

        def show(self, img, dirty=None):
            self.frames.append((img.size, dirty))

        def off(self):
            pass

    monkeypatch.setattr(hub_main, "HdmiDisplay", FakeHdmi)
    args = hub_main.parse_args(["--config", str(tmp_path / "none.json"), "--serial", "sim", "--display", "hdmi", "--db", str(tmp_path / "h.db"),
                                "--token-file", str(tmp_path / "tok"), "--port", "0", "--host", "127.0.0.1", "--sim-speed", "20"])
    hub = hub_main.Hub(args, {"hdmi": {}})

    async def run():
        try:
            await asyncio.wait_for(hub.main(), 3.0)
        except asyncio.TimeoutError:
            pass
    asyncio.run(run())
    frames = hub.display.frames
    assert frames and frames[0][0] == (1280, 720)
    assert 2 <= len(frames) < 30 * 3                          # drawn when something changed, not on every 1/30 s tick
