#!/usr/bin/env python3
"""
Generate native macOS AppIcon (.icns) and master assets for Rune Weaver.
Features the distinctive Weave Cross (Ingwaz diamond + 3 intersecting staves + nexus core).
Adheres to Apple macOS Human Interface Guidelines (1024x1024 squircle with drop shadow).

Outputs to Resources/:
  - AppIcon.icns: Multi-resolution native macOS icon bundle (16x16 up to 1024x1024 @2x).
  - AppIcon.png: 1024x1024 master icon PNG.
  - AppIcon.svg: Vector source.
"""

import os
import shutil
import subprocess
import tempfile
from pathlib import Path
from PIL import Image

APP_ICON_SVG = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <defs>
    <!-- Native macOS Dock drop shadow for the squircle body -->
    <filter id="dockShadow" x="-10%" y="-5%" width="120%" height="130%">
      <feDropShadow dx="0" dy="28" stdDeviation="32" flood-color="#000000" flood-opacity="0.55" />
      <feDropShadow dx="0" dy="8" stdDeviation="12" flood-color="#000000" flood-opacity="0.35" />
    </filter>

    <!-- Rune drop shadow for tactile relief depth -->
    <filter id="runeShadow" x="-20%" y="-20%" width="140%" height="140%">
      <feDropShadow dx="0" dy="12" stdDeviation="16" flood-color="#000000" flood-opacity="0.6" />
      <feDropShadow dx="0" dy="4" stdDeviation="6" flood-color="#a855f7" flood-opacity="0.3" />
    </filter>

    <!-- Squircle base gradient: space-black obsidian to midnight violet -->
    <linearGradient id="bodyGrad" x1="0%" y1="0%" x2="0%" y2="100%">
      <stop offset="0%" stop-color="#221d38"/>
      <stop offset="40%" stop-color="#161324"/>
      <stop offset="100%" stop-color="#0b0a12"/>
    </linearGradient>

    <!-- Top rim highlight -->
    <linearGradient id="rimGrad" x1="0%" y1="0%" x2="0%" y2="100%">
      <stop offset="0%" stop-color="#ffffff" stop-opacity="0.22"/>
      <stop offset="15%" stop-color="#c084fc" stop-opacity="0.35"/>
      <stop offset="60%" stop-color="#8b5cf6" stop-opacity="0.15"/>
      <stop offset="100%" stop-color="#3b82f6" stop-opacity="0.05"/>
    </linearGradient>

    <!-- Ambient Magical Core Aura -->
    <radialGradient id="coreAura" cx="50%" cy="50%" r="50%">
      <stop offset="0%" stop-color="#a855f7" stop-opacity="0.45"/>
      <stop offset="50%" stop-color="#6366f1" stop-opacity="0.15"/>
      <stop offset="100%" stop-color="#000000" stop-opacity="0"/>
    </radialGradient>

    <!-- Luminous Rune Glyph Gradient -->
    <linearGradient id="runeGrad" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" stop-color="#f3e8ff"/>
      <stop offset="25%" stop-color="#d8b4fe"/>
      <stop offset="65%" stop-color="#a855f7"/>
      <stop offset="100%" stop-color="#6366f1"/>
    </linearGradient>

    <!-- Nexus Center Node Gradient -->
    <radialGradient id="nexusGrad" cx="50%" cy="50%" r="50%">
      <stop offset="0%" stop-color="#ffffff"/>
      <stop offset="30%" stop-color="#38bdf8"/>
      <stop offset="75%" stop-color="#0284c7"/>
      <stop offset="100%" stop-color="#0369a1"/>
    </radialGradient>
  </defs>

  <!-- Squircle Base with macOS Shadow (macOS HIG standard: 824x824 at 100,92 rx=185) -->
  <rect x="100" y="92" width="824" height="824" rx="185" fill="url(#bodyGrad)" filter="url(#dockShadow)"/>

  <!-- Subtle inner rim highlight -->
  <rect x="101" y="93" width="822" height="822" rx="184" fill="none" stroke="url(#rimGrad)" stroke-width="2.5"/>

  <!-- Ambient Magical Aura -->
  <circle cx="512" cy="504" r="320" fill="url(#coreAura)"/>

  <!-- Hero Weave Cross Emblem (scaled from 24x24 coords) -->
  <g transform="translate(512, 504) scale(28) translate(-12, -12)" filter="url(#runeShadow)" fill="none" stroke="url(#runeGrad)" stroke-width="2.3" stroke-linecap="round" stroke-linejoin="round">
    <!-- Center diamond -->
    <polygon points="12,4 19.5,12 12,20 4.5,12" />
    <!-- 3 crossing warp/weft staves -->
    <line x1="12" y1="1" x2="12" y2="23" />
    <line x1="5" y1="5" x2="19" y2="19" />
    <line x1="5" y1="19" x2="19" y2="5" />
    <!-- Central Nexus Node -->
    <circle cx="12" cy="12" r="2.2" fill="url(#nexusGrad)" stroke="#0e7490" stroke-width="0.3" />
    <circle cx="12" cy="12" r="0.7" fill="#ffffff" stroke="none" />
  </g>
</svg>"""


def generate():
    root_dir = Path(__file__).resolve().parent.parent
    resources_dir = root_dir / "Resources"
    resources_dir.mkdir(parents=True, exist_ok=True)

    # 1. Save vector source
    svg_path = resources_dir / "AppIcon.svg"
    svg_path.write_text(APP_ICON_SVG, encoding="utf-8")
    print(f"Created {svg_path}")

    # 2. Render 1024x1024 master PNG via sips
    png_path = resources_dir / "AppIcon.png"
    subprocess.run(
        ["sips", "-s", "format", "png", "--resampleHeightWidth", "1024", "1024", str(svg_path), "--out", str(png_path)],
        check=True,
        capture_output=True,
    )
    print(f"Created {png_path} (1024x1024)")

    # 3. Create iconset directory with standard Apple icon sizes
    with tempfile.TemporaryDirectory() as tmpdir:
        iconset_dir = Path(tmpdir) / "AppIcon.iconset"
        iconset_dir.mkdir()

        master_img = Image.open(png_path)

        icon_sizes = [
            ("icon_16x16.png", 16),
            ("icon_16x16@2x.png", 32),
            ("icon_32x32.png", 32),
            ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128),
            ("icon_128x128@2x.png", 256),
            ("icon_256x256.png", 256),
            ("icon_256x256@2x.png", 512),
            ("icon_512x512.png", 512),
            ("icon_512x512@2x.png", 1024),
        ]

        for filename, size in icon_sizes:
            resized = master_img.resize((size, size), Image.Resampling.LANCZOS)
            resized.save(iconset_dir / filename, format="PNG")

        # 4. Compile .icns via Apple iconutil
        icns_path = resources_dir / "AppIcon.icns"
        subprocess.run(
            ["iconutil", "-c", "icns", str(iconset_dir), "-o", str(icns_path)],
            check=True,
            capture_output=True,
        )
        print(f"Created {icns_path} ({icns_path.stat().st_size:,} bytes)")

    print("macOS AppIcon generated successfully.")


if __name__ == "__main__":
    generate()
