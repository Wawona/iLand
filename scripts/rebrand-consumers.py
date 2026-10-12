#!/usr/bin/env python3
"""Update sibling checkouts: iLand → iLand URLs + flake input iland."""
from __future__ import annotations

import re
import sys
from pathlib import Path

# Parents of this repo: .../Wawona/iLand → workspace root
WORKSPACE = Path(__file__).resolve().parents[2]

SKIP_DIR_NAMES = {
    ".git",
    "result",
    "result-ios-sim",
    "result-ios-sim-tip",
    "node_modules",
    "XCBuildData",
    ".cache",
    "corebedtime-tip",
}
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
    ".wasm",
    ".lock.bak",
}

# Order matters: longer / more specific first.
SUBS = [
    (r"github\.com/Wawona/iLand", "github.com/Wawona/iLand"),
    (r"github:Wawona/iLand", "github:Wawona/iLand"),
    (r"flakehub\.com/f/Wawona/iLand", "flakehub.com/f/Wawona/iLand"),
    (r"api\.flakehub\.com/f/pinned/Wawona/iLand", "api.flakehub.com/f/pinned/Wawona/iLand"),
    (r"Wawona/iLand", "Wawona/iLand"),
    # flake.lock node / original.repo
    (r'"repo": "iLand"', '"repo": "iLand"'),
    # flake input attribute (nix)
    (r"\bwwn-iland\.inputs\b", "iland.inputs"),
    (r"\bwwn-iland\.url\b", "iland.url"),
    (r"\bwwn-iland\.registryFragment\b", "iland.registryFragment"),
    (r"\bwwn-iland\.follows\b", "iland.follows"),
    (r"inputs\.iLand\b", "inputs.iland"),
    (r"\bwwn-iland,\b", "iland,"),
    (r"\(\s*iLand\s*,", "(iland,"),
    (r"\{\s*iLand\s*,", "{iland,"),
    (r"\bwwn-iland\s*\}", "iland}"),
    (r'ilandSrc = iLand\b', "ilandSrc = iland"),
    (r"\$\{iLand\}", "${iland}"),
    (r'"iLand"', '"iland"'),  # lock keys / JSON where string form is input name
]

# Prose leftover (after URLs). Keep product keys like iland-baremetal.
PROSE = [
    (r"`iLand`", "`iLand`"),
    (r"\bwwn-iland\b", "iLand"),
]


def should_skip(path: Path) -> bool:
    parts = set(path.parts)
    if parts & SKIP_DIR_NAMES:
        return True
    if any(p.startswith("result") for p in path.parts):
        return True
    if path.suffix.lower() in SKIP_SUFFIXES:
        return True
    # Do not rewrite this repo's corebedtime vendor dump
    if "corebedtime-tip" in path.parts and path.name != "SYNC.md":
        return True
    return False


def transform(text: str, *, is_lock: bool) -> str:
    out = text
    for pat, repl in SUBS:
        out = re.sub(pat, repl, out)
    if not is_lock:
        for pat, repl in PROSE:
            out = re.sub(pat, repl, out)
    # flake.lock: rename top-level node key "iLand" / "wwn-iland_2"
    if is_lock:
        out = re.sub(r'"iLand(_\d+)?"\s*:', lambda m: f'"iland{m.group(1) or ""}":', out)
        # follows arrays that still say iLand
        out = out.replace('"iLand"', '"iland"')
    return out


def main() -> int:
    roots = [WORKSPACE]
    if len(sys.argv) > 1:
        roots = [Path(p).resolve() for p in sys.argv[1:]]

    updated = []
    for root in roots:
        for path in root.rglob("*"):
            if not path.is_file() or should_skip(path):
                continue
            # Bound: skip huge unrelated trees
            if "build-iOS-arm64" in path.parts or "host-python-site" in path.parts:
                continue
            try:
                text = path.read_text(encoding="utf-8")
            except (UnicodeDecodeError, OSError):
                continue
            if "iLand" not in text and "Wawona/iLand" not in text:
                continue
            is_lock = path.name == "flake.lock"
            new = transform(text, is_lock=is_lock)
            if new != text:
                path.write_text(new, encoding="utf-8")
                updated.append(path)

    for p in updated:
        try:
            print(p.relative_to(WORKSPACE))
        except ValueError:
            print(p)
    print(f"# updated {len(updated)} files", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
