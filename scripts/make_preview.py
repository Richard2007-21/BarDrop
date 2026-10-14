"""Erzeugt docs/preview.gif als nahtlose Schleife:

1. Auf dem Schreibtisch liegt eine Datei. Sie wird an den rechten Rand gezogen,
   die Ablage erscheint in drei Stufen und nimmt sie auf.
2. Ein Programm (Mail) öffnet sich im Vollbild.
3. Am Rand öffnet sich die Ablage wieder, die Datei wird in die E-Mail gezogen.
4. Das Programm schließt sich, der Zeiger steht wieder am Ausgangspunkt.

Nachgebaut mit denselben Maßen und derselben Form wie in der App
(EdgeBlobShape, ShelfMetrics). Benötigt Pillow: pip install pillow
"""
import math
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 760, 440
S = 2                      # Supersampling
EDGE = W                   # rechter Bildschirmrand
CY = H // 2 + 10           # Höhe der Ablage
FPS_MS = 33

# Zustände wie ShelfMetrics: Breite, Länge, Eckradius, Übergang
# Wie in der App: flacher Streifen, der sich bei „Automatisch“ direkt zur Ablage öffnet
HIDDEN = (0, 36, 4, 6)
PEEK = (8, 64, 4, 6)
HINT = PEEK
OPEN = (240, 300, 26, 14)  # verkleinert, damit es ins Bild passt


def lerp(a, b, t):
    return a + (b - a) * t


def spring(t, damping=0.7):
    """Gedämpfte Feder wie SwiftUI .spring (Ausschwingen über 1)."""
    if t <= 0:
        return 0.0
    if t >= 1:
        return 1.0
    zeta = damping
    w = 9.0
    wd = w * math.sqrt(1 - zeta * zeta)
    return 1 - math.exp(-zeta * w * t) * (math.cos(wd * t) + zeta * w / wd * math.sin(wd * t))


def ease_out(t):
    """Schließen ohne Nachschwingen, damit kein Rest am Rand stehen bleibt."""
    t = max(0.0, min(1.0, t))
    return 1 - (1 - t) ** 3


def ease(t):
    return 0.5 - 0.5 * math.cos(math.pi * max(0, min(1, t)))


def cubic(p0, c1, c2, p3, n=24):
    out = []
    for i in range(n + 1):
        t = i / n
        mt = 1 - t
        out.append((mt**3 * p0[0] + 3 * mt * mt * t * c1[0] + 3 * mt * t * t * c2[0] + t**3 * p3[0],
                    mt**3 * p0[1] + 3 * mt * mt * t * c1[1] + 3 * mt * t * t * c2[1] + t**3 * p3[1]))
    return out


def blob(width, height, radius, fillet, cy):
    """Gleiche Geometrie wie EdgeBlobShape (rechter Rand)."""
    if width < 2:
        return None
    h = height + 2 * fillet
    top, bottom = cy - h / 2, cy + h / 2
    max_fy = max(0, min(fillet, h / 4))
    r = max(0, min(radius, (h - 2 * max_fy) / 2, width))
    fx = max(0, min(fillet, width - r))
    fy = min(max_fy, fx * 1.25)
    bt, bb = top + fy, bottom - fy
    k = 0.5523
    ex, ix = EDGE, EDGE - width
    pts = [(ex, top)]
    pts += cubic((ex, top), (ex, top + k * fy), (ex - fx + k * fx, bt), (ex - fx, bt))
    pts += cubic((ix + r, bt), (ix + r - k * r, bt), (ix, bt + r - k * r), (ix, bt + r))
    pts += cubic((ix, bb - r), (ix, bb - r + k * r), (ix + r - k * r, bb), (ix + r, bb))
    pts += cubic((ex - fx, bb), (ex - fx + k * fx, bb), (ex, bottom - k * fy), (ex, bottom))
    return [(x * S, y * S) for x, y in pts]


def font(size, bold=False):
    names = ["/System/Library/Fonts/SFNS.ttf",
             "/usr/share/fonts/opentype/inter/Inter-SemiBold.otf" if bold
             else "/usr/share/fonts/opentype/inter/Inter-Medium.otf",
             "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf" if bold
             else "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"]
    for n in names:
        try:
            return ImageFont.truetype(n, size * S)
        except OSError:
            pass
    return ImageFont.load_default()


def wallpaper():
    img = Image.new("RGB", (W * S, H * S))
    d = ImageDraw.Draw(img)
    top, bottom = (78, 96, 150), (196, 126, 140)
    for y in range(H * S):
        t = y / (H * S)
        d.line([(0, y), (W * S, y)], fill=tuple(int(lerp(top[i], bottom[i], t)) for i in range(3)))
    glow = Image.new("RGB", (W * S, H * S), (0, 0, 0))
    ImageDraw.Draw(glow).ellipse((W * S * 0.1, H * S * 0.2, W * S * 0.7, H * S * 1.2), fill=(250, 190, 120))
    glow = glow.filter(ImageFilter.GaussianBlur(120))
    img = Image.blend(img, Image.composite(glow, img, glow.convert("L")), 0.35)
    d = ImageDraw.Draw(img)
    d.rectangle((0, 0, W * S, 24 * S), fill=(232, 232, 236))
    d.text((14 * S, 5 * S), "  Finder   Ablage   Bearbeiten   Darstellung", font=font(11), fill=(40, 40, 44))
    return img


def doc_icon(scale=1.0, color=(236, 240, 246), accent=(90, 140, 230)):
    w, h = int(44 * scale * S), int(56 * scale * S)
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle((0, 0, w - 1, h - 1), radius=int(6 * scale * S), fill=color)
    d.rectangle((int(w * 0.18), int(h * 0.22), int(w * 0.82), int(h * 0.58)), fill=accent)
    for i in range(2):
        y = int(h * (0.68 + i * 0.12))
        d.rounded_rectangle((int(w * 0.18), y, int(w * (0.82 - i * 0.2)), y + int(3 * S)), radius=S, fill=(170, 176, 188))
    return im


def paste_shadowed(base, icon, x, y):
    sh = Image.new("RGBA", icon.size, (0, 0, 0, 0))
    sh.putalpha(icon.getchannel("A").point(lambda v: int(v * 0.35)))
    sh = sh.filter(ImageFilter.GaussianBlur(6))
    base.alpha_composite(sh, (int(x), int(y + 4 * S)))
    base.alpha_composite(icon, (int(x), int(y)))


def cursor(base, x, y):
    d = ImageDraw.Draw(base)
    p = [(x, y), (x, y + 18 * S), (x + 5 * S, y + 13.5 * S), (x + 12.5 * S, y + 13 * S)]
    d.polygon(p, fill=(0, 0, 0), outline=(255, 255, 255))


def shelf_content(base, state, open_t, items, highlight, target_action):
    """Inhalt der offenen Ablage, eingeblendet mit Unschärfe wie in der App."""
    w, h = OPEN[0], OPEN[1]
    x0, y0 = EDGE - w, CY - h / 2
    layer = Image.new("RGBA", base.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    white = lambda a: (255, 255, 255, int(255 * a))
    if highlight:
        d.rounded_rectangle(((x0 + 8) * S, (y0 + 8) * S, (EDGE - 8) * S, (y0 + h - 8) * S),
                            radius=20 * S, outline=white(0.28), width=int(1.5 * S), fill=white(0.05))
    d.text(((x0 + 18) * S, (y0 + 14) * S), "Ablage", font=font(12, True), fill=white(0.92))
    count = len(items)
    if count:
        label = "1 Objekt" if count == 1 else f"{count} Objekte"
        tw = d.textlength(label, font=font(10))
        d.text(((EDGE - 18) * S - tw, (y0 + 16) * S), label, font=font(10), fill=white(0.45))
    # Kacheln
    for i, (name, accent) in enumerate(items):
        col, row = i % 3, i // 3
        tx = x0 + 18 + col * 76
        ty = y0 + 44 + row * 92
        icon = doc_icon(0.9, accent=accent)
        layer.alpha_composite(icon, (int((tx + 14) * S), int(ty * S)))
        tw = d.textlength(name, font=font(9))
        d.text(((tx + 34) * S - tw / 2, (ty + 56) * S), name, font=font(9), fill=white(0.88))
    if not items:
        msg = "Hier ablegen"
        tw = d.textlength(msg, font=font(12, True))
        d.text(((x0 + w / 2) * S - tw / 2, (CY - 10) * S), msg, font=font(12, True), fill=white(0.85))
    # Aktionsleiste
    by = y0 + h - 64
    acts = [("AirDrop", (60, 150, 245)), ("Downloads", (70, 150, 240))]
    step = (w - 20) / len(acts)
    for i, (label, col) in enumerate(acts):
        cx = x0 + 10 + step * (i + 0.5)
        if target_action == i:
            d.rounded_rectangle(((cx - step / 2 + 3) * S, (by + 3) * S, (cx + step / 2 - 3) * S, (by + 51) * S),
                                radius=11 * S, fill=white(0.12))
        size = 26 if target_action != i else 29
        d.rounded_rectangle(((cx - size / 2) * S, (by + 7) * S, (cx + size / 2) * S, (by + 7 + size) * S),
                            radius=int(size * 0.23 * S), fill=col)
        tw = d.textlength(label, font=font(8))
        d.text((cx * S - tw / 2, (by + 38) * S), label, font=font(8), fill=white(0.7))
    blur = (1 - open_t) * 14
    if blur > 0.3:
        layer = layer.filter(ImageFilter.GaussianBlur(blur * S))
    a = layer.getchannel("A").point(lambda v: int(v * open_t))
    layer.putalpha(a)
    base.alpha_composite(layer)


def lerp_state(a, b, t):
    return tuple(lerp(a[i], b[i], t) for i in range(4))


DESK_FILE = (78, 70)          # Datei auf dem Schreibtisch (links oben)
GRAB = (22, 30)               # Zeiger relativ zur gezogenen Datei
DROP_IN_MAIL = (300, 300)     # Ablageort im Mail-Fenster (Datei links oben)
P0 = (DROP_IN_MAIL[0] + GRAB[0], DROP_IN_MAIL[1] + GRAB[1])   # Start = Ende der Schleife


def desktop_file(base, dim):
    icon = doc_icon(1.0, accent=(220, 80, 70))
    if dim:
        icon.putalpha(icon.getchannel("A").point(lambda v: v // 2))
    paste_shadowed(base, icon, DESK_FILE[0] * S, DESK_FILE[1] * S)
    d = ImageDraw.Draw(base)
    label = "Bericht.pdf"
    tw = d.textlength(label, font=font(10, True))
    cx = (DESK_FILE[0] + 22) * S
    d.text((cx - tw / 2, (DESK_FILE[1] + 62) * S), label, font=font(10, True), fill=(255, 255, 255, 235))


def fullscreen_mail(base, progress, attached, highlight):
    """Mail im Vollbild. `progress` 0…1 steuert das Öffnen (Zoom wie bei macOS)."""
    if progress <= 0.001:
        return
    t = ease(progress)
    layer = Image.new("RGBA", base.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    WS, HS = W * S, H * S
    d.rectangle((0, 0, WS, HS), fill=(250, 250, 252, 255))
    # Symbolleiste
    d.rectangle((0, 0, WS, 46 * S), fill=(240, 240, 244, 255))
    d.line((0, 46 * S, WS, 46 * S), fill=(222, 222, 228), width=S)
    d.text((24 * S, 14 * S), "Neue E-Mail", font=font(14, True), fill=(40, 40, 46))
    d.rounded_rectangle((WS - 120 * S, 11 * S, WS - 28 * S, 35 * S), radius=8 * S, fill=(0, 122, 255))
    d.text((WS - 98 * S, 15 * S), "Senden", font=font(11, True), fill=(255, 255, 255))
    # Felder
    for i, (k, v) in enumerate([("An:", "Lena Bauer"), ("Betreff:", "Bericht")]):
        y = (62 + i * 34) * S
        d.text((24 * S, y), k, font=font(11), fill=(140, 140, 148))
        d.text((90 * S, y), v, font=font(11), fill=(40, 40, 46))
        d.line((24 * S, y + 24 * S, WS - 24 * S, y + 24 * S), fill=(230, 230, 234), width=S)
    d.text((24 * S, 142 * S), "Hallo Lena,", font=font(11), fill=(40, 40, 46))
    d.text((24 * S, 162 * S), "anbei der Bericht.", font=font(11), fill=(40, 40, 46))
    if highlight:
        d.rounded_rectangle((16 * S, 196 * S, WS - 16 * S, HS - 16 * S), radius=12 * S,
                            outline=(0, 122, 255, 255), width=2 * S, fill=(0, 122, 255, 20))
    if attached > 0:
        a = int(255 * min(1, attached))
        icon = doc_icon(0.9, accent=(220, 80, 70))
        icon.putalpha(icon.getchannel("A").point(lambda v: v * a // 255))
        x, y = DROP_IN_MAIL[0] * S, DROP_IN_MAIL[1] * S
        layer.alpha_composite(icon, (int(x), int(y)))
        d.text((x + 50 * S, y + 12 * S), "Bericht.pdf", font=font(11, True), fill=(40, 40, 46, a))
        d.text((x + 50 * S, y + 30 * S), "248 KB", font=font(10), fill=(130, 130, 138, a))

    # Zoom aus der Mitte heraus
    if t < 0.999:
        scale = lerp(0.35, 1.0, t)
        w, h = int(WS * scale), int(HS * scale)
        layer = layer.resize((max(1, w), max(1, h)), Image.LANCZOS)
        mask = Image.new("L", layer.size, 0)
        ImageDraw.Draw(mask).rounded_rectangle((0, 0, w - 1, h - 1), radius=int(lerp(18, 0, t) * S), fill=255)
        layer.putalpha(Image.composite(layer.getchannel("A"), Image.new("L", layer.size, 0), mask))
        framed = Image.new("RGBA", base.size, (0, 0, 0, 0))
        framed.alpha_composite(layer, ((WS - w) // 2, (HS - h) // 2))
        layer = framed
    layer.putalpha(layer.getchannel("A").point(lambda v: int(v * min(1, t * 1.6))))
    base.alpha_composite(layer)


def render():
    bg = wallpaper().convert("RGBA")
    frames = []
    timeline = []

    def add(n, fn):
        timeline.append((n, fn))

    def move(a, b, t):
        k = ease(t)
        return (lerp(a[0], b[0], k), lerp(a[1], b[1], k))

    tile = (EDGE - OPEN[0] + 32, CY - OPEN[1] / 2 + 44)          # Kachel in der offenen Ablage
    tile_c = (tile[0] + GRAB[0], tile[1] + GRAB[1])
    grab_desk = (DESK_FILE[0] + GRAB[0], DESK_FILE[1] + GRAB[1])
    near_edge = (430, CY)
    nearer = (620, CY)
    outside = (430, 250)

    # --- Teil 1: vom Schreibtisch in die Ablage ---
    add(12, lambda t: dict(state=HIDDEN, cur=P0))
    add(16, lambda t: dict(state=HIDDEN, cur=move(P0, grab_desk, t)))
    add(14, lambda t: dict(state=lerp_state(HIDDEN, PEEK, spring(t)), cur=move(grab_desk, near_edge, t), drag=True))
    add(12, lambda t: dict(state=lerp_state(PEEK, HINT, spring(t)), cur=move(near_edge, nearer, t), drag=True))
    add(18, lambda t: dict(state=lerp_state(HINT, OPEN, spring(t)), open=max(0, (t - 0.2) / 0.8),
                           cur=move(nearer, tile_c, t), drag=True, highlight=t > 0.55))
    add(6, lambda t: dict(state=OPEN, open=1, cur=tile_c, drag=True, drop=t, highlight=True))
    add(10, lambda t: dict(state=OPEN, open=1, items=1, cur=move(tile_c, (EDGE - 120, CY + 40), t)))
    add(14, lambda t: dict(state=lerp_state(OPEN, HIDDEN, ease_out(t)), open=max(0, 1 - t * 2.5), items=1,
                           cur=move((EDGE - 120, CY + 40), outside, t)))

    # --- Teil 2: Programm öffnet sich im Vollbild ---
    add(14, lambda t: dict(state=HIDDEN, app=t, cur=outside))
    add(6, lambda t: dict(state=HIDDEN, app=1, cur=outside))

    # --- Teil 3: Ablage am Rand öffnen und Datei in die E-Mail ziehen ---
    add(12, lambda t: dict(state=HIDDEN, app=1, cur=move(outside, (EDGE - 3, CY), t)))
    add(7, lambda t: dict(state=lerp_state(HIDDEN, PEEK, spring(t)), app=1, cur=(EDGE - 3, CY)))
    add(7, lambda t: dict(state=lerp_state(PEEK, HINT, spring(t)), app=1, cur=(EDGE - 5, CY)))
    add(14, lambda t: dict(state=lerp_state(HINT, OPEN, spring(t)), open=max(0, (t - 0.2) / 0.8), items=1, app=1,
                           cur=move((EDGE - 5, CY), (EDGE - 60, CY), t)))
    add(10, lambda t: dict(state=OPEN, open=1, items=1, app=1, cur=move((EDGE - 60, CY), tile_c, t)))

    def drag_out(t):
        leave = max(0.0, (t - 0.2) / 0.8)          # Ablage schließt, sobald der Zeiger draußen ist
        return dict(state=lerp_state(OPEN, HIDDEN, ease_out(leave)), open=max(0, 1 - leave * 2.5), items=1,
                    app=1, cur=move(tile_c, P0, t), drag=True, mail_highlight=t > 0.7)
    add(26, drag_out)
    add(6, lambda t: dict(state=HIDDEN, app=1, cur=P0, drag=True, drop=t, mail_highlight=True, attached=t))
    add(18, lambda t: dict(state=HIDDEN, app=1, attached=1, cur=P0))

    # --- Teil 4: Programm schließt, zurück zum Anfang ---
    add(14, lambda t: dict(state=HIDDEN, app=1 - t, attached=1, cur=P0))

    items_all = [("Bericht.pdf", (220, 80, 70))]
    ghost = doc_icon(1.0, accent=(220, 80, 70))

    for n, fn in timeline:
        for i in range(n):
            t = i / max(1, n - 1)
            sc = fn(t)
            img = bg.copy()
            dragging_from_desk = sc.get("drag") and sc.get("app", 0) == 0 and sc.get("items", 0) == 0
            desktop_file(img, dim=dragging_from_desk)
            fullscreen_mail(img, sc.get("app", 0), sc.get("attached", 0), sc.get("mail_highlight", False))

            st = sc["state"]
            pts = blob(st[0], st[1], st[2], st[3], CY)
            if pts:
                if st[0] > 120:
                    sh = Image.new("RGBA", img.size, (0, 0, 0, 0))
                    ImageDraw.Draw(sh).polygon(pts, fill=(0, 0, 0, int(140 * min(1, (st[0] - 120) / 100))))
                    img.alpha_composite(sh.filter(ImageFilter.GaussianBlur(22 * S)), (0, 10 * S))
                ImageDraw.Draw(img).polygon(pts, fill=(0, 0, 0, 255))
                if sc.get("open", 0) > 0.02:
                    mask = Image.new("L", img.size, 0)
                    ImageDraw.Draw(mask).polygon(pts, fill=255)
                    content = Image.new("RGBA", img.size, (0, 0, 0, 0))
                    shelf_content(content, st, min(1, sc["open"]), items_all[: sc.get("items", 0)],
                                  sc.get("highlight", False), None)
                    content.putalpha(Image.composite(content.getchannel("A"), Image.new("L", img.size, 0), mask))
                    img.alpha_composite(content)

            cx, cy = sc["cur"]
            if sc.get("drag"):
                gx, gy = cx - GRAB[0], cy - GRAB[1]
                if "drop" in sc:
                    k = 1 - 0.5 * sc["drop"]
                    g = ghost.resize((max(1, int(ghost.width * k)), max(1, int(ghost.height * k))))
                    g.putalpha(g.getchannel("A").point(lambda v: int(v * (1 - sc["drop"]))))
                    paste_shadowed(img, g, gx * S, gy * S)
                else:
                    paste_shadowed(img, ghost, gx * S, gy * S)
            cursor(img, cx * S, cy * S)
            frames.append(img.resize((W, H), Image.LANCZOS).convert("RGB"))

    # Das letzte Bild entspricht dem ersten: weglassen, damit die Schleife nicht stockt
    return frames[:-1]


def save(frames):
    out = Path(__file__).resolve().parent.parent / "docs" / "preview.gif"
    out.parent.mkdir(exist_ok=True)
    pal = [f.convert("P", palette=Image.ADAPTIVE, colors=224) for f in frames]
    pal[0].save(out, save_all=True, append_images=pal[1:], duration=FPS_MS, loop=0)
    print(f"{len(frames)} Bilder -> {out} ({out.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    save(render())
