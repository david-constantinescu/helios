"""Helios mark as a 1-bit bitmap for the OLED splash (generated from brand/helios-mark.png)."""
import base64, io
from PIL import Image

_PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAEAAAAAwAQAAAACJMEGyAAAA4klEQVR4nFWQPU4EMQyFv5iRMsWK5AazR+AEMzdBHIGCcospKTnSiIJbII2oKLNUKSKC7GQXsKzYeXr+eQY1vyGWjMeeVHuBw0NHrhb2juRLUrb/jKW06Kq2EfNGCSkk+8aXr9GQGU6GzPDa2sKkiMvQyAnyyuA+3m+0s9zCAXiUOGx3urUcdysdOHltxywFnoCdFJrrqilrecLBSr7q+hWYArvv5DiSkOczMUKQN2By3LPUWourRXRmgSKfurWg4e8xu2YIlxHREr+qQMU3rRf4xoRBKEtTEmpt1d5uqDbp8j/p/EbYDuG3YwAAAABJRU5ErkJggg==")

def mark() -> Image.Image:
    return Image.open(io.BytesIO(_PNG)).convert("1")
