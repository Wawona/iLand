# iland userland core for macOS (Mode A — in-window, App-Store-safe shape).
#
# Builds the IOSurface/ANGLE-backed Linux-graphics compat shims as a single
# static archive (libiland_userland.a). KMS/GBM clients (kmscube, es2gears)
# link that. Wayland-EGL clients (weston-simple-egl, opengl-cube) also link
# libiland_wayland_egl.a (wl_egl_window + linux-dmabuf, not the KMS presenter):
#
#   displaysurface  IOSurface creation (WSPixelFormat / CAWindowServer-compatible)
#   gbm             Generic Buffer Management backed by IOSurface
#   egl             EGL/GLES entrypoints wrapping ANGLE (nixpkgs#angle)
#   libEGL.dylib    Public EGL ABI (Wayland-EGL winsys + dma_buf query).
#                   Nested niri/weston dlopen this; ANGLE is libEGL_angle.dylib.
#   drm             DRM/KMS userland API (drmMode*, gbm handle registry)
#
# Mode B (Dobby code injection, framebufferd/SkyLight, AMFI bypass, inputd) is
# intentionally NOT built here; it lives behind the `iland-baremetal` gate.
{
  lib,
  pkgs,
  stdenv,
  buildModule,
  # Legacy flag: Mode B dylib now builds via macos-baremetal.nix
  # (`iland-baremetal` registry entry). Keeping this for callers that still
  # pass baremetal=true — it only stages sources for inspection, it does NOT
  # produce libwayland-mac.dylib (use buildForMacOS "iland-baremetal").
  baremetal ? false,
  # Injected by wwn-toolchain (xcodeUtils === the apple toolchain). Previously
  # imported via ../../utils/xcode-wrapper.nix.
  xcodeUtils,
  ...
}:

let
  ilandVersion = import ./version.nix;
  angle = buildModule.buildForMacOS "angle" { };
  # Wayland-EGL winsys: libwayland-client for the protocol calls, scanner +
  # protocol XML to generate the linux-dmabuf client bindings the winsys posts
  # IOSurfaces through.
  libwayland = buildModule.buildForMacOS "libwayland" { };
  waylandScanner = pkgs.wayland-scanner;
  waylandProtocols = pkgs.wayland-protocols;
in
pkgs.stdenv.mkDerivation {
  pname = "iland-userland";
  version = ilandVersion;

  src = ./upstream;

  # Needs the macOS SDK (IOSurface/Accelerate/Foundation frameworks) via xcrun.
  __noChroot = true;

  # wayland-scanner is multi-output; take it from PATH rather than guessing
  # which output holds the binary.
  nativeBuildInputs = [ waylandScanner ];

  dontConfigure = true;

  preBuild = ''
    # De-MacPorts: rewrite the shim's last-resort ANGLE path from /opt/local to
    # the Nix ANGLE. This is only the unbundled fallback — inside Wawona.app the
    # shim resolves @rpath/Frameworks first so the process keeps a single ANGLE
    # image (two copies duplicate ANGLESwapCGLLayer and crash the client).
    substituteInPlace shims/egl/src/egl.c \
      --replace "/opt/local/lib/libEGL.dylib"    "${angle}/lib/libEGL.dylib" \
      --replace "/opt/local/lib/libGLESv2.dylib" "${angle}/lib/libGLESv2.dylib"
  '';

  buildPhase = ''
    runHook preBuild

    # Robust macOS SDK detection (mirrors pixman/macos.nix).
    unset DEVELOPER_DIR
    MACOS_SDK=$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)
    if [ ! -d "$MACOS_SDK" ]; then
      MACOS_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"
    fi
    if [ ! -d "$MACOS_SDK" ]; then
      MACOS_SDK=$(${xcodeUtils.findXcodeScript}/bin/find-xcode)/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
    fi
    if [ ! -d "$MACOS_SDK" ]; then
      echo "ERROR: MacOSX SDK not found." >&2
      exit 1
    fi
    export SDKROOT="$MACOS_SDK"

    CLANG="${pkgs.clang}/bin/clang"
    AR="ar"

    # linux-dmabuf client bindings for the Wayland-EGL winsys. Generated rather
    # than vendored so the marshalling stays in step with libwayland.
    DMABUF_XML="${waylandProtocols}/share/wayland-protocols/unstable/linux-dmabuf/linux-dmabuf-unstable-v1.xml"
    wayland-scanner client-header "$DMABUF_XML" linux-dmabuf-v1-client-protocol.h
    wayland-scanner private-code  "$DMABUF_XML" linux-dmabuf-v1-protocol.c

    INCLUDES="\
      -I. \
      -Ishims/include \
      -Ishims/drm/displaysurface/include \
      -Ishims/drm/drm/include \
      -Ishims/gbm/include \
      -Ishims/egl/include \
      -Ishims/wayland-egl/include \
      -I${libwayland}/include \
      -I${angle}/include"

    COMMON_FLAGS="-isysroot $SDKROOT -mmacosx-version-min=12.0 -fPIC -O2 -std=c11 $INCLUDES"

    OBJS=""
    for src in \
      shims/drm/displaysurface/src/DisplaySurface.c \
      shims/gbm/src/gbm.c \
      shims/drm/drm/src/drm.c \
      shims/drm/drm/src/drm_linux.c \
      shims/drm/drm/src/drm_ioctl.c \
      shims/egl/src/iland_wl_ops.c \
      shims/egl/src/egl.c; do
      obj="$(basename "$src").o"
      echo "CC $src"
      "$CLANG" -c "$src" $COMMON_FLAGS -o "$obj"
      OBJS="$OBJS $obj"
    done

    "$AR" rcs libiland_userland.a $OBJS

    # Wayland-EGL winsys, kept out of the core archive: it needs
    # libwayland-client, and a KMS-only client (kmscube) must not have to link
    # Wayland to use iland. egl.c refers to it weakly, so linking this archive
    # is what turns EGL_PLATFORM_WAYLAND on. Clients that link it also need
    # -lwayland-client.
    WL_OBJS=""
    for src in \
      shims/wayland-egl/src/wayland_egl.c \
      shims/egl/src/egl_wayland.c \
      linux-dmabuf-v1-protocol.c; do
      obj="wl_$(basename "$src").o"
      echo "CC $src"
      "$CLANG" -c "$src" $COMMON_FLAGS -o "$obj"
      WL_OBJS="$WL_OBJS $obj"
    done

    # wayland-scanner's linux-dmabuf interfaces are the same symbols weston
    # generates from the same XML, and the app force-loads both archives, so
    # exporting ours is a duplicate-symbol link error. Partial-link the winsys
    # into one object first — the reference and the definition must end up in
    # the same object for privatising to leave anything resolvable — then hide
    # the protocol globals. Same treatment foot's protocol symbols get.
    echo "_zwp_linux_*" > unexported-protocol.txt
    ld -r -arch arm64 -o iland_wayland_egl.o $WL_OBJS \
      -unexported_symbols_list unexported-protocol.txt

    "$AR" rcs libiland_wayland_egl.a iland_wayland_egl.o

    # Public EGL ABI for nested compositors (niri, weston gl-renderer) that
    # dlopen libEGL.dylib. ANGLE is a private image (libEGL_angle.dylib) the
    # shim load_angle() opens. Do not LC_LOAD ANGLE here.
    echo "CC libEGL.dylib (iland Wayland-EGL shim)"
    "$CLANG" -dynamiclib -o libEGL.dylib \
      -isysroot "$SDKROOT" -mmacosx-version-min=12.0 \
      -Wl,-force_load,libiland_userland.a \
      -Wl,-force_load,libiland_wayland_egl.a \
      -L${libwayland}/lib -lwayland-client \
      -framework IOSurface -framework Foundation -framework CoreFoundation \
      -framework CoreGraphics -framework Accelerate -framework QuartzCore \
      -framework Metal \
      -lobjc \
      -install_name @rpath/libEGL.dylib \
      -compatibility_version 1 -current_version 1

    # Vulkan Wayland WSI (VK_KHR_wayland_surface + swapchain over the same
    # IOSurface dmabuf winsys). Separate archive so GLES-only clients skip it.
    VK_WL_CFLAGS="$COMMON_FLAGS -Ishims/vulkan-wayland/include -I${pkgs.vulkan-headers}/include"
    echo "CC shims/vulkan-wayland/src/vk_wayland_wsi.c"
    "$CLANG" -c shims/vulkan-wayland/src/vk_wayland_wsi.c $VK_WL_CFLAGS \
      -o vk_wayland_wsi.o
    "$AR" rcs libiland_wayland_vulkan.a vk_wayland_wsi.o

    runHook postBuild
  '';

  installPhase = ''
    mkdir -p $out/lib $out/include/EGL $out/include/GLES2 $out/include/GLES3 $out/include/KHR

    cp libiland_userland.a $out/lib/
    cp libiland_wayland_egl.a $out/lib/
    cp libiland_wayland_vulkan.a $out/lib/
    cp libEGL.dylib $out/lib/

    # Public client-facing headers
    cp shims/gbm/include/gbm.h                       $out/include/
    cp shims/egl/include/egl_shim.h                  $out/include/
    # Wayland-EGL winsys. wl_egl_window_* live in this archive, so a client must
    # NOT also link libwayland-egl (its vendor stub aborts) — link iland instead.
    cp shims/egl/include/iland_wl_winsys.h           $out/include/
    cp shims/wayland-egl/include/iland_wayland_egl.h $out/include/
    cp shims/vulkan-wayland/include/iland_vk_wayland.h $out/include/
    cp shims/drm/displaysurface/include/DisplaySurface.h $out/include/
    cp shims/include/drm_fourcc.h                    $out/include/
    cp shims/include/xf86drm.h                       $out/include/
    cp shims/include/xf86drmMode.h                   $out/include/
    cp shims/include/esUtil.h                        $out/include/ || true
    cp shims/drm/drm/include/drm.h                   $out/include/ || true
    cp shims/drm/drm/include/iland_present.h         $out/include/
    # Mode A store-safe open() redirect — force-included by GL/DRM clients so
    # their raw open("/dev/dri/cardN") reaches the in-process virtual fd (#58).
    cp shims/drm/drm/include/iland_drm_open_compat.h $out/include/

    # GLES/EGL/KHR headers come from ANGLE so clients get a consistent ABI.
    cp -r ${angle}/include/EGL/.   $out/include/EGL/
    cp -r ${angle}/include/GLES2/. $out/include/GLES2/
    cp -r ${angle}/include/GLES3/. $out/include/GLES3/ || true
    cp -r ${angle}/include/KHR/.   $out/include/KHR/

    # Record the ANGLE runtime libraries clients dlopen/link at runtime.
    mkdir -p $out/nix-support
    echo "${angle}" > $out/nix-support/angle-path
    echo "${if baremetal then "mode-b-baremetal" else "mode-a-userland"}" \
      > $out/nix-support/iland-mode
  '' + lib.optionalString baremetal ''
    # Mode B (opt-in, macOS-only, NOT App-Store-safe): stage the bare-metal
    # WindowServer-replacement sources for the external injection toolchain.
    # These are intentionally NOT compiled into libiland_userland.a and require
    # SIP off + root + private entitlements + Dobby to build/run.
    mkdir -p $out/baremetal/src
    cp -r shims/drm/framebufferd      $out/baremetal/src/ || true
    cp -r shims/libinput/input-daemon $out/baremetal/src/ || true
    cp -r shims/wayland/amfi          $out/baremetal/src/ || true
    cp -r shims/drm/symrez            $out/baremetal/src/ || true
    cat > $out/baremetal/README.txt <<'EOF'
    iland Mode B (bare-metal WindowServer replacement) — macOS only, opt-in.
    NOT App-Store-safe. Requires SIP disabled, root, private entitlements and
    Dobby. Build with the external iland baremetal harness; never linked into
    the default Wawona app. The default (Mode A) path needs none of this.
    EOF
  '';

  passthru = {
    inherit angle;
    angleLibs = "${angle}/lib";
  };

  meta = with lib; {
    description = "iland userland in-window Linux-graphics compat (GBM/EGL/DRM over IOSurface+ANGLE) for macOS";
    homepage = "https://github.com/Wawona/iLand";
    license = licenses.mit;
    platforms = platforms.darwin;
  };
}
