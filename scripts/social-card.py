#!/usr/bin/env python3
"""Builds docs/images/social.png (1200x630), the link preview for the site and README."""
from PIL import Image, ImageDraw, ImageFont, ImageFilter

F = "Sources/TwinfoldApp/Fonts/"
W, H = 1200, 630
paper, ink, green = (247, 244, 236), (24, 28, 24), (52, 160, 98)

card = Image.new("RGB", (W, H), paper)
glow = Image.new("RGB", (W, H), paper)
ImageDraw.Draw(glow).ellipse((620, -160, 1400, 560), fill=(214, 236, 218))
card = Image.blend(card, glow.filter(ImageFilter.GaussianBlur(120)), 1)

d = ImageDraw.Draw(card)
serif = ImageFont.truetype(F + "InstrumentSerif-Regular.ttf", 70)
italic = ImageFont.truetype(F + "InstrumentSerif-Italic.ttf", 70)
mono = ImageFont.truetype(F + "GeistMono.ttf", 24)

d.text((64, 170), "Get disk space back", font=serif, fill=ink)
x = 72
d.text((64, 248), "without removing", font=italic, fill=green)
d.text((64, 326), "any files.", font=serif, fill=ink)
d.text((66, 440), "Twinfold · free, open source", font=mono, fill=(110, 114, 108))

shot = Image.open("docs/images/simple-light.png").convert("RGB")
shot = shot.crop((400, 180, 1760, 1300))  # the centered card, without the window's empty sides
shot = shot.resize((500, int(500 * shot.height / shot.width)), Image.LANCZOS)
mask = Image.new("L", shot.size, 0)
ImageDraw.Draw(mask).rounded_rectangle((0, 0, *shot.size), 22, fill=255)
shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle((668, (H - shot.height) // 2 + 20, 668 + shot.width, (H + shot.height) // 2 + 20), 22, fill=(0, 0, 0, 60))
card.paste(shadow.filter(ImageFilter.GaussianBlur(24)), (0, 0), shadow.filter(ImageFilter.GaussianBlur(24)))
card.paste(shot, (660, (H - shot.height) // 2), mask)
card.save("docs/images/social.png", optimize=True)
print("wrote docs/images/social.png")
