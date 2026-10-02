"""Build the single-file redesign mockup page from its split source.

Inlines the stylesheet, script and icon concepts into one HTML file for publishing.
Run from the repo root: uv run --no-project python resources/scripts/build-redesign-mockups.py
"""

import base64
import subprocess
import tempfile
from pathlib import Path

DOCS = Path("resources/docs")
STEM = "261002-redesign-mockups"
CONCEPTS = Path("resources/icons/concepts")
OUT = DOCS / f"{STEM}.html"
EMBED_SIZE = "256x256"
OVERRIDE = (
    "<!-- lint-ignore: max-lines -- generated single-file page for publishing; "
    f"edit {STEM}.html.in, .css and .js, then rerun resources/scripts/build-redesign-mockups.py -->\n"
)


def embed_icon(src: Path, tmp: Path) -> str:
    small = tmp / src.name
    subprocess.run(["magick", str(src), "-resize", EMBED_SIZE, "-strip", str(small)], check=True)
    return "data:image/png;base64," + base64.b64encode(small.read_bytes()).decode()


def main() -> None:
    html = (DOCS / f"{STEM}.html.in").read_text()
    for marker, part in (("/*__CSS__*/", "css"), ("/*__JS__*/", "js")):
        if html.count(marker) != 1:
            raise SystemExit(f"marker {marker} must appear once")
        html = html.replace(marker, (DOCS / f"{STEM}.{part}").read_text())
    with tempfile.TemporaryDirectory() as tmp_dir:
        tmp = Path(tmp_dir)
        for direction in "abc":
            for appearance in ("light", "dark"):
                token = f"__ICON_{direction.upper()}_{appearance.upper()}__"
                if html.count(token) != 1:
                    raise SystemExit(f"token {token} must appear once")
                src = CONCEPTS / f"detours-icon-{direction}-{appearance}.png"
                if not src.exists():
                    raise SystemExit(f"missing icon concept {src}")
                html = html.replace(token, embed_icon(src, tmp))
    if "__ICON_" in html:
        raise SystemExit("unreplaced icon token")
    OUT.write_text(OVERRIDE + html)
    print(f"RESULT ok {OUT} {OUT.stat().st_size} bytes")


if __name__ == "__main__":
    main()
