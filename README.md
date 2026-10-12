# iLand

[![CI](https://github.com/Wawona/iLand/actions/workflows/ci.yml/badge.svg)](https://github.com/Wawona/iLand/actions/workflows/ci.yml)

Wawona's userland Linux-graphics compatibility layer: GBM / EGL / DRM-KMS over
Apple `IOSurface` + ANGLE, providing the "Mode A" in-window present path that
stays inside the host app for Wayland/Weston GL clients
(kmscube, es2gears, weston-simple-egl) on Apple platforms.

Extracted from the Wawona monorepo. Built with [wwn-toolchain](https://github.com/Wawona/wwn-toolchain).

## Layer identity (L1) — acyclic DAG

```text
L0 wwn-toolchain (substrate: cairo/pango/pixman/libwayland/…)
   ▼
L1 iLand (this repo: complete graphics stack) → depends on toolchain ONLY
   ▼
L2 wwn-kmscube → L3 wwn-weston → L4 Wawona
```

`iLand` is **L1: the complete Wawona graphics stack** (userland
DRM/KMS/GBM/EGL present + Mode A/B; ANGLE, SwiftShader, MoltenVK, and Vulkan ICD
packaging). It depends on
`wwn-toolchain` (L0) only. Never add weston/kmscube/waypipe/Wawona as a flake
input, and never move substrate libs (pixman/cairo/pango) into this repo.
Canonical: `Wawona/docs/wwn-repo-dag.md`; workspace rule `wawona-repo-dag`.

The DRM/KMS/GBM device is runtime-only userland emulation. Wawona code never
opens real `/dev/dri` or `/dev/kgsl`, forwards real DRM/KMS/KGSL ioctls, ships
kernel code, or requires kernel patches. Direct Turnip/KGSL is therefore out
of scope; use system Metal/Vulkan or SwiftShader.

## Credit / upstream

Vendored tip for later port (not wired into recipes):
`dependencies/libs/iland/corebedtime-tip/` (see `SYNC.md` there). Production
shims stay under `dependencies/libs/iland/upstream/`.



`iLand` was inspired by and originally forked from
[**corebedtime/iland**](https://github.com/CoreBedtime/iland) — the project that
pioneered replacing the macOS WindowServer/SkyLight stack with a custom
`IOSurface`/Metal-backed framebuffer that mimics Linux DRM/KMS/EGL/GBM. All
credit for the original macOS approach goes to bedtime
([corebedtime/iland](https://github.com/CoreBedtime/iland)).

This repo is the new home of what used to live at `Wawona/iland`. Beyond the
upstream macOS-only layer, `iLand` adds and implements substantial changes:

- **KMS/DRM on iOS** and across the rest of the Apple platform family
  (iPadOS/tvOS/visionOS), not just macOS.
- **Android** support.
- Cross-compiled, Nix-wrapped recipes (via `wwn-toolchain`) and a composable
  `registryFragment` consumed by Wawona and `wwn-weston`.
- The DRM/EGL/GBM/udev shim set under `dependencies/libs/iland/upstream/shims/`
  that `wwn-weston` links against for the nested-compositor present path.

## Use

```nix
inputs.iLand.url = "github:Wawona/iLand";

# Wawona merges the fragment and threads the source for shim copying:
registry = wwn-toolchain.lib.baseRegistry // iLand.registryFragment;
extraArgs = { ilandSrc = iLand; };  # weston copies upstream/shims/* from here
```

- `registryFragment.iland` — Mode A per-platform userland archives (iOS family +
  macOS + Android). App-Store-safe in-window present.
- `registryFragment.angle` / `registryFragment.swiftshader` — L1-owned graphics
  translator and software Vulkan recipes. Consumers must merge this fragment;
  toolchain `baseRegistry` contains fail-loud ownership sentinels only.
- `registryFragment.iland-baremetal` — **macOS only** Mode B
  `libwayland-mac.dylib` (Dobby + embedded `framebufferd` / `inputd` /
  `amfiexceptiond`). Desktop Replacement / WindowServer path. Never built for
  iOS/iPadOS/tvOS/watchOS/visionOS/Android.
- **kmscube** lives in [wwn-kmscube](https://github.com/Wawona/wwn-kmscube) (GL smoke test over this stack).
- `dependencies/libs/iland/upstream/` - vendored upstream iland sources + DRM/EGL/GBM/udev shims that `wwn-weston` consumes via `ilandSrc`.

## Mode A vs Mode B

| | Mode A (default) | Mode B (desktop-host) |
|---|---|---|
| Artifact | `libiland_userland.a` | `libwayland-mac.dylib` |
| Platforms | macOS, iOS/iPadOS/visionOS, Android; tvOS/watchOS stubs | **macOS only** |
| Present | In-process `iland_drm_set_present_callback` | Mach IPC → `framebufferd` (SkyLight) |
| SIP / root | Not required | SIP fully disabled (`csrutil disable`) + root |
| App Store | Yes | No — Developer ID / desktop-host only |

Wawona wires Mode B only when SIP allows (`WWNSipStatus`) **and** Settings →
Desktop → Enable Desktop Replacement is on. Otherwise Mode A.

## Standalone build

```sh
nix build .#iland-macos              # Mode A macOS archive
nix build .#iland-ios                # Mode A iOS archive
nix build .#iland-baremetal-macos    # Mode B dylib (macOS only)
```

## Versioning

`VERSION` at the repo root is CalVer (`YY.M.D`). Nix packages (`iland-userland`,
`iland-baremetal`, gl-clients, iomfb) and Wawona Settings → Dependencies read
that file. Tag releases as `vYY.M.D`.

## License

The Wawona Nix packaging in this repo is MIT (see `LICENSE`). The vendored
upstream `iland` sources under `dependencies/libs/iland/upstream/` retain their
original upstream license terms.

## Agents

See [AGENTS.md](./AGENTS.md) for Mode A/B editing rules.
