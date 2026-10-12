#!/usr/bin/env python3
"""Update sibling checkouts: iLand repo refs → iLand; flake input → iland."""
from __future__ import annotations

import re
import sys
from pathlib import Path

WORKSPACE = Path(__file__).resolve().parents[2]

SKIP_DIR_NAMES = {
    ".git",
    "node_modules",
    "XCBuildData",
    ".cache",
    "corebedtime-tip",
    "host-python-site",
    "build-iOS-arm64",
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
}

# Specific → general. Do not blanket-replace crate names like wwn-iland-iomfb.
URL_SUBS = [
    (r"github\.com/Wawona/iLand", "github.com/Wawona/iLand"),
    (r"github:Wawona/iLand", "github:Wawona/iLand"),
    (r"flakehub\.com/f/Wawona/iLand", "flakehub.com/f/Wawona/iLand"),
    (r"api\.flakehub\.com/f/pinned/Wawona/iLand", "api.flakehub.com/f/pinned/Wawona/iLand"),
    (r"Wawona/iLand", "Wawona/iLand"),
    (r'"repo": "iLand"', '"repo": "iLand"'),
]

FLAKE_INPUT_SUBS = [
    (r"\bwwn-iland\.inputs\b", "iland.inputs"),
    (r"\bwwn-iland\.url\b", "iland.url"),
    (r"\bwwn-iland\.registryFragment\b", "iland.registryFragment"),
    (r"\bwwn-iland\.follows\b", "iland.follows"),
    (r"inputs\.iLand\b", "inputs.iland"),
    (r"ilandSrc = iLand\b", "ilandSrc = iland"),
    (r"\$\{iLand\}", "${iland}"),
    (r"\bwwn-iland,\b", "iland,"),
    (r"\(\s*iLand\s*,", "(iland,"),
    (r"\{\s*iLand\s*,", "{iland,"),
    (r"\bwwn-iland\s*\}", "iland}"),
]


def should_skip(path: Path) -> bool:
    if any(part in SKIP_DIR_NAMES for part in path.parts):
        return True
    if any(part.startswith("result") for part in path.parts):
        return True
    if path.suffix.lower() in SKIP_SUFFIXES:
        return True
    if "corebedtime-tip" in path.parts and path.name != "SYNC.md":
        return True
    # Skip this repo's target/ build debris
    if "target" in path.parts:
        return True
    return False


def transform(text: str, *, is_lock: bool, is_flake_nix: bool) -> str:
    out = text
    for pat, repl in URL_SUBS:
        out = re.sub(pat, repl, out)
    if is_flake_nix or is_lock:
        for pat, repl in FLAKE_INPUT_SUBS:
            out = re.sub(pat, repl, out)
    if is_lock:
        # Rename lock nodes iLand / wwn-iland_2 → iland / iland_2
        out = re.sub(r'"iLand(_\d+)?"\s*:', lambda m: f'"iland{m.group(1) or ""}":', out)
        out = out.replace('"iLand"', '"iland"')
    else:
        # Prose: keep hyphenated crate/path tokens that start with wwn-iland-
        out = re.sub(r"`iLand`", "`iLand`", out)
        out = re.sub(r"(?<![\w-])iLand(?![\w-])", "iLand", out)
    return out


def main() -> int:
    roots = [Path(p).resolve() for p in sys.argv[1:]] if len(sys.argv) > 1 else [WORKSPACE]
    updated: list[Path] = []
    for root in roots:
        for path in root.rglob("*"):
            if not path.is_file() or should_skip(path):
                continue
            try:
                text = path.read_text(encoding="utf-8")
            except (UnicodeDecodeError, OSError):
                continue
            if "iLand" not in text:
                continue
            new = transform(
                text,
                is_lock=path.name == "flake.lock",
                is_flake_nix=path.name == "flake.nix",
            )
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
