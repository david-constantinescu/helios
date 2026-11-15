"""The Helios start-up logo, shown from the first seconds of boot.

    python -m crewhub.splash --make /opt/crewhub/splash.fb     # renders the logo in the screen's own pixel format (run on the Pi)

The installer then installs helios-splash.service, which copies that file straight into /dev/fb0 as soon as the display
exists — no Python, no waiting for the hub.
"""
import argparse
import sys

from PIL import Image

from .fb_fast import pack, read_fb_info
from .hdmi_pages import splash_image


def make(path: str, dev: str = "/dev/fb0") -> str:
    info = read_fb_info(dev)
    img = splash_image((1280, round(1280 * info.height / info.width))).resize((info.width, info.height), Image.BILINEAR)
    data = pack(img, info.bpp)
    if info.stride != info.width * info.bpp // 8:                     # pad every row to the framebuffer's stride
        row = info.width * info.bpp // 8
        data = b"".join(data[i * row:(i + 1) * row].ljust(info.stride, b"\0") for i in range(info.height))
    with open(path, "wb") as f:
        f.write(data)
    return f"{info.width},{info.height} {info.bpp} {info.stride}"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--make", required=True)
    ap.add_argument("--dev", default="/dev/fb0")
    a = ap.parse_args()
    try:
        print(make(a.make, a.dev))
    except (OSError, ValueError) as e:
        print("no framebuffer:", e, file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
