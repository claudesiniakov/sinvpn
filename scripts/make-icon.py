#!/usr/bin/env python3
"""Рисует иконку SinVpn (1024×1024 PNG): слово VPN в рамке на тёмном скруглённом квадрате.

Запуск: python3 scripts/make-icon.py [путь/к/AppIcon.png]
"""
import sys

from PIL import Image, ImageDraw, ImageFont

S = 4  # суперсэмплинг для сглаживания
N = 1024 * S
FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"


def main(out):
    img = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    pad = 100 * S
    # Фон: вертикальный переход от тёмно-бирюзового к почти чёрному.
    bg = Image.new("RGBA", (N, N))
    top, bottom = (22, 78, 92), (10, 28, 38)
    bd = ImageDraw.Draw(bg)
    for y in range(N):
        t = y / (N - 1)
        bd.line([(0, y), (N, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)) + (255,))
    mask = Image.new("L", (N, N), 0)
    ImageDraw.Draw(mask).rounded_rectangle([pad, pad, N - pad, N - pad], radius=185 * S, fill=255)
    img.paste(bg, (0, 0), mask)

    # Рамка и слово VPN.
    white = (244, 248, 248, 255)
    fx, fy = 215 * S, 362 * S
    d.rounded_rectangle([fx, fy, N - fx, N - fy], radius=100 * S, outline=white, width=26 * S)
    font = ImageFont.truetype(FONT, 190 * S)
    box = d.textbbox((0, 0), "VPN", font=font)
    w, h = box[2] - box[0], box[3] - box[1]
    d.text(((N - w) / 2 - box[0], (N - h) / 2 - box[1]), "VPN", font=font, fill=white)

    img.resize((1024, 1024), Image.LANCZOS).save(out)
    print("Сохранено:", out)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "Resources/AppIcon.png")
