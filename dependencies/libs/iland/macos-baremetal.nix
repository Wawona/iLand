# iland Mode B: macOS-only WindowServer/SkyLight replacement dylib.
#
# Builds upstream libwayland-mac.dylib (Dobby hooks + embedded amfiexceptiond /
# framebufferd / inputd). NOT App-Store-safe: requires SIP fully disabled
# (`csrutil disable` in Recovery). Classic engage spawns helpers as root.
# Login-user niri/weston insert the same dylib for iland DRM hooks only.
#
# Consumed only by Wawona desktop-host / full-dev macOS packaging. Never built
# for iOS/iPadOS/tvOS/watchOS/visionOS/Android.
{
  lib,
  pkgs,
  stdenv,
  buildModule,
  xcodeUtils,
  ...
}:

let
  ilandVersion = import ./version.nix;
  angle = buildModule.buildForMacOS "angle" { };

  # Pinned Dobby (upstream CMake FetchContent target). Keep in sync with
  # CoreBedtime/iland's CMakeLists FetchContent_Declare(dobby …).
  dobbySrc = pkgs.fetchFromGitHub {
    owner = "jmpews";
    repo = "Dobby";
    rev = "5dfc8546954ce3b3198132ab13fddb89ee92cdd7";
    sha256 = "0531k6r7knn30xb32rbri55d1k0rv1zjfqlcji66ms2m0ilj2g4x";
  };
in
pkgs.stdenv.mkDerivation {
  pname = "iland-baremetal";
  version = ilandVersion;

  src = ./upstream;

  # Needs the macOS SDK + codesign for ad-hoc helper signing.
  __noChroot = true;

  nativeBuildInputs = [
    pkgs.cmake
    pkgs.ninja
    pkgs.git
  ];

  postPatch = ''
    # Skip upstream test/kmscube targets (MacPorts ANGLE paths; not needed for
    # the product dylib).
    substituteInPlace CMakeLists.txt \
      --replace 'add_subdirectory(test)' '# add_subdirectory(test) # iLand: skipped'

    # De-MacPorts: EGL shim still embeds /opt/local candidates for the Mode B
    # fallback GLES load path.
    substituteInPlace shims/egl/src/egl.c \
      --replace "/opt/local/lib/libEGL.dylib"    "${angle}/lib/libEGL.dylib" \
      --replace "/opt/local/lib/libGLESv2.dylib" "${angle}/lib/libGLESv2.dylib"
    substituteInPlace shims/egl/CMakeLists.txt \
      --replace '/opt/local/include' '${angle}/include'

    # Mode B presents via Mach/framebufferd, not wl_egl_window. Skip the
    # Wayland-EGL winsys (needs shims/wayland-egl/include). GBM zerocopy still
    # compiles: depth-blit helpers in egl.c are no longer gated on WL_WINSYS.
    substituteInPlace shims/egl/CMakeLists.txt \
      --replace 'add_library(egl-shim STATIC src/egl.c)' \
                'add_library(egl-shim STATIC src/egl.c)
target_compile_definitions(egl-shim PRIVATE ILAND_NO_WL_WINSYS=1)'

    # inputd CMake hardcodes /opt/local/include — drop it (IOKit headers are in SDK).
    substituteInPlace shims/libinput/input-daemon/CMakeLists.txt \
      --replace '/opt/local/include' '${angle}/include'
  '';

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild

    # CMake links the injected dylib and its embedded root helpers.  It must use
    # one Xcode compiler + SDK pair; the Nix clang wrapper injects its own
    # apple-sdk DEVELOPER_DIR and conflicts with a host SDK at link time.
    XCODE_APP=$(${xcodeUtils.findXcodeScript}/bin/find-xcode)
    export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
    # CMake's helper targets invoke `codesign` by name. Nix's build PATH omits
    # host /usr/bin, but prepending it would shadow GNU find/cut used by
    # fixupPhase. Provide only the required host binary through a tiny wrapper.
    mkdir -p .mode-b-tools
    cat > .mode-b-tools/codesign <<'EOF'
    #!/bin/sh
    exec /usr/bin/codesign "$@"
    EOF
    chmod +x .mode-b-tools/codesign
    export PATH="$PWD/.mode-b-tools:$PATH"
    MACOS_SDK="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
    if [ ! -d "$MACOS_SDK" ]; then
      echo "ERROR: MacOSX SDK not found." >&2
      exit 1
    fi
    export SDKROOT="$MACOS_SDK"
    CLANG="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
    CLANGXX="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang++"

    cmake -G Ninja -B build -S . \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER="$CLANG" \
      -DCMAKE_CXX_COMPILER="$CLANGXX" \
      -DCMAKE_OBJC_COMPILER="$CLANG" \
      -DCMAKE_OSX_SYSROOT="$SDKROOT" \
      -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 \
      -DFETCHCONTENT_SOURCE_DIR_DOBBY="${dobbySrc}" \
      -DFETCHCONTENT_FULLY_DISCONNECTED=ON \
      -DDobby_BUILD_TOOLS=OFF \
      -DDobby_BUILD_TESTS=OFF

    cmake --build build --parallel ''${NIX_BUILD_CORES:-4}

    runHook postBuild
  '';

  installPhase = ''
    mkdir -p $out/lib $out/nix-support
    cp -L build/libwayland-mac.dylib $out/lib/libwayland-mac.dylib
    chmod 755 $out/lib/libwayland-mac.dylib

    # Convenience alias used by Wawona bundle layout docs.
    ln -sf libwayland-mac.dylib $out/lib/libwwn-iland.dylib

    echo "mode-b-baremetal" > $out/nix-support/iland-mode
    echo "${angle}" > $out/nix-support/angle-path

    cat > $out/nix-support/README.txt <<'EOF'
    iland Mode B dylib (libwayland-mac.dylib).
    Load via DYLD_INSERT_LIBRARIES into a root-launched weston --backend=drm
    process when SIP is fully disabled (csrutil disable) and Desktop Replacement
    is enabled. Never ship in App Store / store-safe builds.
    EOF
  '';

  passthru = {
    inherit angle dobbySrc;
    dylibName = "libwayland-mac.dylib";
  };

  meta = with lib; {
    description = "iland Mode B WindowServer-replacement dylib (Dobby + framebufferd) for macOS";
    homepage = "https://github.com/Wawona/iLand";
    license = licenses.mit;
    platforms = platforms.darwin;
    # Intentionally not hydra-safe / store-safe.
    broken = false;
  };
}
