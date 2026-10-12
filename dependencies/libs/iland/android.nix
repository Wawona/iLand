# iland userland core for Android (Mode A — in-window GBM/EGL/DRM over ANGLE).
#
# Cross-compiles libiland_userland.a with the NDK via wwn-toolchain. Android
# shims live under ./android/ (IOSurface compat, GBM, DRM IPC stubs); upstream
# drm_linux.c + drm_ioctl.c + egl.c are patched in postPatch.
{
  lib,
  pkgs,
  buildModule,
  androidToolchain ? (import "${toolchainSrc}/dependencies/toolchains/android.nix" {
    inherit lib pkgs;
  }),
  toolchainSrc ? null,
  ...
}:

let
  ilandVersion = import ./version.nix;
  angle = buildModule.buildForAndroid "angle" { };
  libwayland = buildModule.buildForAndroid "libwayland" { };
  androidDir = ./android;
  waylandScanner = pkgs.wayland-scanner;
  waylandProtocols = pkgs.wayland-protocols;
in
pkgs.stdenv.mkDerivation {
  pname = "iland-userland";
  version = ilandVersion;

  src = ./upstream;

  dontConfigure = true;
  dontFixup = true;

  nativeBuildInputs = [ pkgs.python3 waylandScanner ];

  postPatch = ''
    cp -f ${androidDir}/DisplaySurface.h shims/drm/displaysurface/include/DisplaySurface.h
    cp -f ${androidDir}/iland_present.h shims/drm/drm/include/iland_present.h
    cp -f ${androidDir}/drm.h shims/drm/drm/include/drm.h
    cp -f ${androidDir}/gbm_priv.h shims/gbm/include/gbm_priv.h
    cp -f ${androidDir}/iosurface_compat.h shims/include/iosurface_compat.h

    # Wayland-EGL winsys: Apple IOSurface headers → Android AHB compat.
    sed -i 's|#include <IOSurface/IOSurfaceRef.h>|#include "iosurface_compat.h"|' \
      shims/egl/include/iland_wl_winsys.h \
      shims/egl/include/iland_wl_ops.h \
      shims/egl/src/egl_wayland.c
    # CFSTR / CoreFoundation only used for WWNBottomUp; iosurface_compat no-ops
    # IOSurfaceSetValue. Strip any accidental CF include if added later.
    sed -i '/#include <CoreFoundation/d' shims/egl/src/egl_wayland.c || true

    # Drop macOS WindowServer plist probe; keep preferred-mode + default sizes.
    python3 - <<'PY'
from pathlib import Path
path = Path("shims/drm/drm/src/drm_linux.c")
text = path.read_text()
start = '    CFURLRef url = CFURLCreateWithFileSystemPath(NULL,'
end = '    if (url) CFRelease(url);'
si = text.find(start)
ei = text.find(end)
if si < 0 or ei < 0:
    raise SystemExit("drm_linux.c CF plist block anchors missing")
ei = text.find('\n', ei) + 1
text = text[:si] + text[ei:]
path.write_text(text)
PY

    sed -i '/#include <IOSurface/d' shims/drm/drm/src/drm_linux.c
    sed -i '/#include <mach\/mach.h>/d' shims/drm/drm/src/drm_linux.c
    sed -i '/#include <CoreFoundation/d' shims/drm/drm/src/drm_linux.c
    sed -i '/#include <CoreGraphics/d' shims/drm/drm/src/drm_linux.c
    sed -i '1i #include "iosurface_compat.h"' shims/drm/drm/src/drm_linux.c

    sed -i 's/mach_port_t surface_port/uint32_t surface_port/g' shims/drm/drm/src/drm_linux.c
    sed -i 's/MACH_PORT_NULL/0/g' shims/drm/drm/src/drm_linux.c
    sed -i 's/surface_port = IOSurfaceCreateMachPort(surf);/surface_port = 0; (void)surf;/g' shims/drm/drm/src/drm_linux.c
    sed -i 's/mach_port_deallocate(mach_task_self(), surface_port);/(void)surface_port;/g' shims/drm/drm/src/drm_linux.c

    # egl.c: no Accelerate / IOSurface / Apple dlopen paths on Android.
    sed -i '/#include <TargetConditionals.h>/d' shims/egl/src/egl.c
    sed -i '/#include <Accelerate\/Accelerate.h>/d' shims/egl/src/egl.c
    sed -i 's|#include <IOSurface/IOSurfaceRef.h>|#include "iosurface_compat.h"|' shims/egl/src/egl.c

    python3 - <<'PY'
from pathlib import Path
path = Path("shims/egl/src/egl.c")
text = path.read_text()
old = "        g_zerocopy_enabled = (e && e[0] == '0') ? 0 : 1;"
if old not in text:
    raise SystemExit("egl.c zerocopy default anchor missing")
text = text.replace(old, "        g_zerocopy_enabled = 0; (void)e;", 1)
# Channel swap lives in swap_rgba_to_bgra() with an #ifdef __ANDROID__ arm —
# no more vImage text rewrite here.
if 'swap_rgba_to_bgra' not in text:
    raise SystemExit("egl.c missing swap_rgba_to_bgra helper")
# The Android libEGL.so / libGLESv2.so dlopen arms live in egl.c behind
# `#elif defined(__ANDROID__)`. They used to be patched in here, anchored on the
# macOS dlopen lines, which broke silently the moment those lines changed.
if 'defined(__ANDROID__)' not in text:
    raise SystemExit("egl.c lost its __ANDROID__ dlopen arm")
path.write_text(text)
PY
  '';

  buildPhase = ''
    runHook preBuild

    CC="${androidToolchain.androidCC}"
    AR="${androidToolchain.androidAR}"

    DMABUF_XML="${waylandProtocols}/share/wayland-protocols/unstable/linux-dmabuf/linux-dmabuf-unstable-v1.xml"
    wayland-scanner client-header "$DMABUF_XML" linux-dmabuf-v1-client-protocol.h
    wayland-scanner private-code  "$DMABUF_XML" linux-dmabuf-v1-protocol.c

    INCLUDES="\
      -Ishims/include \
      -I${androidDir} \
      -Ishims/drm/displaysurface/include \
      -Ishims/drm/drm/include \
      -Ishims/gbm/include \
      -Ishims/egl/include \
      -Ishims/wayland-egl/include \
      -Ishims/udev/include \
      -I${libwayland}/include \
      -I${libwayland}/include/wayland \
      -I${angle}/include \
      -I${angle}/include/EGL \
      -I${angle}/include/GLES2"

    # -I. so generated linux-dmabuf-v1-client-protocol.h is visible to egl_wayland.c
    COMMON_FLAGS="-fPIC -O2 -std=c11 -I. $INCLUDES -Wno-int-conversion -D_GNU_SOURCE"

    OBJS=""
    for src in \
      ${androidDir}/iosurface_compat.c \
      ${androidDir}/DisplaySurface.c \
      ${androidDir}/gbm.c \
      ${androidDir}/drm_ipc_stubs.c \
      shims/drm/drm/src/drm_linux.c \
      shims/drm/drm/src/drm_ioctl.c \
      shims/udev/src/udev.c \
      shims/egl/src/iland_wl_ops.c \
      shims/egl/src/egl.c; do
      obj="$(basename "$src").o"
      echo "CC $src"
      "$CC" -c "$src" $COMMON_FLAGS -o "$obj"
      OBJS="$OBJS $obj"
    done

    "$AR" rcs libiland_userland.a $OBJS

    # Wayland-EGL winsys (AHB id in dmabuf modifier — same #86 convention).
    # Partial-link then localize zwp_linux_* so they do not clash with weston's
    # copies when both archives are --whole-archive into libwawona.so (same
    # problem ios.nix solves with -unexported_symbols_list).
    WL_OBJS=""
    for src in \
      shims/wayland-egl/src/wayland_egl.c \
      shims/egl/src/egl_wayland.c \
      linux-dmabuf-v1-protocol.c; do
      obj="wl_$(basename "$src").o"
      echo "CC $src"
      "$CC" -c "$src" $COMMON_FLAGS -o "$obj"
      WL_OBJS="$WL_OBJS $obj"
    done
    "$CC" -r -nostdlib $COMMON_FLAGS -o iland_wayland_egl.o $WL_OBJS
    OBJCOPY="$("$CC" -print-prog-name=llvm-objcopy)"
    "$OBJCOPY" --wildcard --localize-symbol='zwp_linux_*' iland_wayland_egl.o
    "$AR" rcs libiland_wayland_egl.a iland_wayland_egl.o

    # Vulkan Wayland WSI (optional; ICD-neutral present_pixels path).
    if [ -f shims/vulkan-wayland/src/vk_wayland_wsi.c ]; then
      VK_WL_CFLAGS="$COMMON_FLAGS -Ishims/vulkan-wayland/include -I${pkgs.vulkan-headers}/include"
      echo "CC shims/vulkan-wayland/src/vk_wayland_wsi.c"
      "$CC" -c shims/vulkan-wayland/src/vk_wayland_wsi.c $VK_WL_CFLAGS \
        -o vk_wayland_wsi.o
      "$AR" rcs libiland_wayland_vulkan.a vk_wayland_wsi.o
    fi

    runHook postBuild
  '';

  installPhase = ''
    mkdir -p $out/lib $out/lib/pkgconfig $out/include/EGL $out/include/GLES2 $out/include/GLES3 $out/include/KHR $out/nix-support

    cp libiland_userland.a $out/lib/
    cp libiland_wayland_egl.a $out/lib/
    if [ -f libiland_wayland_vulkan.a ]; then
      cp libiland_wayland_vulkan.a $out/lib/
    fi

    cp shims/gbm/include/gbm.h                       $out/include/
    cp shims/egl/include/egl_shim.h                  $out/include/
    cp shims/egl/include/iland_wl_winsys.h           $out/include/
    cp shims/wayland-egl/include/iland_wayland_egl.h $out/include/
    if [ -f shims/vulkan-wayland/include/iland_vk_wayland.h ]; then
      cp shims/vulkan-wayland/include/iland_vk_wayland.h $out/include/
    fi
    cp shims/drm/displaysurface/include/DisplaySurface.h $out/include/
    cp shims/include/drm_fourcc.h                    $out/include/
    cp shims/include/xf86drm.h                       $out/include/
    cp shims/include/xf86drmMode.h                   $out/include/
    cp shims/include/esUtil.h                        $out/include/ || true
    cp shims/drm/drm/include/drm.h                   $out/include/ || true
    cp shims/drm/drm/include/iland_present.h         $out/include/
    cp shims/udev/include/libudev.h                  $out/include/
    # Mode A store-safe open() redirect — force-included by GL/DRM clients so
    # their raw open("/dev/dri/cardN") reaches the in-process virtual fd (#58).
    cp shims/drm/drm/include/iland_drm_open_compat.h $out/include/
    # Consumed by Wawona's iland_presenter_android.c (JNI presenter bridge).
    cp shims/include/iosurface_compat.h              $out/include/

    cp -r ${angle}/include/EGL/.   $out/include/EGL/
    cp -r ${angle}/include/GLES2/. $out/include/GLES2/
    cp -r ${angle}/include/GLES3/. $out/include/GLES3/ || true
    cp -r ${angle}/include/KHR/.   $out/include/KHR/

    # waypipe wrap-gbm + meson clients expect pkg-config `gbm`.
    cat > $out/lib/pkgconfig/gbm.pc <<EOF
prefix=$out
exec_prefix=\''${prefix}
libdir=\''${exec_prefix}/lib
includedir=\''${prefix}/include

Name: gbm
Description: iland userland GBM (AHB-backed) for Android
Version: 0.1.0
Libs: -L\''${libdir} -liland_userland
Cflags: -I\''${includedir}
EOF

    echo "${angle}" > $out/nix-support/angle-path
    echo "dylib" > $out/nix-support/link-kind
    echo "mode-a-userland" > $out/nix-support/iland-mode
  '';

  passthru = {
    inherit angle;
    angleLibs = "${angle}/lib";
  };

  meta = with lib; {
    description = "iland userland in-window Linux-graphics compat (GBM/EGL/DRM + ANGLE) for Android";
    homepage = "https://github.com/Wawona/iLand";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
