# watchOS: non-GL / non-IOKit stub (platform-targets matrix).
# Not pulled when weston enableIlandDrm=false; present so accidental builds
# never import the iOS ANGLE recipe.
{ lib, pkgs, ... }:

let
  ilandVersion = import ./version.nix;
in
pkgs.runCommand "iland-userland-watchos-stub-${ilandVersion}" {
  nativeBuildInputs = [ pkgs.binutils ];
  version = ilandVersion;
  meta = {
    homepage = "https://github.com/Wawona/iLand";
    description = "watchOS iland stub (no GPU userland)";
  };
} ''
  mkdir -p "$out/lib" "$out/include" "$out/nix-support"
  ar rcs "$out/lib/libiland_userland.a"
  echo stub > "$out/nix-support/link-kind"
  echo "${ilandVersion}" > "$out/nix-support/iland-version"
  cat > "$out/include/iland_stub.h" <<'EOF'
/* watchOS iland stub — no GPU userland. */
EOF
''
