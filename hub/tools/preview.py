#!/usr/bin/env python3
"""Renders every OLED page with sample data into one contact sheet:  python tools/preview.py out.png [--height 32]"""
import argparse
import os
import sys
import tempfile
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from PIL import Image, ImageDraw  # noqa: E402

from crewhub.pages import PAGES, Nav, handle, render  # noqa: E402
from crewhub.protocol import Frame  # noqa: E402
from crewhub.serial_link import FakeUno  # noqa: E402
from crewhub.state import HubState  # noqa: E402
from crewhub.store import Store  # noqa: E402


def sample_state(spike: bool = False) -> HubState:
    st = HubState(Store(os.path.join(tempfile.mkdtemp(), "p.db")))
    uno = FakeUno(None, None, seed=3)
    t0 = time.time() - 1800
    for i in range(1800):
        f = uno.frame()
        if spike and i > 1700:
            f.values["rad_dose_rate"] = 0.10 + (i - 1700) * 0.05
        st.on_frame(f, ts=t0 + i)
    st.uno_connected = True
    st.clients[1] = None
    m = {
        "heart_rate_resting": {"label": "Resting HR", "unit": "bpm", "decimals": 0, "group": "Heart", "value": 66, "usual": 57, "level": 1,
                               "spark": [56, 57, 58, 57, 56, 58, 57, 59, 60, 61, 63, 64, 66, 66]},
        "hrv": {"label": "HRV", "unit": "ms", "decimals": 0, "group": "Heart", "value": 37, "usual": 51, "level": 1, "spark": [52, 50, 51, 49, 47, 45, 41, 40, 38, 37]},
        "spo2": {"label": "Blood oxygen", "unit": "%", "decimals": 0, "group": "Breathing", "value": 97, "usual": 97, "level": 0},
        "resp_rate": {"label": "Breathing rate", "unit": "breaths/min", "decimals": 0, "group": "Breathing", "value": 15, "level": 0},
        "body_temp": {"label": "Body temp", "unit": "°C", "decimals": 1, "group": "Immune", "value": 36.7, "level": 0},
        "bp_sys": {"label": "Blood pressure", "unit": "mmHg", "decimals": 0, "group": "Heart", "value": 121, "pair": 78, "level": 0},
        "vo2max": {"label": "VO2 max", "unit": "mL/kg/min", "decimals": 1, "group": "Heart", "value": 44.5, "level": 0},
        "sleep_hours": {"label": "Sleep", "unit": "h", "decimals": 1, "group": "Sleep & mind", "value": 5.7, "usual": 8.2, "level": 3},
        "sleep_deep_h": {"label": "Deep sleep", "unit": "h", "decimals": 1, "group": "Sleep & mind", "value": 0.8, "level": 0},
        "activity_steps": {"label": "Steps", "unit": "steps", "decimals": 0, "group": "Activity", "value": 8432, "level": 0},
        "active_kcal": {"label": "Active energy", "unit": "kcal", "decimals": 0, "group": "Activity", "value": 512, "level": 0},
        "exercise_min": {"label": "Exercise", "unit": "min", "decimals": 0, "group": "Activity", "value": 42, "level": 0},
        "mood": {"label": "Mood", "unit": "1–5", "decimals": 0, "group": "Sleep & mind", "value": 3, "level": 0},
        "protein_g": {"label": "Protein", "unit": "g", "decimals": 0, "group": "Nutrition", "value": 96, "level": 0},
        "walking_speed": {"label": "Walking speed", "unit": "m/s", "decimals": 2, "group": "Mobility", "value": 1.31, "level": 0},
    }
    st.set_snapshot("dev:david", {"person": {"id": "david", "name": "David"}, "mission": {"day": 44},
                                  "overall": {"level": 3, "title": "Contact flight surgeon"},
                                  "alerts": [{"key": "metric:sleep_hours|2026-11-14", "text": "Sleep 2.5 h below usual"}],
                                  "metrics": m}, current=True)
    return st


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--height", type=int, default=64)
    a = ap.parse_args()
    st = sample_state()
    net = {"host": "crewhub", "ip": "192.168.1.42", "port": 8765, "token": "K7Q2MX", "records": 48210}
    frames = []
    for name in PAGES:
        nav = Nav()
        nav.go(name)
        frames.append((name, render(st, nav, (128, a.height), now=time.time() // 2 * 2 + 0.75, net=net)))
    for name, key in (("cabin", "co2"), ("vitals", "heart_rate_resting")):
        nav = Nav(); nav.go(name)
        while handle(nav, "P", st) is not None or nav.detail is None:
            break
        nav.detail = key
        frames.append((name + " › detail", render(st, nav, (128, a.height), now=time.time() // 2 * 2 + 0.75, net=net)))
    scale, pad, cols = 3, 14, 4
    w, h = 128 * scale, a.height * scale
    rows = (len(frames) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * (w + pad) + pad, rows * (h + pad + 12) + pad), (40, 40, 44))
    d = ImageDraw.Draw(sheet)
    for i, (name, img) in enumerate(frames):
        x, y = pad + (i % cols) * (w + pad), pad + (i // cols) * (h + pad + 12)
        d.text((x, y), name, fill=(200, 200, 200))
        big = img.convert("RGB").resize((w, h), Image.NEAREST)
        big = Image.eval(big, lambda p: 255 if p else 0)
        tinted = Image.new("RGB", big.size, (0, 0, 0))
        tinted.paste((120, 200, 255), mask=big.convert("L"))
        sheet.paste(tinted, (x, y + 12))
    sheet.save(a.out)
    print(a.out)


if __name__ == "__main__":
    main()
