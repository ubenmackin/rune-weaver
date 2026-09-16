#!/usr/bin/env python3
"""
Generate Weave Cross favicons and web icon assets for Rune Weaver.
Distinctive, non-Bluetooth runic loom cross (Ingwaz diamond + 3 intersecting staves + nexus core).

Outputs to Web/public/:
  - favicon.svg: Clean, transparent vector icon with CSS prefers-color-scheme adaptation.
  - favicon.ico: Multi-resolution transparent ICO (16x16, 32x32, 48x48).
  - favicon-16x16.png: Transparent high-contrast 16x16 PNG.
  - favicon-32x32.png: Transparent high-contrast 32x32 PNG.
  - apple-touch-icon.png: 180x180 icon with dark solid canvas for iOS/Safari home screen.
  - site.webmanifest: Web app manifest.
"""

import json
import subprocess
import tempfile
from pathlib import Path
from PIL import Image

# Responsive Weave Cross SVG with light/dark adaptive CSS
SVG_CONTENT = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24">
  <style>
    :root {
      --rune-color: #a855f7;
      --dot-color: #38bdf8;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --rune-color: #c084fc;
        --dot-color: #38bdf8;
      }
    }
    @media (prefers-color-scheme: light) {
      :root {
        --rune-color: #7c3aed;
        --dot-color: #0284c7;
      }
    }
  </style>
  <g fill="none" stroke="var(--rune-color)" stroke-width="2.3" stroke-linecap="round" stroke-linejoin="round">
    <polygon points="12,4 19.5,12 12,20 4.5,12" />
    <line x1="12" y1="1" x2="12" y2="23" />
    <line x1="5" y1="5" x2="19" y2="19" />
    <line x1="5" y1="19" x2="19" y2="5" />
    <circle cx="12" cy="12" r="2.2" fill="var(--dot-color)" stroke="none" />
  </g>
</svg>"""

# High-contrast standalone SVG for rasterization (vibrant violet + cyan dot on transparent canvas)
RASTER_SVG = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="256" height="256">
  <g fill="none" stroke="#a855f7" stroke-width="2.3" stroke-linecap="round" stroke-linejoin="round">
    <polygon points="12,4 19.5,12 12,20 4.5,12" />
    <line x1="12" y1="1" x2="12" y2="23" />
    <line x1="5" y1="5" x2="19" y2="19" />
    <line x1="5" y1="19" x2="19" y2="5" />
    <circle cx="12" cy="12" r="2.2" fill="#38bdf8" stroke="none" />
  </g>
</svg>"""

# Solid canvas SVG specifically for Apple Touch Icon (iOS renders transparent pixels black)
APPLE_TOUCH_SVG = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 180 180" width="180" height="180">
  <defs>
    <radialGradient id="aura" cx="50%" cy="50%" r="50%">
      <stop offset="0%" stop-color="#8b5cf6" stop-opacity="0.3"/>
      <stop offset="100%" stop-color="#101014" stop-opacity="0"/>
    </radialGradient>
  </defs>
  <rect width="180" height="180" fill="#101014"/>
  <circle cx="90" cy="90" r="70" fill="url(#aura)"/>
  <g transform="translate(90, 90) scale(6.2) translate(-12, -12)" fill="none" stroke="#c084fc" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round">
    <polygon points="12,4 19.5,12 12,20 4.5,12" />
    <line x1="12" y1="1" x2="12" y2="23" />
    <line x1="5" y1="5" x2="19" y2="19" />
    <line x1="5" y1="19" x2="19" y2="5" />
    <circle cx="12" cy="12" r="2.2" fill="#38bdf8" stroke="none" />
  </g>
</svg>"""

MANIFEST_CONTENT = {
    "name": "Rune Weaver Dashboard",
    "short_name": "Rune Weaver",
    "description": "Personal AI Agent Dashboard",
    "icons": [
        {
            "src": "./favicon-16x16.png",
            "sizes": "16x16",
            "type": "image/png"
        },
        {
            "src": "./favicon-32x32.png",
            "sizes": "32x32",
            "type": "image/png"
        },
        {
            "src": "./apple-touch-icon.png",
            "sizes": "180x180",
            "type": "image/png"
        }
    ],
    "theme_color": "#101014",
    "background_color": "#101014",
    "display": "standalone"
}


def generate():
    root_dir = Path(__file__).resolve().parent.parent
    public_dir = root_dir / "Web" / "public"
    public_dir.mkdir(parents=True, exist_ok=True)

    # 1. Write favicon.svg
    svg_path = public_dir / "favicon.svg"
    svg_path.write_text(SVG_CONTENT, encoding="utf-8")
    print(f"Created {svg_path}")

    # 2. Write site.webmanifest
    manifest_path = public_dir / "site.webmanifest"
    manifest_path.write_text(json.dumps(MANIFEST_CONTENT, indent=2) + "\n", encoding="utf-8")
    print(f"Created {manifest_path}")

    with tempfile.TemporaryDirectory() as tmpdir:
        tmp_dir_path = Path(tmpdir)

        # 3. Render high-res raster source from RASTER_SVG via sips
        tmp_raster_svg = tmp_dir_path / "raster.svg"
        tmp_raster_png = tmp_dir_path / "raster_256.png"
        tmp_raster_svg.write_text(RASTER_SVG, encoding="utf-8")

        subprocess.run(
            ["sips", "-s", "format", "png", "--resampleHeightWidth", "256", "256", str(tmp_raster_svg), "--out", str(tmp_raster_png)],
            check=True,
            capture_output=True,
        )

        im256 = Image.open(tmp_raster_png)

        # 4. Generate transparent PNG icons (32x32, 16x16)
        im32 = im256.resize((32, 32), Image.Resampling.LANCZOS)
        im16 = im256.resize((16, 16), Image.Resampling.LANCZOS)
        im32.save(public_dir / "favicon-32x32.png", format="PNG")
        im16.save(public_dir / "favicon-16x16.png", format="PNG")
        print(f"Created {public_dir / 'favicon-32x32.png'} and 16x16")

        # 5. Generate transparent multi-resolution favicon.ico (16, 32, 48)
        im48 = im256.resize((48, 48), Image.Resampling.LANCZOS)
        im48.save(public_dir / "favicon.ico", format="ICO", sizes=[(16, 16), (32, 32), (48, 48)])
        print(f"Created {public_dir / 'favicon.ico'} (multi-res 16, 32, 48)")

        # 6. Render apple-touch-icon.png with solid dark canvas
        tmp_apple_svg = tmp_dir_path / "apple.svg"
        tmp_apple_svg.write_text(APPLE_TOUCH_SVG, encoding="utf-8")
        apple_out = public_dir / "apple-touch-icon.png"
        subprocess.run(
            ["sips", "-s", "format", "png", "--resampleHeightWidth", "180", "180", str(tmp_apple_svg), "--out", str(apple_out)],
            check=True,
            capture_output=True,
        )
        print(f"Created {apple_out} (180x180)")

    print("Weave Cross favicon suite generated successfully.")


if __name__ == "__main__":
    generate()
