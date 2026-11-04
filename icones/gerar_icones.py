"""Ícones alternativos da Agenda, no estilo do JL (opção H): monograma serifado branco sobre preto, com traço fino embaixo.

Uso (Windows, precisa da fonte Cambria): python icones/gerar_icones.py
Gera icones/<NOME>-1024.png. O build do iOS reduz para 120 e 180 px e põe no app como ícone alternativo.
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

OUT = Path(__file__).parent
S = 4096
k = S / 1024


def r(v):
    return int(v * k)


def fundo():
    img = Image.new("RGB", (S, S), (0, 0, 0))
    d = ImageDraw.Draw(img)
    for i in range(80, 0, -1):  # mesma vinheta leve do JL
        t = i / 80
        rad = int(S * 0.72 * t)
        c = int(24 * (1 - t))
        d.ellipse([S // 2 - rad, S // 2 - rad, S // 2 + rad, S // 2 + rad], fill=(c, c, c))
    return img


def monograma(txt, tam=430):
    img = fundo()
    d = ImageDraw.Draw(img)
    f = ImageFont.truetype("C:/Windows/Fonts/cambriab.ttf", r(tam))
    l, t, rr, b = d.textbbox((0, 0), txt, font=f)
    d.text(((S - (rr - l)) / 2 - l, r(470) - (b - t) / 2 - t), txt, font=f, fill=(255, 255, 255))
    d.rounded_rectangle([r(332), r(735), r(692), r(753)], radius=r(9), fill=(255, 255, 255))
    return img.resize((1024, 1024), Image.LANCZOS)


ICONES = {"AC": 390}

if __name__ == "__main__":
    for nome, tam in ICONES.items():
        monograma(nome, tam).save(OUT / f"{nome}-1024.png")
        print("gerado", nome)
