# AGENTS.md — iLand

Guidance for AI agents editing this repository.

## What this repo is

Wawona’s Linux-graphics compat layer (GBM / EGL / DRM-KMS over IOSurface +
ANGLE on Apple and AHardwareBuffer/Surface on Android). Fork lineage:
[CoreBedtime/iland](https://github.com/CoreBedtime/iland) → deleted
`Wawona/iland` → **this repo**.

Query **wwn-mcp** (`project=iland`, source `iLand` for packaging; source
`iland` for upstream CoreBedtime reference). Prefer `iLand` recipes over
vanilla CoreBedtime behavior.

## Mode A vs Mode B (non-negotiable)

| Mode | Recipe | Output | Who ships it |
|------|--------|--------|----------------|
| **A** (default) | `registryFragment.iland` → `macos.nix` / `ios.nix` / `android.nix` / stubs | `libiland_userland.a` | All Wawona targets that need GL/userland DRM |
| **B** | `registryFragment.iland-baremetal` → `macos-baremetal.nix` only | `libwayland-mac.dylib` | **Only** Wawona `wawona-macos-desktop-host` |

- Mode B = Dobby + `DYLD_INSERT_LIBRARIES` + embedded `framebufferd` /
  `inputd` / `amfiexceptiond`. Needs SIP fully disabled (`csrutil disable`) +
  root. **Not** App Store.
- Never add `iland-baremetal` variants for iOS/iPadOS/tvOS/watchOS/visionOS/Android.
- tvOS Mode A is real userland: MoltenVK (Vulkan to Metal) and ANGLE
  (OpenGL ES to Metal), both source/static like visionOS. watchOS Mode A
  stays an empty stub (no Metal in the SDK). See workspace
  rule `iLand-apple-fallback`.

Canonical prose (integration side):
`Wawona/docs/iland-mode-a-b-desktop.md` and workspace rule
`wawona-iland-mode-b-desktop`.

Mode B CoreDisplay / SkyLight / `CAWindowServer` SPI (prototypes, ObjC
encodings, 25F80 disasm, safe-call rules):
`docs/mode-b/baremetal-display-spi-25F80.md`.

## Repo DAG layer (L1) — never invert

`iLand` is **L1: the complete Wawona graphics stack** (iland userland
DRM/KMS/GBM/EGL present + Mode A/B; `angle`, `swiftshader`,
`moltenvk`, `kosmickrisp`, `iland-cpu`). It depends on
**`wwn-toolchain` (L0) ONLY**.

- **Never** add `wwn-weston`, `wwn-kmscube`, `wwn-waypipe`, or `Wawona` as a
  flake input of this repo (that would make iland depend on its consumers).
- **Never** move substrate libs (`pixman`, `cairo`, `pango`, `libwayland`) into
  this repo — they stay L0; `iland-cpu` *links* toolchain `pixman`.
- Graphics keys (`angle`/`swiftshader`) live here; consumers merge this repo's
  `registryFragment`, not bare toolchain.

Canonical: `Wawona/docs/wwn-repo-dag.md` + workspace rule `wawona-repo-dag`.

## Layout

- `dependencies/libs/iland/upstream/` — vendored CoreBedtime tree + Wawona shims
  (`iland_present.h`, Mode A present redirect, ANGLE/zerocopy EGL patches).
- `dependencies/libs/iland/android/` — Android GBM/IOSurface-compat sources.
- `dependencies/generators/iland-gl-*.nix` — link flags for clients.
- `flake.nix` — `registryFragment` consumed by Wawona / wwn-weston / wwn-kmscube.

## Do / don’t

- **Do** keep Mode A App-Store-safe (no injection, no priv daemons in the
  default archive).
- **Do** keep all DRM/KMS/GBM behavior runtime-only and in userland. Never open
  real `/dev/dri` or `/dev/kgsl` nodes, forward real DRM/KMS/KGSL ioctls, ship
  kernel code, or require kernel patches. Direct Turnip/KGSL is out of scope;
  use system Vulkan/Metal or SwiftShader.
- **Do** build Mode B only via `macos-baremetal.nix` / `iland-baremetal-macos`.
- **Don’t** MacPorts-assume `/opt/local` in new code; Nix-substitute ANGLE paths.
- **Don’t** document Mode B as the default present path for Wawona apps.
