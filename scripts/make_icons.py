"""Regenerates every Photobank app icon from one design.

The mark is the wordmark's first letter: Bricolage Grotesque 800 "P" in ink with
the accent period, on paper (see THEME.md). One renderer produces:

  assets/icon/photobank.ico          Windows exe + window icon
  assets/icon/photobank.icns         macOS bundle icon
  assets/icon/photobank-256.png      tray / menu-bar icon
  web/public/favicon.ico, apple-touch-icon.png, icon-192.png, icon-512.png
  mobile/assets/icon/*.png           flutter_launcher_icons sources
  mobile/ios/.../AppIcon.appiconset  every size listed in Contents.json
  mobile/android/.../mipmap-*, drawable-*   legacy + adaptive launcher PNGs

The iOS/Android PNGs are written directly, so Flutter is not needed to refresh
the launcher icons. Run:  .\\scripts\\make-icons.ps1
"""

from __future__ import annotations

import json
import urllib.request
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "assets" / "icon"
FONT_CACHE = ROOT / "assets" / ".fontcache" / "BricolageGrotesque.ttf"
FONT_URL = (
    "https://github.com/ateliertriay/bricolage/raw/main/fonts/variable/"
    "BricolageGrotesque%5Bopsz%2Cwdth%2Cwght%5D.ttf"
)

# THEME.md tokens
PAPER = (255, 255, 255, 255)
INK = (16, 20, 24, 255)
ACCENT = (255, 74, 28, 255)
LINE2 = (185, 192, 200, 255)

SUPERSAMPLE = 4


def font_file() -> str:
    if not FONT_CACHE.is_file():
        FONT_CACHE.parent.mkdir(parents=True, exist_ok=True)
        print("downloading Bricolage Grotesque (SIL OFL) ...")
        urllib.request.urlretrieve(FONT_URL, FONT_CACHE)
    return str(FONT_CACHE)


def load_font(px: int) -> ImageFont.FreeTypeFont:
    f = ImageFont.truetype(font_file(), px)
    f.set_variation_by_axes([96, 800, 100])  # optical size, weight, width
    return f


_CAP_PER_PX: float | None = None


def cap_per_px() -> float:
    """Cap height of "P" as a fraction of the font size."""
    global _CAP_PER_PX
    if _CAP_PER_PX is None:
        _, top, _, _ = load_font(1000).getbbox("P", anchor="ls")
        _CAP_PER_PX = -top / 1000
    return _CAP_PER_PX


def draw_mark(img: Image.Image, box: tuple[float, float, float, float], cap_frac: float) -> None:
    """Draws "P." centred in box; the cap height is cap_frac of the box height."""
    d = ImageDraw.Draw(img)
    x0, y0, x1, y1 = box
    w, h = x1 - x0, y1 - y0
    px = int(round(cap_frac * h / cap_per_px()))
    f = load_font(px)

    tracking = -0.02 * px  # display tracking per THEME.md
    dot_x = f.getlength("P.") - f.getlength(".") + tracking  # keeps the pair's kerning
    p_l, p_t, _, _ = f.getbbox("P", anchor="ls")
    _, _, d_r, _ = f.getbbox(".", anchor="ls")
    group_w = (dot_x + d_r) - p_l
    cap = -p_t

    x = x0 + (w - group_w) / 2 - p_l
    baseline = y0 + (h + cap) / 2
    d.text((x, baseline), "P", font=f, fill=INK, anchor="ls")
    d.text((x + dot_x, baseline), ".", font=f, fill=ACCENT, anchor="ls")


def render(
    size: int,
    shape: str,
    *,
    cap_frac: float | None = None,
    radius: float = 0.0,
    border: bool = False,
    inset: float = 0.0,
) -> Image.Image:
    """One icon at `size` px.

    shape: "square" (paper, full bleed: iOS masks it), "rounded" (paper rounded
    rect, transparent outside; radius/inset are fractions of the canvas), or
    "foreground" (glyph only, transparent: Android adaptive foreground).
    """
    s = size * SUPERSAMPLE
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    m = inset * s
    shape_box = (m, m, s - 1 - m, s - 1 - m)
    if shape == "square":
        d.rectangle(shape_box, fill=PAPER)
    elif shape == "rounded":
        r = radius * (s - 2 * m)
        bw = max(SUPERSAMPLE, round(s * 0.005)) if border else 0
        d.rounded_rectangle(
            shape_box, radius=r, fill=PAPER, outline=LINE2 if border else None, width=bw
        )
    if cap_frac is None:
        cap_frac = 0.62 if size <= 32 else 0.50  # tiny sizes: bigger glyph, it has to read
    draw_mark(img, shape_box, cap_frac)
    return img.resize((size, size), Image.LANCZOS)


def save_png(img: Image.Image, path: Path, rgb: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    (img.convert("RGB") if rgb else img).save(path, "PNG", optimize=True)
    print(f"  {path.relative_to(ROOT).as_posix()}  {img.width}px")


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)

    print("master")
    master = render(1024, "square")
    save_png(master, OUT / "photobank-1024.png")
    save_png(render(1024, "rounded", radius=0.18, border=True), OUT / "photobank-rounded-1024.png")

    print("windows")
    win = {s: render(s, "rounded", radius=0.12, border=s >= 48) for s in (16, 20, 24, 32, 40, 48, 64, 128, 256)}
    win[256].save(
        OUT / "photobank.ico", format="ICO",
        sizes=[(s, s) for s in win], append_images=[win[s] for s in sorted(win) if s != 256],
    )
    print(f"  assets/icon/photobank.ico  {sorted(win)}")
    save_png(render(256, "rounded", radius=0.12, border=True), OUT / "photobank-256.png")

    print("macos")
    # Big Sur grid: the rounded square sits on a transparent margin (824 of 1024).
    mac = {s: render(s, "rounded", radius=0.2237, border=s >= 64, inset=0.0977) for s in (16, 32, 64, 128, 256, 512, 1024)}
    mac[1024].save(OUT / "photobank.icns", format="ICNS", append_images=[mac[s] for s in sorted(mac) if s != 1024])
    print(f"  assets/icon/photobank.icns  {sorted(mac)}")

    print("web")
    web = ROOT / "web" / "public"
    web.mkdir(parents=True, exist_ok=True)
    fav = {s: render(s, "rounded", radius=0.18) for s in (16, 32, 48)}
    fav[48].save(web / "favicon.ico", format="ICO", sizes=[(s, s) for s in fav], append_images=[fav[16], fav[32]])
    print(f"  web/public/favicon.ico  {sorted(fav)}")
    save_png(render(180, "square"), web / "apple-touch-icon.png", rgb=True)
    save_png(render(192, "square"), web / "icon-192.png")
    save_png(render(512, "square"), web / "icon-512.png")

    print("mobile sources")
    mobile = ROOT / "mobile"
    save_png(master, mobile / "assets" / "icon" / "icon.png")
    save_png(render(1024, "foreground"), mobile / "assets" / "icon" / "icon_foreground.png")

    print("ios")
    iconset = mobile / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
    manifest = json.loads((iconset / "Contents.json").read_text(encoding="utf-8"))
    done: set[str] = set()
    for entry in manifest["images"]:
        name = entry["filename"]
        if name in done:
            continue
        done.add(name)
        pt = float(entry["size"].split("x")[0])
        scale = int(entry["scale"].rstrip("x"))
        px = int(round(pt * scale))
        save_png(render(px, "square"), iconset / name, rgb=True)  # App Store icons must be opaque

    print("android")
    res = mobile / "android" / "app" / "src" / "main" / "res"
    for density, px in {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}.items():
        save_png(render(px, "rounded", radius=0.18, border=px >= 96), res / f"mipmap-{density}" / "ic_launcher.png")
    for density, px in {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}.items():
        save_png(render(px, "foreground"), res / f"drawable-{density}" / "ic_launcher_foreground.png")

    print("done")


if __name__ == "__main__":
    main()
