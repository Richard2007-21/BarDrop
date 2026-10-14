"""Erzeugt Resources/AppIcon.png (1024 x 1024) für BarDrop.

Dunkle Kachel im macOS-Raster, rechts eine tiefschwarze Ablage, die mit
konkaven Rundungen am Rand sitzt, darin zwei Dokumente.
Benötigt Pillow: pip install pillow
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

S = 4  # Supersampling
N = 1024 * S


def squircle_mask(size, inset, radius):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle((inset, inset, size - inset, size - inset), radius=radius, fill=255)
    return m


def main():
    out = Path(__file__).resolve().parent.parent / "Resources" / "AppIcon.png"
    inset = 100 * S
    radius = 185 * S

    # Hintergrund: weicher Verlauf von Graphit nach Blau-Grau
    bg = Image.new("RGB", (N, N))
    top, bottom = (74, 84, 104), (22, 25, 33)
    px = ImageDraw.Draw(bg)
    for y in range(N):
        t = y / (N - 1)
        c = tuple(int(top[i] * (1 - t) + bottom[i] * t) for i in range(3))
        px.line([(0, y), (N, y)], fill=c)

    tile = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    tile.paste(bg, (0, 0), squircle_mask(N, inset, radius))

    # Schatten der Kachel
    shadow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    sm = squircle_mask(N, inset, radius).point(lambda v: int(v * 0.45))
    shadow.putalpha(sm)
    shadow = shadow.transform(shadow.size, Image.AFFINE, (1, 0, 0, 0, 1, -14 * S))
    shadow = shadow.filter(ImageFilter.GaussianBlur(28 * S))

    canvas = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    canvas.alpha_composite(shadow)
    canvas.alpha_composite(tile)

    # Ablage am rechten Rand der Kachel
    edge_x = N - inset
    w, h, f, r = 360 * S, 560 * S, 50 * S, 96 * S
    cy = N // 2
    top_y, bot_y = cy - h // 2, cy + h // 2
    blob = Image.new("L", (N, N), 0)
    d = ImageDraw.Draw(blob)
    d.rounded_rectangle((edge_x - w, top_y + f, edge_x + 2 * r, bot_y - f), radius=r, fill=255)
    # konkave Übergänge zum Rand
    d.rectangle((edge_x - f, top_y, edge_x, top_y + f), fill=255)
    d.ellipse((edge_x - 2 * f, top_y - f, edge_x, top_y + f), fill=0)
    d.rectangle((edge_x - f, bot_y - f, edge_x, bot_y), fill=255)
    d.ellipse((edge_x - 2 * f, bot_y - f, edge_x, bot_y + f), fill=0)
    blob = Image.composite(blob, Image.new("L", (N, N), 0), squircle_mask(N, inset, radius))

    blob_shadow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    blob_shadow.putalpha(blob.point(lambda v: int(v * 0.55)).filter(ImageFilter.GaussianBlur(26 * S)))
    canvas.alpha_composite(blob_shadow)
    black = Image.new("RGBA", (N, N), (0, 0, 0, 255))
    canvas.paste(black, (0, 0), blob)

    # Zwei Dokumente in der Ablage
    def doc(cx, cy_, angle, shade):
        dw, dh = 150 * S, 190 * S
        layer = Image.new("RGBA", (N, N), (0, 0, 0, 0))
        ld = ImageDraw.Draw(layer)
        box = (cx - dw // 2, cy_ - dh // 2, cx + dw // 2, cy_ + dh // 2)
        ld.rounded_rectangle(box, radius=22 * S, fill=(shade, shade, shade, 255))
        for i in range(3):
            y = box[1] + 52 * S + i * 34 * S
            ld.rounded_rectangle((box[0] + 26 * S, y, box[2] - (26 + i * 22) * S, y + 12 * S),
                                 radius=6 * S, fill=(150, 156, 168, 255))
        layer = layer.rotate(angle, center=(cx, cy_), resample=Image.BICUBIC)
        sh = Image.new("RGBA", (N, N), (0, 0, 0, 0))
        sh.putalpha(layer.getchannel("A").point(lambda v: int(v * 0.6)).filter(ImageFilter.GaussianBlur(10 * S)))
        canvas.alpha_composite(sh)
        canvas.alpha_composite(layer)

    doc_x = edge_x - w // 2 + 10 * S
    doc(doc_x - 18 * S, cy + 20 * S, 9, 210)
    doc(doc_x + 14 * S, cy - 18 * S, -6, 248)

    canvas = canvas.resize((1024, 1024), Image.LANCZOS)
    out.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(out)
    print(f"Icon geschrieben: {out}")


if __name__ == "__main__":
    main()
