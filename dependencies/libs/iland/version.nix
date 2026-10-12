# CalVer for iland packages (Settings → Dependencies, Nix pname version).
# Root VERSION is the single source of truth. Tag releases as vYY.M.D.
builtins.replaceStrings [ "\n" "\r" " " ] [ "" "" "" ] (
  builtins.readFile ../../../VERSION
)
