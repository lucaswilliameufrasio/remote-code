#!/usr/bin/env python3
"""Render the CodeRelay artwork. Requires Pillow only when regenerating assets."""
import json
import pathlib

from PIL import Image, ImageDraw

ROOT = pathlib.Path(__file__).resolve().parents[1]
BRAND = ROOT / 'assets/brand'


def render_logo():
    # Supersample the geometry shared with assets/brand/logo.svg.
    scale = 4
    image = Image.new('RGB', (1024 * scale, 1024 * scale), '#0B1418')
    drawing = ImageDraw.Draw(image)

    def bounds(values):
        return tuple(value * scale for value in values)

    drawing.rounded_rectangle(bounds((188, 220, 836, 756)), radius=124 * scale,
                              fill='#9CE5C5')
    drawing.rounded_rectangle(bounds((228, 260, 796, 716)), radius=84 * scale,
                              fill='#152C2B')
    for points in (((336, 408), (432, 488), (336, 568)),
                   ((516, 568), (628, 568))):
        drawing.line([(x * scale, y * scale) for x, y in points],
                     fill='#9CE5C5', width=44 * scale, joint='curve')
        for x, y in points:
            drawing.ellipse(bounds((x - 22, y - 22, x + 22, y + 22)),
                            fill='#9CE5C5')
    drawing.rounded_rectangle(bounds((540, 644, 868, 804)), radius=80 * scale,
                              fill='#0B1418')
    drawing.line(bounds((608, 724, 800, 724)), fill='#9CE5C5', width=24 * scale)
    for center in (608, 800):
        drawing.ellipse(bounds((center - 34, 690, center + 34, 758)), fill='#9CE5C5')
    return image


def main():
    image = render_logo()
    sizes = {48, 72, 96, 144, 192, 1024}
    catalog = ROOT / 'ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json'
    for entry in json.loads(catalog.read_text())['images']:
        sizes.add(round(float(entry['size'].split('x')[0]) *
                        float(entry['scale'].rstrip('x'))))
    output = BRAND / 'raster'
    output.mkdir(parents=True, exist_ok=True)
    for size in sorted(sizes):
        image.resize((size, size), Image.Resampling.LANCZOS).save(output / f'{size}.png')
    image.resize((512, 512), Image.Resampling.LANCZOS).save(BRAND / 'logo.png')


if __name__ == '__main__':
    main()
