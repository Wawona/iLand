{
  description = "iLand: Wawona userland Linux-graphics compat layer (GBM/EGL/DRM over IOSurface/ANGLE). Formerly wwn-iland.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    rust-overlay.url = "github:oxalica/rust-overlay";
    rust-overlay.inputs.nixpkgs.follows = "nixpkgs";
    wwn-toolchain.url = "https://flakehub.com/f/Wawona/wwn-toolchain/*";
    wwn-toolchain.inputs.nixpkgs.follows = "nixpkgs";
    wwn-toolchain.inputs.rust-overlay.follows = "rust-overlay";
  };

  outputs = { self, nixpkgs, rust-overlay, wwn-toolchain, ... }:
    let
      darwinSystems = [ "x86_64-darwin" "aarch64-darwin" ];
      linuxSystems = [ "x86_64-linux" "aarch64-linux" ];
      allSystems = darwinSystems ++ linuxSystems;
      forAll = nixpkgs.lib.genAttrs allSystems;
      inherit (wwn-toolchain.lib) withPlatformVariants baseRegistry mkToolchains;

      pkgsFor = system: import nixpkgs {
        inherit system;
        overlays = [ (import rust-overlay) ];
        config = { allowUnfree = true; allowUnsupportedSystem = true; android_sdk.accept_license = true; };
      };

      mkAndroidSDK = system: pkgs:
        let
          androidConfig = import "${wwn-toolchain}/dependencies/android/sdk-config.nix" {
            inherit system;
            lib = pkgs.lib;
          };
          androidComposition = pkgs.androidenv.composeAndroidPackages {
            cmdLineToolsVersion = "latest";
            platformToolsVersion = "latest";
            buildToolsVersions = [ androidConfig.buildToolsVersion ];
            platformVersions = [ (toString androidConfig.compileSdk) ];
            abiVersions = [ androidConfig.hostEmulatorAbi ];
            systemImageTypes = [ "google_apis_playstore" ];
            includeEmulator = androidConfig.emulatorSupported;
            includeSystemImages = androidConfig.emulatorSupported;
            includeNDK = true;
            includeCmake = true;
            ndkVersions = [ androidConfig.ndkVersion ];
            cmakeVersions = [ androidConfig.cmakeVersion ];
            useGoogleAPIs = false;
          };
          sdkRoot = "${androidComposition.androidsdk}/libexec/android-sdk";
        in {
          androidsdk = androidComposition.androidsdk;
          inherit sdkRoot;
          platformTools = androidComposition.platform-tools;
          cmdlineTools = androidComposition.androidsdk;
          buildTools = "${sdkRoot}/build-tools/${androidConfig.buildToolsVersion}";
          cmake = "${sdkRoot}/cmake/${androidConfig.cmakeVersion}";
          ndk = "${sdkRoot}/ndk/${androidConfig.ndkVersion}";
          emulator =
            if androidConfig.emulatorSupported then
              androidComposition.emulator
            else
              androidComposition.androidsdk;
          systemImage =
            "${sdkRoot}/system-images/android-${toString androidConfig.compileSdk}/google_apis_playstore/${androidConfig.hostEmulatorAbi}";
          androidSdkPackages = { };
          inherit androidConfig;
        };
    in
    {
      # Registry fragment merged by Wawona / standalone builds over baseRegistry.
      registryFragment = {
        # L1 graphics implementations. Consumers cannot select these drivers
        # without merging iland's registry fragment.
        angle = withPlatformVariants {
          android = ./dependencies/libs/angle/android.nix;
          ios = ./dependencies/libs/angle/ios.nix;
          ipados = ./dependencies/libs/angle/ios.nix;
          # Source GN (same ios.nix as visionOS). Chromium already has
          # target_platform=tvos. Cited: Wawona/docs/wwn-repo-dag.md.
          tvos = ./dependencies/libs/angle/ios.nix;
          visionos = ./dependencies/libs/angle/ios.nix;
          watchos = null;
          macos = ./dependencies/libs/angle/macos.nix;
        };
        swiftshader = withPlatformVariants {
          android = ./dependencies/libs/swiftshader/android.nix;
          wearos = ./dependencies/libs/swiftshader/wearos.nix;
          ios = ./dependencies/libs/swiftshader/ios.nix;
          ipados = ./dependencies/libs/swiftshader/ios.nix;
          visionos = ./dependencies/libs/swiftshader/ios.nix;
          macos = ./dependencies/libs/swiftshader/macos.nix;
        };
        moltenvk = withPlatformVariants {
          ios = ./dependencies/libs/moltenvk/apple-mobile.nix;
          ipados = ./dependencies/libs/moltenvk/apple-mobile.nix;
          visionos = ./dependencies/libs/moltenvk/apple-mobile.nix;
          macos = ./dependencies/libs/moltenvk/macos.nix;
          tvos = ./dependencies/libs/moltenvk/apple-mobile.nix;
          watchos = null;
          android = null;
        };
        # KosmicKrisp is an L1 key. Unsupported variants fail instead of
        # silently substituting MoltenVK.
        kosmickrisp = withPlatformVariants {
          macos = ./dependencies/libs/kosmickrisp/macos.nix;
          ios = null;
          ipados = null;
          visionos = null;
          tvos = null;
          watchos = null;
          android = null;
        };
        iland = withPlatformVariants {
          android = ./dependencies/libs/iland/android.nix;
          ios = ./dependencies/libs/iland/ios.nix;
          ipados = ./dependencies/libs/iland/ios.nix;
          tvos = ./dependencies/libs/iland/tvos.nix;
          visionos = ./dependencies/libs/iland/visionos.nix;
          watchos = ./dependencies/libs/iland/watchos.nix;
          macos = ./dependencies/libs/iland/macos.nix;
        };
        # Mode B dylib — macOS only (no mobile/Android variants).
        iland-baremetal = withPlatformVariants {
          macos = ./dependencies/libs/iland/macos-baremetal.nix;
        };
        # L1 iOS own-display sink. Cited: Wawona/docs/wwn-repo-dag.md.
        # Mode B device products opt in explicitly; no store/mobile default.
        iland-iomfb = withPlatformVariants {
          ios = ./dependencies/libs/iland/iomfb.nix;
          ipados = ./dependencies/libs/iland/iomfb.nix;
        };
      };

      packages = forAll (system:
        let
          pkgs = pkgsFor system;
          androidSDK = mkAndroidSDK system pkgs;
          androidAllowExperimentalFallback =
            (builtins.getEnv "WAWONA_ANDROID_EXPERIMENTAL_FALLBACK") == "1"
            || builtins.elem system [ "aarch64-darwin" "aarch64-linux" ];
          tc = mkToolchains {
            inherit pkgs androidSDK androidAllowExperimentalFallback;
            pkgsAndroid = pkgs.pkgsCross.aarch64-android;
            registry = baseRegistry // self.registryFragment;
          };
          isDarwin = builtins.elem system darwinSystems;
        in
        ((if isDarwin then {
          iland-ios = tc.buildForIOS "iland" { };
          iland-ios-sim = tc.buildForIOS "iland" { simulator = true; };
          iland-ipados = tc.buildForIPadOS "iland" { };
          iland-tvos = tc.buildForTVOS "iland" { };
          iland-tvos-sim = tc.buildForTVOS "iland" { simulator = true; };
          iland-watchos = tc.buildForWatchOS "iland" { };
          iland-visionos = tc.buildForVisionOS "iland" { };
          iland-visionos-sim = tc.buildForVisionOS "iland" { simulator = true; };
          iland-macos = tc.buildForMacOS "iland" { };
          iland-baremetal-macos = tc.buildForMacOS "iland-baremetal" { };
          iland-iomfb-ios = tc.buildForIOS "iland-iomfb" { };
          angle-ios = tc.buildForIOS "angle" { };
          angle-ios-sim = tc.buildForIOS "angle" { simulator = true; };
          angle-visionos = tc.buildForVisionOS "angle" { };
          angle-visionos-sim = tc.buildForVisionOS "angle" { simulator = true; };
          angle-tvos = tc.buildForTVOS "angle" { };
          angle-tvos-sim = tc.buildForTVOS "angle" { simulator = true; };
          moltenvk-ios = tc.buildForIOS "moltenvk" { };
          moltenvk-ios-sim = tc.buildForIOS "moltenvk" { simulator = true; };
          moltenvk-visionos = tc.buildForVisionOS "moltenvk" { };
          moltenvk-visionos-sim = tc.buildForVisionOS "moltenvk" { simulator = true; };
          moltenvk-tvos = tc.buildForTVOS "moltenvk" { };
          moltenvk-tvos-sim = tc.buildForTVOS "moltenvk" { simulator = true; };
          moltenvk-macos = tc.buildForMacOS "moltenvk" { };
          kosmickrisp-macos = tc.buildForMacOS "kosmickrisp" { };
          swiftshader-macos = tc.buildForMacOS "swiftshader" { };
          swiftshader-ios = tc.buildForIOS "swiftshader" { };
          swiftshader-ios-sim = tc.buildForIOS "swiftshader" { simulator = true; };
          swiftshader-visionos-sim = tc.buildForVisionOS "swiftshader" { simulator = true; };
        } else { }) // {
          iland-android = tc.buildForAndroid "iland" { };
          swiftshader-android = tc.buildForAndroid "swiftshader" { };
        })
      );

      formatter = forAll (system: (pkgsFor system).nixfmt-rfc-style);
    };
}
