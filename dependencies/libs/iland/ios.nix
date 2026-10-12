# iland userland core for iOS (Mode A — in-window, App-Store-safe shape).
#
# Builds the IOSurface-backed Linux-graphics compat shims as a static archive
# (libiland_userland.a). GLES/EGL links ANGLE when enableGl is true
# (ILAND_ANGLE_STATIC, no dlopen). tvOS uses the same recipe with ANGLE
# from source GN (target_platform=tvos). watchOS stays enableGl=false.
{
  lib,
  pkgs,
  stdenv,
  buildModule,
  simulator ? false,
  enableGl ? true,
  iosToolchain ? (import ../../apple/default.nix { inherit lib pkgs; }),
  # Injected by wwn-toolchain (xcodeUtils === the apple toolchain). Previously
  # imported via ../../utils/xcode-wrapper.nix; falls back to iosToolchain.
  xcodeUtils ? iosToolchain,
  ...
}:

let
  ilandVersion = import ./version.nix;
  angle =
    if enableGl then
      buildModule.buildForIOS "angle" { inherit simulator; }
    else
      null;
  # Wayland-EGL winsys (same IOSurface-as-dmabuf path as macOS): libwayland-client
  # for the protocol calls, scanner + XML for the linux-dmabuf client bindings.
  # Vulkan WSI uses this winsys without ANGLE (egl_wayland.c has no EGL includes).
  libwayland = buildModule.buildForIOS "libwayland" { inherit simulator; };
  waylandScanner = pkgs.wayland-scanner;
  waylandProtocols = pkgs.wayland-protocols;
  angleLinkKind =
    if angle == null then
      "none"
    else if builtins.pathExists "${angle}/nix-support/link-kind" then
      lib.strings.trim (builtins.readFile "${angle}/nix-support/link-kind")
    else
      "static";
  angleStaticFlag = if angleLinkKind == "static" then "-DILAND_ANGLE_STATIC" else "";
  angleIncludes =
    if angle == null then
      ""
    else
      "-I${angle}/include -I${angle}/include/EGL -I${angle}/include/GLES2";
  # buildForVisionOS / buildForTVOS set toolchain flags; do not hardcode
  # iPhoneSimulator or ld rejects the archive (wrong LC_BUILD_VERSION platform).
  isVisionOS = iosToolchain.isVisionOSToolchain or false;
  isTVOS = iosToolchain.isTVOSToolchain or false;
  minVersion =
    iosToolchain.deploymentTarget or (
      if isVisionOS then "26.0" else "17.0"
    );
  sdkPlatform =
    if isVisionOS then
      if simulator then "XRSimulator" else "XROS"
    else if isTVOS then
      if simulator then "AppleTVSimulator" else "AppleTVOS"
    else if simulator then
      "iPhoneSimulator"
    else
      "iPhoneOS";
  minFlag =
    if isVisionOS && simulator then
      "-target arm64-apple-xros${minVersion}-simulator"
    else if isVisionOS then
      "-target arm64-apple-xros${minVersion}"
    else if isTVOS && simulator then
      "-mtvos-simulator-version-min=${minVersion}"
    else if isTVOS then
      "-mtvos-version-min=${minVersion}"
    else if simulator then
      "-mios-simulator-version-min=${minVersion}"
    else
      "-miphoneos-version-min=${minVersion}";
in
pkgs.stdenv.mkDerivation {
  pname = "iland-userland";
  version = ilandVersion;

  src = ./upstream;

  __noChroot = true;
  dontConfigure = true;

  # wayland-scanner is multi-output; take it from PATH.
  nativeBuildInputs = [ waylandScanner ];

  postPatch = ''
    find shims -type f \( -name '*.h' -o -name '*.m' -o -name '*.c' \) \
      -exec sed -i 's|IOSurface/IOSurface.h|IOSurface/IOSurfaceRef.h|g' {} +

    # iOS has no bootstrap.h — stub Mode B Mach IPC helpers (Mode A uses present callback).
    cat > shims/drm/drm/src/drm_ios_ipc_stubs.c <<'EOF'
#include "drm.h"
#include <mach/mach.h>

int drm_send_json(const char *json)
{
    (void)json;
    return -1;
}

int drm_send_json_with_surface(const char *json, mach_port_t surface_port)
{
    (void)json;
    (void)surface_port;
    return -1;
}

int drm_receive_present_ack(unsigned timeout_ms)
{
    (void)timeout_ms;
    return -1;
}
EOF
  '';

  buildPhase = ''
    runHook preBuild

    unset DEVELOPER_DIR
    if [ -z "''${XCODE_APP:-}" ]; then
      XCODE_APP=$(${xcodeUtils.findXcodeScript}/bin/find-xcode || true)
      [ -n "$XCODE_APP" ] && export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
    fi
    export SDKROOT="$DEVELOPER_DIR/Platforms/${sdkPlatform}.platform/Developer/SDKs/${sdkPlatform}.sdk"
    CLANG="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
    AR="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/ar"

    # linux-dmabuf client bindings for the Wayland-EGL winsys.
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
      -I${libwayland}/include/wayland \
      ${angleIncludes}"

    COMMON_FLAGS="-arch arm64 -isysroot $SDKROOT ${minFlag} -fPIC -O2 -std=c11 \
      ${angleStaticFlag} $INCLUDES -framework IOSurface -framework Foundation \
      -framework CoreFoundation -framework CoreGraphics -framework QuartzCore -framework Metal"

    OBJS=""
    CORE_SRCS="
      shims/drm/displaysurface/src/DisplaySurface.c
      shims/gbm/src/gbm.c
      shims/drm/drm/src/drm_linux.c
      shims/drm/drm/src/drm_ioctl.c
      shims/drm/drm/src/drm_ios_ipc_stubs.c
      shims/egl/src/iland_wl_ops.c
    "
    ${lib.optionalString enableGl ''CORE_SRCS="$CORE_SRCS shims/egl/src/egl.c"''}
    for src in $CORE_SRCS; do
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
    #
    # Drive ld -r through clang with the same -isysroot / min-version as the
    # .o compile. Bare `ld -r -arch arm64` defaults to the macOS platform and
    # then rejects iOS Simulator objects ("building for macOS, but linking in
    # object file built for iOS Simulator").
    echo "_zwp_linux_*" > unexported-protocol.txt
    "$CLANG" -r -nostdlib -arch arm64 -isysroot "$SDKROOT" ${minFlag} \
      -o iland_wayland_egl.o $WL_OBJS \
      -Wl,-unexported_symbols_list,unexported-protocol.txt

    "$AR" rcs libiland_wayland_egl.a iland_wayland_egl.o

    VK_WL_CFLAGS="$COMMON_FLAGS -Ishims/vulkan-wayland/include -I${pkgs.vulkan-headers}/include"
    echo "CC shims/vulkan-wayland/src/vk_wayland_wsi.c"
    "$CLANG" -c shims/vulkan-wayland/src/vk_wayland_wsi.c $VK_WL_CFLAGS \
      -o vk_wayland_wsi.o
    "$AR" rcs libiland_wayland_vulkan.a vk_wayland_wsi.o

    runHook postBuild
  '';

  installPhase = ''
    mkdir -p $out/lib/pkgconfig $out/include/EGL $out/include/GLES2 $out/include/GLES3 $out/include/KHR $out/nix-support

    cp libiland_userland.a $out/lib/
    cp libiland_wayland_egl.a $out/lib/
    cp libiland_wayland_vulkan.a $out/lib/

    cp shims/gbm/include/gbm.h                       $out/include/
    ${lib.optionalString enableGl "cp shims/egl/include/egl_shim.h $out/include/"}
    # Wayland-EGL winsys. wl_egl_window_* live in this archive, so clients must
    # NOT also link libwayland-egl (that one is an abort-on-call vendor stub).
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

    cat > $out/lib/pkgconfig/gbm.pc <<EOF
prefix=$out
libdir=\''${prefix}/lib
includedir=\''${prefix}/include

Name: gbm
Description: iland IOSurface-backed GBM ABI
Version: 1.0.0
Libs: -L\''${libdir} -liland_userland
Cflags: -I\''${includedir}
EOF

    ${lib.optionalString enableGl ''
    cp -r ${angle}/include/EGL/.   $out/include/EGL/
    cp -r ${angle}/include/GLES2/. $out/include/GLES2/
    cp -r ${angle}/include/GLES3/. $out/include/GLES3/ || true
    cp -r ${angle}/include/KHR/.   $out/include/KHR/
    echo "${angle}" > $out/nix-support/angle-path
    ''}

    mkdir -p $out/nix-support
    echo "mode-a-userland" > $out/nix-support/iland-mode
    ${lib.optionalString (!enableGl) ''
    echo none > $out/nix-support/angle-path
    echo vulkan-first > $out/nix-support/tvos-gpu-phase
    ''}
  '';

  passthru = {
    inherit angle;
  } // lib.optionalAttrs (angle != null) {
    angleLibs = "${angle}/lib";
  };

  meta = with lib; {
    description = "iland userland in-window Linux-graphics compat (GBM/EGL/DRM over IOSurface+ANGLE) for iOS";
    homepage = "https://github.com/Wawona/iLand";
    license = licenses.mit;
    platforms = platforms.darwin;
  };
}
