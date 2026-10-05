#!/usr/bin/env python3
"""
Generate Wisp persona avatar assets for the Rune Weaver dashboard.

The Wisp is one figure: a floating rounded sprite body whose radial gradients
give it three-dimensional volume, two glowing eyes, a cyan nexus-core belly,
and a soft violet rim light. Four colorways (violet, cyan, emerald, rose)
differ ONLY in the body gradient stops; four states (idle, sleeping, working,
attention) differ ONLY in the eyes and accents, with body geometry held
identical — idle carries open eyes, sleeping closed eyes plus two Z marks and
a dimmed core, working half-lid eyes angled up plus a small motion arc, and
attention wide eyes inside an amber outer ring. The dashboard renders these
frames so the avatar can mirror the agent's live posture (approvals waiting,
a run in flight, long silence, nothing pending) with zero runtime synthesis.

Determinism is a contract, not a hope: the palette is fixed constants, there
are no timestamps and no randomness, and `--check` re-renders the whole set
twice into throwaway directories, asserts the two passes are byte-identical,
then compares the result against the committed bundle, so re-running this
script must reproduce byte-identical files and any drift fails loudly.

Outputs to Web/public/avatars/:
  - wisp-{idle,sleeping,working,attention}.svg: violet state masters.
  - wisp-{colorway}-{state}-{256,64,32}.png: 48 raster frames (PNG triples).

Rasterization reuses the exact pipeline of scripts/generate_favicons.py and
scripts/generate_app_icon.py — `sips` renders the embedded SVG at the master
size, Pillow LANCZOS produces the smaller sizes — so the repo keeps one
rasterizer rather than a second diverging one.
"""

import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image

# The closed vocabularies of the persona layer. The dashboard mirrors these
# keys one-for-one, so a new colorway or state is exactly one entry here plus
# one asset rename, never a second spelling to reconcile per surface.
COLORWAYS = {
    # Violet is the master colorway: the template below is authored in these
    # stops and the committed SVG masters are this template's literal text.
    # Every other colorway replaces exactly these four body-stop hexes; they
    # appear nowhere else in the artwork (the rim light, core, eyes, and all
    # accents stay colorway-neutral by design).
    "violet": ("#c4b5fd", "#8b5cf6", "#6d28d9", "#2e1065"),
    "cyan": ("#a5f3fc", "#22d3ee", "#0891b2", "#164e63"),
    "emerald": ("#a7f3d0", "#34d399", "#059669", "#064e3b"),
    "rose": ("#fda4af", "#fb7185", "#e11d48", "#881337"),
}
STATES = ("idle", "sleeping", "working", "attention")
MASTER_COLORWAY = "violet"
MASTER_SIZE = 256
PNG_SIZES = (256, 64, 32)

# One body, one geometry, every state. The token lines are the ONLY places a
# colorway or state may differ: body stops, core dimming (sleeping only), and
# the eyes/accents block appended after the core.
WISP_TEMPLATE = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" width="256" height="256">
  <defs>
    <radialGradient id="wispBody" cx="38%" cy="30%" r="78%">
      <stop offset="0%" stop-color="__BODY_STOP_TOP__"/>
      <stop offset="45%" stop-color="__BODY_STOP_MID__"/>
      <stop offset="80%" stop-color="__BODY_STOP_DEEP__"/>
      <stop offset="100%" stop-color="__BODY_STOP_SHADE__"/>
    </radialGradient>
    <radialGradient id="nexusCore" cx="50%" cy="45%" r="62%">
      <stop offset="0%" stop-color="#e0f2fe"/>
      <stop offset="35%" stop-color="#38bdf8"/>
      <stop offset="75%" stop-color="#0284c7"/>
      <stop offset="100%" stop-color="#075985"/>
    </radialGradient>
    <radialGradient id="rimLight" cx="50%" cy="42%" r="64%">
      <stop offset="72%" stop-color="#a855f7" stop-opacity="0"/>
      <stop offset="93%" stop-color="#a855f7" stop-opacity="0.45"/>
      <stop offset="100%" stop-color="#a855f7" stop-opacity="0"/>
    </radialGradient>
    <radialGradient id="eyeGlow" cx="50%" cy="42%" r="65%">
      <stop offset="0%" stop-color="#ffffff"/>
      <stop offset="55%" stop-color="#dff6ff"/>
      <stop offset="100%" stop-color="#7dd3fc"/>
    </radialGradient>
    <filter id="wispFloat" x="-20%" y="-20%" width="140%" height="160%">
      <feDropShadow dx="0" dy="12" stdDeviation="10" flood-color="#1e1b4b" flood-opacity="0.45"/>
    </filter>
  </defs>
  <circle cx="128" cy="118" r="96" fill="url(#rimLight)"/>
  <path d="M128 36 C166 36 194 70 194 116 C194 160 184 196 162 209 C150 216 140 209 128 209 C116 209 106 216 94 209 C72 196 62 160 62 116 C62 70 90 36 128 36 Z" fill="url(#wispBody)" filter="url(#wispFloat)"/>
  <ellipse cx="104" cy="74" rx="26" ry="13" fill="#ffffff" opacity="0.16" transform="rotate(-20 104 74)"/>
  <ellipse cx="128" cy="152" rx="26" ry="19" fill="url(#nexusCore)" opacity="__CORE_OPACITY__"/>
  <circle cx="121" cy="146" r="5.5" fill="#f0f9ff" opacity="__CORE_GLINT_OPACITY__"/>
__STATE_ART__
</svg>
"""

# Eyes and accents per state. Nothing here touches body geometry, so the four
# states read as one creature with different moods rather than four sprites.
STATE_ART = {
    "idle": """  <ellipse cx="104" cy="110" rx="11" ry="14" fill="url(#eyeGlow)"/>
  <ellipse cx="152" cy="110" rx="11" ry="14" fill="url(#eyeGlow)"/>""",
    "sleeping": """  <path d="M93 108 Q104 119 115 108" stroke="#dff6ff" stroke-width="5" fill="none" stroke-linecap="round"/>
  <path d="M141 108 Q152 119 163 108" stroke="#dff6ff" stroke-width="5" fill="none" stroke-linecap="round"/>
  <path d="M184 62 L202 62 L184 80 L202 80" stroke="#e9d5ff" stroke-width="5" fill="none" stroke-linecap="round" stroke-linejoin="round"/>
  <path d="M208 38 L219 38 L208 50 L219 50" stroke="#e9d5ff" stroke-width="4" fill="none" stroke-linecap="round" stroke-linejoin="round" opacity="0.75"/>""",
    "working": """  <path d="M46 96 Q36 116 46 136" stroke="#bae6fd" stroke-width="5" fill="none" stroke-linecap="round" opacity="0.55"/>
  <path d="M28 106 Q21 120 28 134" stroke="#bae6fd" stroke-width="4" fill="none" stroke-linecap="round" opacity="0.4"/>
  <g transform="rotate(-8 128 108)">
    <path d="M94 116 Q104 98 114 116 Z" fill="url(#eyeGlow)"/>
    <path d="M142 116 Q152 98 162 116 Z" fill="url(#eyeGlow)"/>
  </g>""",
    "attention": """  <circle cx="128" cy="118" r="110" fill="none" stroke="#f59e0b" stroke-width="7" opacity="0.9"/>
  <ellipse cx="104" cy="110" rx="13" ry="17" fill="url(#eyeGlow)"/>
  <ellipse cx="152" cy="110" rx="13" ry="17" fill="url(#eyeGlow)"/>""",
}


def wisp_svg(colorway: str, state: str) -> str:
    top, mid, deep, shade = COLORWAYS[colorway]
    dimmed = state == "sleeping"
    return (
        WISP_TEMPLATE.replace("__BODY_STOP_TOP__", top)
        .replace("__BODY_STOP_MID__", mid)
        .replace("__BODY_STOP_DEEP__", deep)
        .replace("__BODY_STOP_SHADE__", shade)
        .replace("__CORE_OPACITY__", "0.45" if dimmed else "1")
        .replace("__CORE_GLINT_OPACITY__", "0.4" if dimmed else "0.85")
        .replace("__STATE_ART__", STATE_ART[state])
    )


def expected_names() -> list:
    names = [f"wisp-{state}.svg" for state in STATES]
    for colorway in COLORWAYS:
        for state in STATES:
            for size in PNG_SIZES:
                names.append(f"wisp-{colorway}-{state}-{size}.png")
    return names


def render_into(directory: Path) -> None:
    """Render the full 52-file set into one directory.

    The SVG masters are the literal violet template text (design source of
    truth), the 256px PNGs are the `sips` rasterization of each embedded
    template, and 64/32 are Pillow LANCZOS downscales — the shared favicon
    pipeline, so byte-for-byte reproducibility rides one toolchain."""
    directory.mkdir(parents=True, exist_ok=True)
    for state in STATES:
        (directory / f"wisp-{state}.svg").write_text(
            wisp_svg(MASTER_COLORWAY, state), encoding="utf-8"
        )
    with tempfile.TemporaryDirectory() as scratch:
        scratch_svg = Path(scratch) / "frame.svg"
        for colorway in COLORWAYS:
            for state in STATES:
                master_png = directory / f"wisp-{colorway}-{state}-{MASTER_SIZE}.png"
                scratch_svg.write_text(wisp_svg(colorway, state), encoding="utf-8")
                subprocess.run(
                    [
                        "sips",
                        "-s",
                        "format",
                        "png",
                        "--resampleHeightWidth",
                        str(MASTER_SIZE),
                        str(MASTER_SIZE),
                        str(scratch_svg),
                        "--out",
                        str(master_png),
                    ],
                    check=True,
                    capture_output=True,
                )
                with Image.open(master_png) as master_image:
                    for size in PNG_SIZES:
                        if size == MASTER_SIZE:
                            continue
                        resized = master_image.resize(
                            (size, size), Image.Resampling.LANCZOS
                        )
                        resized.save(
                            directory / f"wisp-{colorway}-{state}-{size}.png",
                            format="PNG",
                        )


def avatars_dir() -> Path:
    root_dir = Path(__file__).resolve().parent.parent
    return root_dir / "Web" / "public" / "avatars"


def generate() -> None:
    target = avatars_dir()
    render_into(target)
    print(
        f"Created {len(expected_names())} persona avatar assets "
        f"(4 SVG masters + 48 PNG frames) in {target}"
    )


def check() -> int:
    """Assert re-runs are byte-identical: two fresh renders must match each
    other, and the committed bundle must match the regenerated bytes exactly.

    A missing file is a failure with repair guidance, never a silent pass: the
    PNG triples are derived assets and the script is their only source."""
    committed = avatars_dir()
    failures = []
    with tempfile.TemporaryDirectory() as first, tempfile.TemporaryDirectory() as second:
        first_dir, second_dir = Path(first), Path(second)
        render_into(first_dir)
        render_into(second_dir)
        for name in expected_names():
            run_one = (first_dir / name).read_bytes()
            run_two = (second_dir / name).read_bytes()
            if run_one != run_two:
                failures.append(f"{name}: regeneration is not byte-stable")
                continue
            bundle_path = committed / name
            if not bundle_path.exists():
                failures.append(
                    f"{name}: missing from Web/public/avatars — run without --check"
                )
            elif bundle_path.read_bytes() != run_one:
                failures.append(f"{name}: bundle differs from regenerated bytes")
    if failures:
        print("Persona avatar check FAILED:")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print(
        f"Persona avatar check passed: {len(expected_names())} files are "
        "byte-identical across re-runs and match the bundle."
    )
    return 0


if __name__ == "__main__":
    if "--check" in sys.argv[1:]:
        raise SystemExit(check())
    generate()
