# iOS/iPadOS Mode B IOMobileFramebuffer sink.
#
# Rust owns session lifecycle and sink policy. Objective-C is a thin trampoline
# for private IOMFB SPI and Metal objects. This package is device-only and must
# never be merged into App Store products.
{
  lib,
  pkgs,
  simulator ? false,
  iosToolchain,
  ...
}:

assert lib.assertMsg (!simulator) "iland-iomfb is TrollStore/Sileo device-only";

let
  ilandVersion = import ./version.nix;
  cargoTarget = "aarch64-apple-ios";
  rustToolchain = pkgs.rust-bin.stable.latest.default.override {
    targets = [ cargoTarget ];
  };
  rustPlatform = pkgs.makeRustPlatform {
    cargo = rustToolchain;
    rustc = rustToolchain;
  };
in
rustPlatform.buildRustPackage {
  pname = "iLand-iomfb";
  version = ilandVersion;
  src = ../../../crates/iLand-iomfb;
  __noChroot = true;

  cargoLock.lockFile = ../../../crates/iLand-iomfb/Cargo.lock;
  CARGO_BUILD_TARGET = cargoTarget;
  doCheck = false;

  nativeBuildInputs = [ pkgs.clang ];

  preConfigure = ''
    ${iosToolchain.mkIOSBuildEnv { simulator = false; }}
    export NIX_CFLAGS_COMPILE=""
    export NIX_CXXFLAGS_COMPILE=""
    export NIX_LDFLAGS=""
    export IPHONEOS_DEPLOYMENT_TARGET="${iosToolchain.deploymentTarget}"
    export RUSTFLAGS="-C linker=$XCODE_CLANG -C link-arg=-isysroot -C link-arg=$SDKROOT -C link-arg=$APPLE_DEPLOYMENT_FLAG $RUSTFLAGS"
    export CC_aarch64_apple_ios="$XCODE_CLANG"
    export CXX_aarch64_apple_ios="$XCODE_CLANGXX"
    export CARGO_TARGET_AARCH64_APPLE_IOS_LINKER="$XCODE_CLANG"
  '';

  buildPhase = ''
    runHook preBuild
    cargo build --lib --target ${cargoTarget} --release
    "$XCODE_CLANG" -fobjc-arc -O2 -fPIC \
      -isysroot "$SDKROOT" "$APPLE_DEPLOYMENT_FLAG" \
      -Iinclude \
      -x objective-c -c ffi/iomfb_platform.c -o iomfb_platform.o
    "$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/libtool" \
      -static -o libwwn_iland_iomfb.a \
      target/${cargoTarget}/release/libwwn_iland_iomfb.a \
      iomfb_platform.o
    runHook postBuild
  '';

  installPhase = ''
    mkdir -p $out/lib $out/include $out/nix-support
    cp libwwn_iland_iomfb.a $out/lib/
    cp include/wwn_iland_iomfb.h $out/include/
    cp include/IOMobileFramebuffer.h $out/include/
    echo mode-b-ios-iomfb > $out/nix-support/iland-mode
  '';

  meta = with lib; {
    description = "Rust-owned Wawona iOS Mode B IOMobileFramebuffer sink";
    license = licenses.mit;
    platforms = platforms.darwin;
  };
}
