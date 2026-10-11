"""Draw the North Star app icon (1024 x 1024 PNG).

A person on a rock by still water looks up at the North Star, shining bright
among dimmer stars, above a mountain silhouette at night.

Drawn at 4x size and scaled down for smooth edges. iOS rounds the corners
itself, so the picture fills the whole square and has no transparency.

Run from the project root (needs Pillow, which the backend's environment has):
    Backend/.venv/bin/python "iOS/Design/make_app_icon.py"
"""

import math
import random
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

SIZE = 1024
S = 4                      # draw at 4x, then scale down
W = SIZE * S
HORIZON = 0.665            # where the water meets the land, as a share of the height
STAR = (0.635, 0.255)      # the North Star's position
OUT = Path(__file__).resolve().parent.parent / "North Star" / "North Star" / "Assets.xcassets" / "AppIcon.appiconset"


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def sky() -> Image.Image:
    """Deep navy at the top, fading to a soft blue glow at the horizon."""
    top, middle, low = (4, 7, 22), (14, 22, 54), (52, 66, 112)
    image = Image.new("RGB", (W, W))
    draw = ImageDraw.Draw(image)
    for y in range(W):
        t = y / (W * HORIZON)
        colour = lerp(top, middle, min(1, t / 0.6)) if t < 0.6 else lerp(middle, low, min(1, (t - 0.6) / 0.4))
        draw.line([(0, y), (W, y)], fill=colour)
    return image


def dim_stars(image: Image.Image) -> None:
    random.seed(7)
    layer = Image.new("RGB", (W, W))
    draw = ImageDraw.Draw(layer)
    for _ in range(95):
        x, y = random.random() * W, random.random() * W * 0.55
        if math.dist((x, y), (STAR[0] * W, STAR[1] * W)) < 150 * S:
            continue  # keep the space around the North Star clear
        r = random.choice([1.2, 1.5, 1.8, 2.4, 3.0]) * S
        b = random.randint(70, 175)
        draw.ellipse([x - r, y - r, x + r, y + r], fill=(b, b, min(255, b + 25)))
    image.paste(ImageChops.add(image, layer.filter(ImageFilter.GaussianBlur(0.6 * S))))


def north_star(image: Image.Image) -> None:
    """A white-hot centre, a soft glow, and four long tapering rays (plus four short ones)."""
    cx, cy = STAR[0] * W, STAR[1] * W
    glow = Image.new("RGB", (W, W))
    draw = ImageDraw.Draw(glow)
    for radius, colour in [(230, (24, 30, 58)), (150, (46, 54, 92)), (90, (90, 98, 140)), (48, (170, 175, 210))]:
        r = radius * S
        draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=colour)
    glow = glow.filter(ImageFilter.GaussianBlur(40 * S))

    rays = Image.new("RGB", (W, W))
    draw = ImageDraw.Draw(rays)
    for angle, length, width in [(0, 300, 9), (90, 300, 9), (180, 300, 9), (270, 230, 9),
                                 (45, 95, 5), (135, 95, 5), (225, 95, 5), (315, 95, 5)]:
        a = math.radians(angle)
        tip = (cx + math.cos(a) * length * S, cy + math.sin(a) * length * S)
        side = (math.cos(a + math.pi / 2) * width * S, math.sin(a + math.pi / 2) * width * S)
        draw.polygon([(cx + side[0], cy + side[1]), tip, (cx - side[0], cy - side[1])], fill=(235, 236, 255))
    rays = rays.filter(ImageFilter.GaussianBlur(2.5 * S))

    core = Image.new("RGB", (W, W))
    draw = ImageDraw.Draw(core)
    for r, colour in [(30, (200, 205, 240)), (19, (245, 246, 255)), (12, (255, 255, 255))]:
        draw.ellipse([cx - r * S, cy - r * S, cx + r * S, cy + r * S], fill=colour)
    core = core.filter(ImageFilter.GaussianBlur(3 * S))

    for layer in (glow, rays, core):
        image.paste(ImageChops.add(image, layer))


def ridge(seed: int, base: float, height: float, peaks: list[tuple[float, float]], roughness: float) -> list[tuple[float, float]]:
    """A mountain outline: smooth peaks plus a little jaggedness, as points across the width."""
    random.seed(seed)
    points = []
    for i in range(161):
        x = i / 160
        y = base
        for px, ph in peaks:
            y -= ph * height * max(0.0, 1 - abs(x - px) / 0.32) ** 1.6
        y += (random.random() - 0.5) * roughness
        points.append((x * W, y * W))
    return points


def mountains(image: Image.Image) -> None:
    draw = ImageDraw.Draw(image)
    far = ridge(3, HORIZON, 0.22, [(0.18, 0.75), (0.47, 0.55), (0.86, 0.9)], 0.006)
    near = ridge(11, HORIZON, 0.17, [(0.05, 0.6), (0.36, 1.0), (0.72, 0.45), (1.0, 0.7)], 0.008)
    draw.polygon(far + [(W, HORIZON * W), (0, HORIZON * W)], fill=(30, 40, 78))
    draw.polygon(near + [(W, HORIZON * W), (0, HORIZON * W)], fill=(13, 18, 40))
    # A thin line of snow on the highest near peak, catching the starlight.
    peak = min(near, key=lambda p: p[1])
    draw.polygon([(peak[0], peak[1]), (peak[0] - 38 * S, peak[1] + 30 * S), (peak[0] - 12 * S, peak[1] + 24 * S),
                  (peak[0] + 6 * S, peak[1] + 34 * S), (peak[0] + 30 * S, peak[1] + 22 * S)], fill=(70, 82, 124))


def water(image: Image.Image) -> None:
    """Still water: the sky above mirrored and darkened, with the star's light on it."""
    h = int(HORIZON * W)
    above = image.crop((0, h - (W - h), W, h)).transpose(Image.FLIP_TOP_BOTTOM)
    dark = Image.new("RGB", above.size, (3, 6, 18))
    reflection = Image.blend(above, dark, 0.55).filter(ImageFilter.GaussianBlur(3 * S))
    image.paste(reflection, (0, h))
    draw = ImageDraw.Draw(image)
    # The star's light on the water: short shimmering strokes under it.
    random.seed(5)
    cx = STAR[0] * W
    glitter = Image.new("RGB", (W, W))
    gdraw = ImageDraw.Draw(glitter)
    for i in range(34):
        y = h + (10 + i * 9.5 + random.random() * 4) * S
        half = (62 - i * 1.4) * S * (0.35 + random.random() * 0.75)
        shift = (random.random() - 0.5) * 30 * S
        b = max(30, 200 - i * 5)
        gdraw.line([(cx + shift - half, y), (cx + shift + half, y)], fill=(b, b, min(255, b + 30)), width=int(2.4 * S))
    image.paste(ImageChops.add(image, glitter.filter(ImageFilter.GaussianBlur(1.6 * S))))
    # A clean line where water meets land.
    draw.line([(0, h), (W, h)], fill=(40, 50, 90), width=int(2 * S))


def traveller(image: Image.Image) -> None:
    """A rock in the foreground and a person standing on it, head tilted back to the star."""
    draw = ImageDraw.Draw(image)
    ink = (2, 3, 9)
    # The rock: from the left edge into the water.
    draw.polygon([(0, 0.80 * W), (0.10 * W, 0.775 * W), (0.21 * W, 0.79 * W), (0.30 * W, 0.84 * W),
                  (0.36 * W, 0.90 * W), (0.40 * W, 1.0 * W), (0, W)], fill=ink)
    # The person, about a fifth of the icon tall, facing the star.
    fx, feet = 0.205 * W, 0.787 * W
    u = 0.0105 * W  # one unit: the figure is about 19 units tall
    # Legs (slightly apart) and body.
    draw.polygon([(fx - 2.1 * u, feet), (fx - 1.0 * u, feet - 8.5 * u), (fx + 1.0 * u, feet - 8.5 * u),
                  (fx + 2.3 * u, feet), (fx + 1.2 * u, feet), (fx, feet - 5.5 * u), (fx - 1.0 * u, feet)], fill=ink)
    draw.polygon([(fx - 1.6 * u, feet - 8.5 * u), (fx - 1.3 * u, feet - 14.6 * u), (fx + 1.6 * u, feet - 15.0 * u),
                  (fx + 1.7 * u, feet - 8.5 * u)], fill=ink)
    # Arms down at the sides.
    draw.polygon([(fx - 1.4 * u, feet - 14.2 * u), (fx - 2.4 * u, feet - 9.0 * u), (fx - 1.6 * u, feet - 8.8 * u),
                  (fx - 0.8 * u, feet - 13.0 * u)], fill=ink)
    draw.polygon([(fx + 1.4 * u, feet - 14.4 * u), (fx + 2.5 * u, feet - 9.2 * u), (fx + 1.7 * u, feet - 9.0 * u),
                  (fx + 0.9 * u, feet - 13.0 * u)], fill=ink)
    # Neck and head, tilted back and towards the star.
    draw.polygon([(fx - 0.5 * u, feet - 14.8 * u), (fx + 0.2 * u, feet - 16.6 * u), (fx + 1.1 * u, feet - 16.3 * u),
                  (fx + 0.7 * u, feet - 14.8 * u)], fill=ink)
    # The head: an oval tilted back, so the face points up at the star.
    head = Image.new("L", (int(8 * u), int(8 * u)), 0)
    ImageDraw.Draw(head).ellipse([2.2 * u, 1.9 * u, 5.8 * u, 6.1 * u], fill=255)
    head = head.rotate(-35, resample=Image.BICUBIC, center=(4 * u, 4 * u))
    image.paste(Image.new("RGB", head.size, ink), (int(fx + 0.9 * u - 4 * u), int(feet - 17.6 * u - 4 * u)), head)


def main() -> None:
    image = sky()
    dim_stars(image)
    north_star(image)
    mountains(image)
    water(image)
    traveller(image)
    icon = image.resize((SIZE, SIZE), Image.LANCZOS)
    OUT.mkdir(parents=True, exist_ok=True)
    icon.save(OUT / "AppIcon.png")
    print("saved", OUT / "AppIcon.png")


if __name__ == "__main__":
    main()
