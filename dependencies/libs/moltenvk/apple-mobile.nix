# MoltenVK for Apple mobile, built from pinned source with the public Metal API.
#
# Upstream's source archive deliberately omits `External/` and its helper script
# clones those trees at build time.  Keep the derivation hermetic: the exact
# revision of each needed helper source is a Nix input, then Xcode compiles the
# static libraries for the selected latest-SDK slice.
{
  lib,
  pkgs,
  simulator ? false,
  iosToolchain,
  ...
}:

let
  isVisionOS = iosToolchain.isVisionOSToolchain or false;
  isTVOS = iosToolchain.isTVOSToolchain or false;
  platformName =
    if isTVOS then "tvos" else if isVisionOS then "visionos" else "ios";
  sdkPlatform =
    if isVisionOS then
      if simulator then "XRSimulator" else "XROS"
    else if isTVOS then
      if simulator then "AppleTVSimulator" else "AppleTVOS"
    else if simulator then
      "iPhoneSimulator"
    else
      "iPhoneOS";
  xcodePlatform =
    if isVisionOS then
      if simulator then "xrOS Simulator" else "xrOS"
    else if isTVOS then
      if simulator then "tvOS Simulator" else "tvOS"
    else if simulator then
      "iOS Simulator"
    else
      "iOS";
  xcodeOS = if isVisionOS then "xrOS" else if isTVOS then "tvOS" else "iOS";
  upstreamPackageOS = if isVisionOS then "visionOS" else if isTVOS then "tvOS" else "iOS";
  staticScheme = "Wawona MoltenVK ${xcodeOS} static";
  # Packaging schemes point at the dynamic product. Retarget each scheme at
  # that platform's static target. The iOS id is not present in the tvOS or
  # visionOS scheme.
  packageTargetId =
    if isTVOS then "2FEA0A2F24902F5E00EEF3AD"
    else if isVisionOS then "DCFD7ED52A45BC56007BBBF7"
    else "A975D5782140585200D4834F";
  staticTargetId =
    if isTVOS then "2FEA0A3B24902F9F00EEF3AD"
    else if isVisionOS then "DCFD7EDF2A45BC6E007BBBF7"
    else "A9B8EE091A98D796009C5A02";

  # These revisions are recorded by MoltenVK v1.4.2's ExternalRevisions.
  # Only the pieces linked into the public MoltenVK runtime are hydrated.
  cerealSrc = pkgs.fetchFromGitHub {
    owner = "USCiLab";
    repo = "cereal";
    rev = "a56bad8bbb770ee266e930c95d37fff2a5be7fea";
    hash = "sha256-Q2/W74G5DYvgjPpzPRDWcWdqmEVyaY9wZaoMlfvfOnM=";
  };
  spirvCrossSrc = pkgs.fetchFromGitHub {
    owner = "KhronosGroup";
    repo = "SPIRV-Cross";
    rev = "6c09849fe88c48eaed08413aa022aaa136a3a057";
    hash = "sha256-HjAVP+yMeybM8VQQO3aKmuxpvjA03EGjKUPWVQKoRuc=";
  };
  spirvToolsSrc = pkgs.fetchFromGitHub {
    owner = "KhronosGroup";
    repo = "SPIRV-Tools";
    rev = "0d6fd73ca73830ccab5fa1f00ed5ed40124e2c55";
    hash = "sha256-hmy+EbCdD9ec7T1dofPtlbUnZc/65x0T5OCaiEtWAOM=";
  };
  spirvHeadersSrc = pkgs.fetchFromGitHub {
    owner = "KhronosGroup";
    repo = "SPIRV-Headers";
    rev = "29981f65241605e08b0ede4cfeb999fe3b723c6a";
    hash = "sha256-tGY4H3+5p9M5LBK/xxRdMT9CX+qq3e7fPkaftnpjU9I=";
  };
  vulkanHeadersSrc = pkgs.fetchFromGitHub {
    owner = "KhronosGroup";
    repo = "Vulkan-Headers";
    rev = "e3b1eec08173d6b825cd3ac88c885a63b621504a";
    hash = "sha256-tAYvYx/Mqvf/I177xmx7oLZVc7S7GK3MArY3i+FCYuw=";
  };

  # On Apple silicon, generic/platform=iOS Simulator otherwise builds both
  # arm64 and x86_64 ExternalDependencies (SPIRV-Tools). That doubles wall
  # time and RAM. Product simulators on this host are arm64 only.
  simArchArgs = lib.optionals (simulator && pkgs.stdenv.hostPlatform.isAarch64) [
    "ONLY_ACTIVE_ARCH=YES"
    "ARCHS=arm64"
    "EXCLUDED_ARCHS=x86_64 i386"
  ];
in
pkgs.stdenv.mkDerivation (finalAttrs: {
  pname = "moltenvk-${platformName}${lib.optionalString simulator "-sim"}";
  version = "1.4.2";
  strictDeps = true;
  # Xcode is an impure host tool, as for the rest of Wawona's Apple SDK builds.
  __noChroot = true;

  src = pkgs.fetchFromGitHub {
    owner = "KhronosGroup";
    repo = "MoltenVK";
    rev = "v${finalAttrs.version}";
    hash = "sha256-iyYxuWZZfk2W3DW9OX3m77RLk0e8GTTpEV3Th7mIrXY=";
  };

  nativeBuildInputs = [ pkgs.unzip ];

  postPatch = ''
    mkdir -p External
    cp -R ${cerealSrc} External/cereal
    cp -R ${spirvCrossSrc} External/SPIRV-Cross
    cp -R ${vulkanHeadersSrc} External/Vulkan-Headers

    cp -R ${spirvToolsSrc} External/SPIRV-Tools
    chmod -R u+w External/SPIRV-Tools
    mkdir -p External/SPIRV-Tools/external
    cp -R ${spirvHeadersSrc} External/SPIRV-Tools/external/spirv-headers
    # MoltenVK ships generated SPIRV-Tools headers matching its source pin.
    # The Xcode project builds the target-native static library from source.
    unzip -q Templates/spirv-tools/build.zip -d External/SPIRV-Tools

    # The source archive has no .git metadata. Make the generated revision
    # header deterministic without changing upstream runtime sources.
    substituteInPlace Scripts/gen_moltenvk_rev_hdr.sh \
      --replace-fail '$(git rev-parse HEAD)' ${finalAttrs.src.rev}
    # This derivation always starts from a fresh source tree. Upstream's final
    # `make clean` merely launches a second Xcode build outside our explicit
    # derived-data path, where the Nix builder has no writable user Library.
    substituteInPlace Scripts/package_ext_libs_finish.sh \
      --replace-fail 'make --quiet clean' ':'
    mkdir -p MoltenVK/MoltenVK.xcodeproj/xcshareddata/xcschemes
    cp "MoltenVKPackaging.xcodeproj/xcshareddata/xcschemes/MoltenVK Package (${upstreamPackageOS} only).xcscheme" \
      "MoltenVK/MoltenVK.xcodeproj/xcshareddata/xcschemes/${staticScheme}.xcscheme"
    substituteInPlace "MoltenVK/MoltenVK.xcodeproj/xcshareddata/xcschemes/${staticScheme}.xcscheme" \
      --replace-fail ${packageTargetId} ${staticTargetId} \
      --replace-fail 'BuildableName = "MoltenVK-${xcodeOS}"' 'BuildableName = "libMoltenVK.a"' \
      --replace-fail 'BlueprintName = "MoltenVK-${xcodeOS}"' 'BlueprintName = "MoltenVK-${xcodeOS}-static"' \
      --replace-fail 'container:MoltenVKPackaging.xcodeproj' 'container:MoltenVK.xcodeproj'
    mkdir -p build/include
  '';

  preBuild = ''
    ${iosToolchain.mkIOSBuildEnv { inherit simulator; }}
    # Upstream package scripts invoke nested xcodebuild. Give Xcode an
    # derivation-local DerivedData home instead of the daemon's /var/empty.
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    export PATH="$DEVELOPER_DIR/usr/bin:$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH"
    export CC="$XCODE_CLANG"
    export CXX="$XCODE_CLANGXX"
    unset MACOSX_DEPLOYMENT_TARGET
    unset NIX_CFLAGS_COMPILE
    unset NIX_CXXFLAGS_COMPILE
    unset NIX_LDFLAGS
  '';

  buildPhase = ''
    runHook preBuild

    # This produces target-native SPIRV-Cross and the generated SPIRV-Tools
    # headers before the static public MoltenVK target is assembled.
    xcodebuild \
      -project ExternalDependencies.xcodeproj \
      -scheme "ExternalDependencies-${xcodeOS}" \
      -configuration Release \
      -destination "generic/platform=${xcodePlatform}" \
      -derivedDataPath "$PWD/External/build" \
      "${if isVisionOS then "XROS_DEPLOYMENT_TARGET" else if isTVOS then "TVOS_DEPLOYMENT_TARGET" else "IPHONEOS_DEPLOYMENT_TARGET"}=${iosToolchain.deploymentTarget}" \
      ${lib.escapeShellArgs simArchArgs} \
      build

    xcodebuild \
      -project MoltenVK/MoltenVK.xcodeproj \
      -scheme "${staticScheme}" \
      -configuration Release \
      -destination "generic/platform=${xcodePlatform}" \
      -derivedDataPath "$PWD/build" \
      "${if isVisionOS then "XROS_DEPLOYMENT_TARGET" else if isTVOS then "TVOS_DEPLOYMENT_TARGET" else "IPHONEOS_DEPLOYMENT_TARGET"}=${iosToolchain.deploymentTarget}" \
      GCC_PREPROCESSOR_DEFINITIONS='$(inherited) MVK_USE_METAL_PRIVATE_API=0' \
      ${lib.escapeShellArgs simArchArgs} \
      build

    runHook postBuild
  '';

  dontConfigure = true;

  installPhase = ''
    runHook preInstall
    archive=$(find build -type f -name libMoltenVK.a -print | LC_ALL=C sort | head -n 1)
    if [ -z "$archive" ]; then
      echo "missing libMoltenVK.a from the source build" >&2
      find build -type f -name '*.a' -print | LC_ALL=C sort >&2 || true
      exit 1
    fi
    mkdir -p "$out/lib" "$out/include" "$out/nix-support"
    install -m644 "$archive" "$out/lib/libMoltenVK.a"
    # The upstream include tree links into its source checkout. Materialize
    # those public headers so the Nix output has no dangling build paths.
    cp -RL MoltenVK/include/. "$out/include/"
    cat > "$out/nix-support/moltenvk-build-metadata.json" <<EOF
{
  "sourceBuild": true,
  "version": "${finalAttrs.version}",
  "upstreamTag": "v${finalAttrs.version}",
  "sdkPlatform": "${sdkPlatform}",
  "deploymentTarget": "${iosToolchain.deploymentTarget}",
  "linkKind": "static",
  "privateApiVariant": false,
  "patchSeries": []
}
EOF
    runHook postInstall
  '';

  meta = with lib; {
    description = "Pinned source-built, public-API MoltenVK static archive for Apple mobile";
    homepage = "https://github.com/KhronosGroup/MoltenVK";
    license = licenses.asl20;
    platforms = platforms.darwin;
  };
})
