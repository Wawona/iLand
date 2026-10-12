# Mode B baremetal display SPI (macOS 26 / 25F80)

Private SkyLight / CoreDisplay / QuartzCore entry points used by CoreBedtime
`framebufferd` and Wawona's Mode B `libwayland-mac.dylib` helper of the same
name. Desktop / LockScreen replacement only. Never ship on store-safe targets.

**Verified on:** macOS 26.5.1 (25F80), arm64e dyld shared cache extracted with
`ipsw dyld extract` into `~/GhidraVibe/dyld-extracted/modeb-25F80/`.

**RE method:** `dyld_info`, ObjC runtime encodings, Xcode `llvm-objdump -d
--macho --dis-symname`. GhidraVibe MCP headless was blocked on this host by a
system-wide JDK 21 `SIGBUS` (`CodeHeap::allocate`, `BUS_ADRALN`) for every
Temurin/Zulu 21 tried. Java 11 still runs. Re-import the extracted dylibs into
Ghidra when JDK 21 works and attach decompiles under `disasm-25F80/`.

Upstream reference:
[CoreBedtime/iland `framebufferd/src/main.m`](https://github.com/CoreBedtime/iland/blob/main/shims/drm/framebufferd/src/main.m).

Wawona implementation:
`dependencies/libs/iland/upstream/shims/drm/framebufferd/src/main.m`.

---

## Call order (must match CoreBedtime display bring-up)

Apple `WindowServer` must already be down for **DispDrvInit /
CAWindowServer / presentSurface** (session-only bootout; never sticky
`unload -w` / `launchctl disable`).

**Mach registration is separate.** On 25F80:

- Legacy `bootstrap_register` after WS bootout fails (`kr=124` / `kr=141`).
- A name registered with `bootstrap_register` *before* WS unload becomes
  `bootstrap_look_up` **"exception protected"** after WS is gone.
- Even **launchd MachServices** + `bootstrap_check_in` still fails look_up
  from the compositor when it inherits a dead Aqua **session bootstrap
  subset** (`KERN_EXCEPTION_PROTECTED` / 32). Fix: drm/libinput walk
  `bootstrap_parent` to the root and look_up again (`drm_bootstrap_look_up`).

Classic therefore publishes via **launchd MachServices** +
`bootstrap_check_in`, with `WWN_MODEB_DEFER_DISPLAY=1`, and the compositor
resolves the name via parent bootstrap walk:

1. Extract helpers from `libwayland-mac.dylib` while Aqua is up
2. `launchctl bootstrap` `com.wayland-mac.framebufferd` /
   `com.wayland-mac.inputd` (MachServices); framebufferd check_in, touches
   `modeb-mach.ready`, waits
3. Session-only unload Path B `watchdogd` + WindowServer
4. Touch `modeb-display-go` so framebufferd continues
5. DispDrvInit pipeline (below)
6. Inject compositor (`DYLD_INSERT_LIBRARIES`); dylib skips helper-owned
   framebufferd when `modeb-mach.ready` is present

DispDrvInit pipeline (WS already down):

1. `dlopen` CoreDisplay, SkyLight, QuartzCore
2. Resolve symbols (SymRez; fail closed if any required pointer is NULL)
3. `_SLSInitialize()`
4. `_InitializeCoreDisplay(WSCDInitializeVtable.callbacks)`
5. Install fake `___sessionControlRef` graph (offsets below)
6. `_CGXDisplayDriverInitialize()`
7. `[CAWindowServer serverWithOptions:@{@"fetchFrozenSurfaces": @YES}]`
8. Take first `CAWindowServerDisplay` via `-displays`
9. Present with `-presentSurface:withOptions:` on a 120 Hz timer / Mach kick

Do **not** call WindowServer-client display APIs after step 7
(`CVDisplayLink`, `CGGetActiveDisplayList`, `SLSGetActiveDisplayList`, …).
`CGSRunningInServer()` is true and those paths assert.

---

## C / C++ SPI

### `_SLSInitialize` (SkyLight)

| | |
|--|--|
| **Symbol** | `_SLSInitialize` (exported) |
| **Image** | `SkyLight.framework` |
| **Prototype** | `void SLSInitialize(void);` |
| **ABI** | No args. `dispatch_once` wrapper; second call is a no-op `ret`. |
| **Role** | One-shot SkyLight server/runtime bring-up. |
| **Safe call** | Always call before CoreDisplay init. Idempotent. NULL-check resolve. |
| **Disasm** | [`disasm-25F80/SLSInitialize.s`](disasm-25F80/SLSInitialize.s) |

### `_InitializeCoreDisplay` (CoreDisplay)

| | |
|--|--|
| **Symbol** | `_InitializeCoreDisplay` (exported) |
| **Image** | `CoreDisplay.framework` |
| **Prototype** | `void InitializeCoreDisplay(const void *wscd_callbacks);` |
| **ABI (25F80)** | `x0` = source pointer. Body: `memcpy(dst_global, x0, 0x6b8)` then queue/callback bookkeeping. |
| **Role** | Copies the WindowServer↔CoreDisplay callback vtable into CoreDisplay globals. |
| **Argument** | Address of SkyLight local `WSCDInitializeVtable.callbacks` (SymRez name `_WSCDInitializeVtable.callbacks`). **Must not be NULL.** Size copied is **0x6b8** bytes on 25F80. |
| **Safe call** | Resolve callbacks first; abort if NULL. Do not invent a smaller stub table. |
| **Disasm** | [`disasm-25F80/InitializeCoreDisplay.s`](disasm-25F80/InitializeCoreDisplay.s) |

### `_CGXDisplayDriverInitialize` (CoreDisplay)

| | |
|--|--|
| **Symbol** | `_CGXDisplayDriverInitialize` (exported) |
| **Image** | `CoreDisplay.framework` |
| **Prototype** | `void CGXDisplayDriverInitialize(void);` |
| **ABI** | No useful args (large stack frame; drives IOKit / page-flip / prefs). |
| **Role** | Bring up the CGX display driver that owns physical outputs. This is what makes `presentSurface` hit the panel. |
| **Preconditions** | SIP fully disabled; helper entitlements (displayservice / IOKit profile); Apple WindowServer **not** holding the display; `_InitializeCoreDisplay` already done. |
| **Safe call** | Only after WS is session-stopped. KEEP_WS probes must **skip** this path (blanking risk). |
| **Disasm** | [`disasm-25F80/CGXDisplayDriverInitialize.s`](disasm-25F80/CGXDisplayDriverInitialize.s) (partial) |

### `WSCDInitializeVtable.callbacks` (SkyLight, local)

| | |
|--|--|
| **Symbol** | `WSCDInitializeVtable.callbacks` (local `s`; SymRez: `_WSCDInitializeVtable.callbacks`) |
| **Type** | Opaque callback table; treated as `const void *` of length **0x6b8** |
| **Role** | Source blob for `_InitializeCoreDisplay`. |

### `___sessionControlRef` (SkyLight, BSS)

| | |
|--|--|
| **Symbol** | `___sessionControlRef` (local BSS; SymRez: `___sessionControlRef`) |
| **Type** | `void **` (global pointer slot) |
| **Role** | SkyLight session controller. framebufferd writes a **fake** object graph. |
| **Fake layout (CoreBedtime / us, 25F80-locked)** | See table below. Offsets are **not** ABI-stable across OS updates. Re-verify on each macOS point release. |

| Offset (bytes) | Write |
|--|--|
| `fake_sub_object+232` | `→ fake_session_data` |
| `fake_sub_object+176` | `→ &fake_connections_ptr` |
| `fake_sub_object+256` | `→ fake_cursor_ctrl` |
| `fake_cursor_ctrl+120` | `uint64_t 0x10` |
| `fake_session_ctrl+32` | `→ fake_sub_object` |
| `*___sessionControlRef` | `→ fake_session_ctrl` |
| `fake_sub_object+0xD0` | `→ fake_event_data` (calloc 0x1000) |
| `fake_event_data+0xA0` | `→ fake_event_caps` (calloc 0x100) |

### `__ZL9_g_server` (SkyLight, BSS)

| | |
|--|--|
| **Symbol** | `__ZL9_g_server` (mangled static `g_server`) |
| **Type** | `void **` |
| **Role** | SkyLight's pointer to the active `CAWindowServer` instance. Set after `serverWithOptions:`. |

### `_CARenderServerRegister` (QuartzCore; imported by SkyLight)

| | |
|--|--|
| **Symbol** | `_CARenderServerRegister` (defined in QuartzCore; SkyLight has `U` import) |
| **Prototype** | `void CARenderServerRegister(const char *name);` |
| **ABI** | Tail-calls `CA::Render::Server::register_name(char const*)`. |
| **Role** | Registers a CA render server name. |
| **Wawona usage** | Resolved historically; **not called**. Old typedef `void (*)(int)` was wrong. Do not call with an `int`. |
| **Disasm** | [`disasm-25F80/CARenderServerRegister.s`](disasm-25F80/CARenderServerRegister.s) |

### QuartzCore `__ZL14_shared_server`

| | |
|--|--|
| **Symbol** | `__ZL14_shared_server` (local) |
| **Type** | `void **` |
| **Role** | Cleared to NULL before `serverWithOptions:` so a fresh server is created. |

---

## Objective-C SPI (QuartzCore)

Encodings from live 25F80 runtime (`method_getTypeEncoding`). Full dump:
[`disasm-25F80/objc-encodings.txt`](disasm-25F80/objc-encodings.txt).

### `+ [CAWindowServer serverWithOptions:]`

| | |
|--|--|
| **Encoding** | `@24@0:8@16` |
| **Prototype** | `+ (instancetype)serverWithOptions:(NSDictionary *)options;` |
| **Options used** | `@{ @"fetchFrozenSurfaces": @YES }` (CoreBedtime) |
| **Safe call** | Class must exist (`NSClassFromString`). Abort if returns nil. |

### `- [CAWindowServer displays]`

| | |
|--|--|
| **Encoding** | `@16@0:8` |
| **Prototype** | `- (NSArray<CAWindowServerDisplay *> *)displays;` |
| **Safe call** | Prefer this over digging `_impl`. Abort if empty / nil. |

### `CAWindowServer` ivar `_impl`

| | |
|--|--|
| **Type encoding** | `^{CAWindowServerImpl=^{__CFArray}@I@?}` |
| **Offset** | 8 |
| **Fallback** | First field is a `CFArray` of displays (CoreBedtime / our fallback). Prefer `-displays`. |

### `- [CAWindowServerDisplay presentSurface:withOptions:]`

| | |
|--|--|
| **Encoding** | `v32@0:8^{__IOSurface=}16@24` |
| **Prototype** | `- (void)presentSurface:(IOSurfaceRef)surface withOptions:(NSDictionary *)options;` |
| **Safe call** | Instance method (verified `class_getInstanceMethod`). Surface must be pipeline-compatible (`DisplaySurface_create`). Empty options `@{}` matches CoreBedtime. Only after DispDrvInit + owned display. |

### `- [CAWindowServerDisplay bounds]`

| | |
|--|--|
| **Encoding** | `{CGRect={CGPoint=dd}{CGSize=dd}}16@0:8` |
| **Prototype** | `- (CGRect)bounds;` |

### Related (not always called)

| Selector | Encoding / notes |
|--|--|
| `-displayedSurface` | `^{__IOSurface=}16@0:8` |
| `-framebufferFormat` | `I16@0:8` (`uint32_t`) |
| `-setBlanked:` | `v20@0:8B16` |
| `-freeze` | `v16@0:8` |

---

## What the Mode B dylib actually hooks

`libwayland-mac.dylib` does **not** ObjC-swizzle CoreDisplay/SLS. It:

1. Dobby-hooks libc `open` / `ioctl` / epoll-shim for DRM emulation
2. Spawns embedded `framebufferd` / `inputd` / `amfiexceptiond`
3. `framebufferd` uses SymRez + ObjC as above

Safety for takeover therefore means **safe SPI calling inside framebufferd**, plus Path B IOWatchdog coverage before unloading WindowServer (see Wawona Mode B rules).

---

## Safe-calling checklist (implement / review)

1. Resolve every required symbol; **abort** if any required pointer is NULL.
2. Never call `_InitializeCoreDisplay(NULL)`.
3. Never call `_CGXDisplayDriverInitialize` while Apple WindowServer owns the panel (`WWN_MODEB_KEEP_WS` skips the whole CoreDisplay claim path).
4. Do not call `_CARenderServerRegister` unless the prototype `const char *` is intentional.
5. Prefer `-displays` over `_impl` ivar walks.
6. Re-verify fake `___sessionControlRef` offsets and `0x6b8` copy size on each OS bump.
7. Entitlements on `framebufferd` must include the display/IOKit profile used at codesign time (`macos-baremetal.nix`).

---

## Artifact locations

| Artifact | Path |
|--|--|
| Extracted dylibs (local RE) | `~/GhidraVibe/dyld-extracted/modeb-25F80/{CoreDisplay,SkyLight,QuartzCore}` |
| This doc | `iLand/docs/mode-b/baremetal-display-spi-25F80.md` |
| Disasm snippets | `iLand/docs/mode-b/disasm-25F80/` |
| Product Mode B prose | `Wawona/docs/iland-mode-a-b-desktop.md` |
