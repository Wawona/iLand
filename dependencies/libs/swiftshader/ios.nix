{
  lib,
  pkgs,
  stdenv,
  xcodeUtils,
  iosToolchain,
  simulator ? true,
  # The existing release contains only the Vulkan frontend, without its
  # static dependency closure. Reprove the source link before pinning a new
  # complete, namespaced release and restoring the prebuilt default.
  usePrebuilt ? false,
  ...
}@args:

# SwiftShader CPU Vulkan ICD for iOS/iPadOS devices and Simulator. It is the
# last-resort link in the Vulkan fallback chain after MoltenVK, and is bundled
# with every Wawona iOS deployment from the product floor through the newest SDK.
#
# The source recipe is deliberately retained for a controlled proof rebuild,
# but it compiles SwiftShader's vendored LLVM and is not the developer default.
let
  sourceBuild = import ./macos.nix (
  (removeAttrs args [ "simulator" ])
  // {
    appleSdk = if simulator then "iphonesimulator" else "iphoneos";
    buildShared = false;
    minVersionFlag =
      if simulator then
        "-mios-simulator-version-min=${iosToolchain.deploymentTarget}"
      else
        "-miphoneos-version-min=${iosToolchain.deploymentTarget}";
    extraCmakeFlags = [
      "-DCMAKE_SYSTEM_NAME=iOS"
      "-DCMAKE_OSX_ARCHITECTURES=arm64"
      "-DCMAKE_OSX_DEPLOYMENT_TARGET=${iosToolchain.deploymentTarget}"
    ];
  }
  );

  prebuilt = pkgs.fetchurl {
    url = "https://github.com/Wawona/iLand/releases/download/swiftshader-ios-static-436722b/${
      if simulator then
        "swiftshader-ios-simulator-arm64-static-436722b.tar"
      else
        "swiftshader-ios-arm64-static-436722b.tar"
    }";
    hash = if simulator then
      "sha256-ViloOOXqSYX4P+s5zJk8PFaOyOio07RBaqAimYxOGdw="
    else
      "sha256-Kx+KQotYsjn2OpT2q4Vu4aybYU7z1Lxf7YHxb8eWAuU=";
  };
in
if !usePrebuilt then sourceBuild else pkgs.stdenv.mkDerivation {
  pname = "swiftshader-${if simulator then "ios-sim" else "ios"}-static";
  version = "436722b";
  src = prebuilt;
  nativeBuildInputs = [ pkgs.llvmPackages_21.bintools ];
  dontConfigure = true;
  dontBuild = true;

  unpackPhase = ''
    mkdir extracted
    tar -xf "$src" -C extracted
  '';

  installPhase = ''
    test -f extracted/lib/libvk_swiftshader.a
    llvm-nm --defined-only -g extracted/lib/libvk_swiftshader.a > symbols.txt
    if ! grep -E ' T _wwn_swiftshader_vkGetInstanceProcAddr$' symbols.txt; then
      echo "SwiftShader release lacks the verified namespaced static provider; rebuild from source" >&2
      exit 1
    fi
    if find extracted -type f \( -name '*.dylib' -o -name '*icd*.json' \) -print | grep -q .; then
      echo "SwiftShader iOS release archive contains a forbidden dynamic runtime artifact" >&2
      exit 1
    fi
    mkdir -p "$out"
    cp -R extracted/lib "$out/lib"
  '';

  meta = with lib; {
    description = "Prebuilt static SwiftShader Vulkan archive for ${if simulator then "the iOS Simulator" else "iOS"}";
    homepage = "https://github.com/Wawona/iLand/releases/tag/swiftshader-ios-static-436722b";
    license = licenses.asl20;
    platforms = platforms.darwin;
  };
}
