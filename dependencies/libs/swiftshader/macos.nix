{
  lib,
  pkgs,
  stdenv,
  buildModule ? null,
  # Injected by wwn-toolchain (the Apple toolchain wrapper).
  xcodeUtils,
  # iOS variants reuse this recipe with a different SDK/sysroot (see ios.nix).
  # macOS is the default.
  appleSdk ? "macosx",
  # Apple mobile links SwiftShader directly into the app. macOS retains an
  # app-owned dynamic ICD for runtime selection.
  buildShared ? true,
  minVersionFlag ? "-mmacosx-version-min=12.0",
  # Extra -D flags the simulator variant needs (CMAKE_SYSTEM_NAME=iOS,
  # CMAKE_OSX_ARCHITECTURES, CMAKE_OSX_DEPLOYMENT_TARGET, …).
  extraCmakeFlags ? [ ],
  ...
}:

# SwiftShader software Vulkan 1.3 ICD for Apple targets. nixpkgs' swiftshader is
# Linux-only (meta.platforms is all *-linux), so we build the upstream CMake
# project ourselves against the macOS / iOS SDK. This is the
# last-resort ICD in Wawona's Vulkan fallback chain (selected -> MoltenVK ->
# SwiftShader): a pure-CPU device that always enumerates, so vkcube and other
# Vulkan clients run even on a headless CI VM / Simulator with no usable
# Metal-backed Vulkan device. It stays userland (no kernel graphics node) per
# the mission's runtime-only rule.
#
let
  src = pkgs.fetchFromGitHub {
    owner = "google";
    repo = "swiftshader";
    rev = "436722b391188ad8c1d1d5dd2447c38ac7f71439";
    hash = "sha256-bIWrl2ZGBfmmQxCNvwyLWQAezgMKY6QKwxp7StfdgqQ=";
  };
  glslangSrc = pkgs.fetchFromGitHub {
    owner = "KhronosGroup";
    repo = "glslang";
    rev = "2b2523fb951f63f072cfba514c26f2feea5f4329";
    hash = "sha256-47vN1gTxRa3MU9avmxVJ/E7MeR9cnjJiheCFBPdci1U=";
  };
  googletestSrc = pkgs.fetchFromGitHub {
    owner = "google";
    repo = "googletest";
    rev = "e2239ee6043f73722e7aa812a459f54a28552929";
    hash = "sha256-SjlJxushfry13RGA7BCjYC9oZqV4z6x8dOiHfl/wpF0=";
  };
  isIOS = appleSdk == "iphoneos" || appleSdk == "iphonesimulator";
  isSimulator = appleSdk == "iphonesimulator";
in
pkgs.stdenv.mkDerivation {
  pname = "swiftshader-${if appleSdk == "iphoneos" then "ios" else if isSimulator then "ios-sim" else "macos"}${lib.optionalString (!buildShared) "-static"}";
  version = "436722b";
  inherit src;

  # Needs the Apple SDK (frameworks + xcrun) at build time.
  __noChroot = true;

  nativeBuildInputs = with pkgs.buildPackages; [
    cmake
    ninja
    pkg-config
    python3
    git
    cacert
    perl
  ];

  postPatch = ''
    rm -rf third_party/glslang third_party/googletest
    cp -r ${glslangSrc} third_party/glslang
    cp -r ${googletestSrc} third_party/googletest
    chmod -R u+w third_party/glslang third_party/googletest

    # cmake >= 4 (nixpkgs macOS) hard-errors on
    # cmake_minimum_required(VERSION < 3.5). The vendored third_party trees
    # (googletest/googlemock, glslang, marl, SPIRV-*, …) still pin ancient
    # minimums in nested CMakeLists, so bump every one to 3.5. Lowering a floor
    # is harmless and CMAKE_POLICY_VERSION_MINIMUM=3.5 keeps policy consistent.
    find third_party -name CMakeLists.txt -print0 2>/dev/null \
      | while IFS= read -r -d "" f; do
      sed -i.bak -E \
        's/cmake_minimum_required\(VERSION [0-9]+(\.[0-9]+)*/cmake_minimum_required(VERSION 3.5/' \
        "$f" || true
    done
    # Upstream LLVM_LIST pulls AArch64Disassembler but omits the MC base
    # units it needs. Without these, the static merge has no
    # llvm::MCDisassembler / MCExternalSymbolizer and iOS-sim Ld fails.
    python3 - <<'PY_LLVM_MC'
from pathlib import Path
p = Path("third_party/llvm-10.0/CMakeLists.txt")
t = p.read_text()
# Split so Nix does not interpolate LLVM_DIR inside this postPatch.
llvm = "''${" + "LLVM_DIR}"
needle = f"{llvm}/lib/MC/MCDisassembler/MCRelocationInfo.cpp"
insert = needle + f"""
    {llvm}/lib/MC/MCDisassembler/MCDisassembler.cpp
    {llvm}/lib/MC/MCDisassembler/MCExternalSymbolizer.cpp
    {llvm}/lib/MC/MCDisassembler/MCSymbolizer.cpp"""
if needle not in t:
    raise SystemExit("MCRelocationInfo.cpp anchor missing from LLVM_LIST")
if "MCDisassembler/MCDisassembler.cpp" not in t:
    t = t.replace(needle, insert, 1)
    p.write_text(t)
PY_LLVM_MC
${lib.optionalString (!buildShared) ''
    # SwiftShader declares its Vulkan ICD explicitly SHARED, so the generic
    # BUILD_SHARED_LIBS switch cannot make an Apple-mobile archive. Mobile
    # Wawona links this provider in-process; do not emit a dylib or ICD.
    substituteInPlace src/Vulkan/CMakeLists.txt \
      --replace-fail 'add_library(vk_swiftshader SHARED' 'add_library(vk_swiftshader STATIC'
    # Keep this in-process provider distinct from MoltenVK's Vulkan ABI.
    # Proc-address lookup strings remain upstream names; only C symbols change.
    python3 - <<'PY_NAMESPACE'
from pathlib import Path
import re
names = set()
for source in Path("src").rglob("*"):
    if source.suffix in {".cpp", ".hpp", ".h", ".mm"}:
        names.update(re.findall(r"\b(vk[A-Z]\w*|vk_icd\w*)\s*\(", source.read_text()))
assert "vkGetInstanceProcAddr" in names
Path("wawona-static-vulkan-namespace.h").write_text(
    "#pragma once\n" + "".join(
        f"#define {name} wwn_swiftshader_{name}\n" for name in sorted(names)))
PY_NAMESPACE
''}
${lib.optionalString isIOS ''
    # The iOS-Simulator SDK has no Cocoa or Quartz (macOS umbrella) frameworks, so
    # SwiftShader's APPLE branch find_library(Cocoa/Quartz) resolves to NOTFOUND
    # and the generate step aborts. They are only used for SwiftShader's macOS
    # window/test harness — the headless CPU Vulkan ICD does not need them — while
    # CoreFoundation, IOSurface, and Metal do exist on iOS. Drop the two
    # macOS-only frameworks from OS_LIBS for the simulator build.
    sed -i.bak \
      -e '/find_library(COCOA_FRAMEWORK Cocoa)/d' \
      -e '/find_library(QUARTZ_FRAMEWORK Quartz)/d' \
      -e 's|set(OS_LIBS "''${COCOA_FRAMEWORK}" "''${QUARTZ_FRAMEWORK}" "''${CORE_FOUNDATION_FRAMEWORK}" "''${IOSURFACE_FRAMEWORK}" "''${METAL_FRAMEWORK}")|set(OS_LIBS "''${CORE_FOUNDATION_FRAMEWORK}" "''${IOSURFACE_FRAMEWORK}" "''${METAL_FRAMEWORK}" "-framework Foundation" "-framework QuartzCore" "-framework UIKit")|' \
      CMakeLists.txt

    # MetalSurface.mm includes <AppKit/NSView.h>, which does not exist on iOS
    # (AppKit is macOS-only). Only the MacOSSurfaceMVK path uses NSView; the
    # VK_EXT_metal_surface path drives CAMetalLayer directly, which is available
    # on iOS. Map NSView -> UIView for the simulator so the file compiles and the
    # Metal-EXT surface still works; SwiftShader remains a headless CPU ICD that
    # Wawona presents through iland regardless.
    perl -0777 -pi -e 's{\#include <AppKit/NSView.h>}{#include <TargetConditionals.h>\n#if TARGET_OS_IPHONE\n#import <UIKit/UIKit.h>\n#define NSView UIView\n#else\n#include <AppKit/NSView.h>\n#endif}' \
      src/WSI/MetalSurface.mm
  ''}'';

  configurePhase = ''
    runHook preConfigure

    export DEVELOPER_DIR="$(${xcodeUtils.findXcodeScript}/bin/find-xcode)/Contents/Developer"
    SDKROOT=$(xcrun --sdk ${appleSdk} --show-sdk-path 2>/dev/null || true)
    if [ ! -d "$SDKROOT" ]; then
      SDKROOT=$(${xcodeUtils.findXcodeScript}/bin/find-xcode)/Contents/Developer/Platforms/${
        if appleSdk == "iphonesimulator" then "iPhoneSimulator" else if appleSdk == "iphoneos" then "iPhoneOS" else "MacOSX"
      }.platform/Developer/SDKs/${
        if appleSdk == "iphonesimulator" then "iPhoneSimulator" else if appleSdk == "iphoneos" then "iPhoneOS" else "MacOSX"
      }.sdk
    fi
    test -d "$SDKROOT" || { echo "ERROR: ${appleSdk} SDK not found" >&2; exit 1; }
    export SDKROOT

    CC_LAUNCH="$(command -v clang)"
    CXX_LAUNCH="$(command -v clang++)"
${lib.optionalString isIOS ''
    # The nixpkgs macOS stdenv clang *wrapper* re-injects -mmacos-version-min
    # internally (not on the visible argv), which clang refuses alongside
    # -mios-simulator-version-min — and there is no runtime env knob to unbake it.
    # For this iOS-Simulator cross build, bypass the wrapper and drive the
    # unwrapped clang directly: we already pass -isysroot (the iPhoneSimulator SDK
    # has libc++ + system headers), -arch arm64, and the correct min-version flag,
    # which is everything a self-contained SwiftShader (CPU-only, no Apple
    # frameworks) build needs. This is the standard way to CMake-cross to iOS from
    # a macOS-host nix stdenv.
    CC_LAUNCH="${pkgs.stdenv.cc.cc}/bin/clang"
    CXX_LAUNCH="${pkgs.stdenv.cc.cc}/bin/clang++"
    test -x "$CC_LAUNCH" || CC_LAUNCH="${pkgs.stdenv.cc.cc}/bin/clang"
    # The unwrapped clang still drives the nix ld-wrapper, which rejects linking
    # against the impure Xcode iPhoneSimulator SDK (`impure path ... used in
    # link`). This build is already __noChroot and deliberately consumes the
    # host Xcode SDK, so relax purity enforcement for the link step.
    export NIX_ENFORCE_PURITY=0
    # NIX_LDFLAGS injects nix's *macOS* libc++ (-L .../libcxx.../lib), which ld
    # refuses to link into an iOS-Simulator binary ("linking in .tbd built for
    # macOS"). Clear the nix-injected compile/link flags entirely: -isysroot to
    # the iPhoneSimulator SDK already supplies libc++, libSystem, and the crt for
    # the correct platform.
    export NIX_LDFLAGS=""
    export NIX_LDFLAGS_BEFORE=""
    export NIX_CFLAGS_COMPILE=""
    export NIX_CFLAGS_LINK=""
''}
    EXTRA_CMAKE_FLAGS="${lib.concatStringsSep " " extraCmakeFlags}"
    # SwiftShader's Reactor JIT vendors LLVM 10, whose llvm-c/DataTypes.h errors
    # unless the C99 limit/constant/format macros are defined before <cstdint>
    # on a modern libc++ (Apple clang). Define them project-wide.
    STDC_MACRO_FLAGS="-D__STDC_LIMIT_MACROS -D__STDC_CONSTANT_MACROS -D__STDC_FORMAT_MACROS"
${lib.optionalString (!buildShared) ''
    STDC_MACRO_FLAGS="$STDC_MACRO_FLAGS -include $PWD/wawona-static-vulkan-namespace.h"
''}
    cmake -S . -B build -GNinja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER="$CC_LAUNCH" \
      -DCMAKE_CXX_COMPILER="$CXX_LAUNCH" \
      -DCMAKE_OSX_SYSROOT="$SDKROOT" \
      $EXTRA_CMAKE_FLAGS \
      -DSWIFTSHADER_BUILD_TESTS=OFF \
      -DSWIFTSHADER_BUILD_PVR=OFF \
      -DSWIFTSHADER_BUILD_BENCHMARKS=OFF \
      -DSWIFTSHADER_WARNINGS_AS_ERRORS=OFF \
      -DBUILD_SHARED_LIBS=${if buildShared then "ON" else "OFF"} \
      -DCMAKE_C_FLAGS="${minVersionFlag} $STDC_MACRO_FLAGS" \
      -DCMAKE_CXX_FLAGS="${minVersionFlag} $STDC_MACRO_FLAGS" \
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    cmake --build build --target vk_swiftshader --parallel "$NIX_BUILD_CORES"
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/lib"

    icd=$(find build -type f -name '${if buildShared then "libvk_swiftshader.dylib" else "libvk_swiftshader.a"}' -print -quit)
    test -n "$icd" || {
      echo "SwiftShader ${appleSdk} ${if buildShared then "Vulkan ICD (libvk_swiftshader.dylib)" else "static Vulkan archive (libvk_swiftshader.a)"} was not produced" >&2
      find build -name 'libvk_swiftshader*' -o -name '*.dylib' -o -name '*.a' | head -50 >&2
      exit 1
    }
${if buildShared then ''
    install -m755 "$icd" "$out/lib/libvk_swiftshader.dylib"
'' else ''
    # A STATIC target does not absorb its transitive static libraries. Merge
    # the ICD archive plus its build/ dependency archives. Prefer third_party
    # LLVM under build/ (including Darwin/iOS MC). Skip build/bin (API copies).
    # Always put "$icd" first: excluding every libvk_swiftshader.a by name
    # dropped the namespaced Vulkan objects and failed the ABI grep.
    # libtool -static concatenates members. Dependency archives often repeat
    # the same .o basenames as the ICD; force_load then fails with hundreds of
    # duplicate symbols. Deduplicate by basename (first archive wins).
    archives=("$icd")
    while IFS= read -r archive; do
      [ "$archive" = "$icd" ] && continue
      case "$(basename "$archive")" in
        libvk_swiftshader.a) continue ;;
      esac
      archives+=("$archive")
    done < <(
      find build -type f -name '*.a' \
        ! -path 'build/bin/*' \
        -print | LC_ALL=C sort
    )
    test "''${#archives[@]}" -gt 1
    merge_dir="$TMPDIR/swiftshader-merge-objs"
    rm -rf "$merge_dir"
    mkdir -p "$merge_dir"
    idx=0
    for archive in "''${archives[@]}"; do
      ext="$TMPDIR/ss-ar-ext-$idx"
      rm -rf "$ext"
      mkdir -p "$ext"
      (cd "$ext" && xcrun --sdk ${appleSdk} ar x "$archive")
      for obj in "$ext"/*; do
        [ -f "$obj" ] || continue
        base=$(basename "$obj")
        case "$base" in
          *.o) ;;
          *) continue ;;
        esac
        # Keep the largest object for a basename. Smaller first copies are often
        # stubs; first-wins then leaves undefined LLVM / Reactor symbols at Ld.
        if [ ! -e "$merge_dir/$base" ]; then
          mv "$obj" "$merge_dir/$base"
        elif [ "$(stat -f%z "$obj" 2>/dev/null || stat -c%s "$obj")" -gt \
               "$(stat -f%z "$merge_dir/$base" 2>/dev/null || stat -c%s "$merge_dir/$base")" ]; then
          mv "$obj" "$merge_dir/$base"
        fi
      done
      idx=$((idx + 1))
    done
    obj_count=$(find "$merge_dir" -name '*.o' | wc -l | tr -d ' ')
    test "$obj_count" -gt 1
    xcrun --sdk ${appleSdk} libtool -static -o "$out/lib/libvk_swiftshader.a" "$merge_dir"/*.o
    if ar t "$out/lib/libvk_swiftshader.a" | sort | uniq -d | grep .; then
      echo "SwiftShader static archive still has duplicate member basenames" >&2
      exit 1
    fi
    # Prove the public ABI is namespaced, rather than accepting a duplicate
    # definition beside MoltenVK. Full app linking proves dependency closure.
    xcrun --sdk ${appleSdk} nm -gU "$out/lib/libvk_swiftshader.a" > "$TMPDIR/swiftshader-symbols.txt"
    if ! grep -E ' T _wwn_swiftshader_vkGetInstanceProcAddr$' "$TMPDIR/swiftshader-symbols.txt"; then
      echo "SwiftShader static archive missing namespaced vkGetInstanceProcAddr" >&2
      grep -E 'vkGetInstanceProcAddr' "$TMPDIR/swiftshader-symbols.txt" | head -20 >&2 || true
      exit 1
    fi
    if grep -E ' T _vk(GetInstanceProcAddr|CreateInstance)$' "$TMPDIR/swiftshader-symbols.txt"; then
      echo "SwiftShader static archive leaks the shared Vulkan ABI" >&2
      exit 1
    fi
    # Fail closed if LLVM MC base stayed out of the merge (app Ld then dies).
    # Do not use nm -u on the archive: member .o files still list U refs to
    # symbols defined in other members; that is normal until final Ld. Require
    # the MC typeinfo/dtor to be present as defined text/data instead.
    if ! grep -E ' [TDS] __ZTIN4llvm14MCDisassemblerE$' "$TMPDIR/swiftshader-symbols.txt" \
      && ! grep -E ' [TDS] __ZN4llvm14MCDisassemblerD2Ev$' "$TMPDIR/swiftshader-symbols.txt"; then
      echo "SwiftShader static archive missing defined llvm::MCDisassembler" >&2
      grep -E 'MCDisassembler' "$TMPDIR/swiftshader-symbols.txt" | head -20 >&2 || true
      exit 1
    fi
''}

${lib.optionalString buildShared ''
    mkdir -p "$out/lib/vulkan/icd.d"
    manifest=$(find build -type f -name 'vk_swiftshader_icd.json' -print -quit)
    if [ -n "$manifest" ]; then
      install -m644 "$manifest" "$out/lib/vulkan/icd.d/vk_swiftshader_icd.json"
    fi
    # Rewrite (or create) the ICD manifest so library_path is bundle-relative;
    # the loader resolves it relative to the manifest's directory.
    cat > "$out/lib/vulkan/icd.d/vk_swiftshader_icd.json" <<'EOF'
{
  "file_format_version": "1.0.0",
  "ICD": {
    "library_path": "../../libvk_swiftshader.dylib",
    "api_version": "1.3.0"
  }
}
EOF
''}
    runHook postInstall
  '';

  meta = with lib; {
    description = "SwiftShader software Vulkan ICD for ${if appleSdk == "iphoneos" then "iOS" else if isSimulator then "the iOS Simulator" else "macOS"}";
    homepage = "https://swiftshader.googlesource.com/SwiftShader";
    license = licenses.asl20;
    platforms = platforms.darwin;
  };
}
