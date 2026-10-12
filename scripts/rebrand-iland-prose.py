#!/usr/bin/env python3
"""One-shot: rebrand wwn-iland → iLand in this repo (skip corebedtime-tip)."""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SKIP_SUFFIXES = {
    ".gif",
    ".png",
    ".jpg",
    ".jpeg",
    ".webp",
    ".pdf",
    ".o",
    ".a",
    ".dylib",
    ".so",
}
URL_SUBS = [
    (r"github\.com/Wawona/wwn-iland", "github.com/Wawona/iLand"),
    (r"github:Wawona/wwn-iland", "github:Wawona/iLand"),
    (r"flakehub\.com/f/Wawona/wwn-iland", "flakehub.com/f/Wawona/iLand"),
    (r"Wawona/wwn-iland", "Wawona/iLand"),
]


def main() -> None:
    updated = []
    for path in ROOT.rglob("*"):
        if not path.is_file():
            continue
        if ".git" in path.parts:
            continue
        if "corebedtime-tip" in path.parts and path.name != "SYNC.md":
            continue
        if path.suffix.lower() in SKIP_SUFFIXES:
            continue
        if path.name == "rebrand-iland-prose.py":
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        orig = text
        for pat, repl in URL_SUBS:
            text = re.sub(pat, repl, text)
        text = text.replace("# wwn-iland", "# iLand")
        text = text.replace("`wwn-iland`", "`iLand`")
        text = re.sub(r"\bwwn-iland\b", "iLand", text)
        if text != orig:
            path.write_text(text, encoding="utf-8")
            updated.append(path.relative_to(ROOT))

    flake = ROOT / "flake.nix"
    t = flake.read_text(encoding="utf-8")
    t2 = re.sub(
        r'description = "[^"]*";',
        'description = "iLand: Wawona userland Linux-graphics compat layer '
        '(GBM/EGL/DRM over IOSurface/ANGLE). Formerly wwn-iland.";',
        t,
        count=1,
    )
    if t2 != t:
        flake.write_text(t2, encoding="utf-8")
        if Path("flake.nix") not in updated:
            updated.append(Path("flake.nix"))

    for p in updated:
        print(p)


if __name__ == "__main__":
    main()
