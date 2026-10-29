# The player's page: a Halogen application that speaks the MPD protocol over
# a websocket and reads which modules the host was built with from
# capabilities.json beside it (nix/module/ui.nix writes that file). Built
# into index.js beside index.html; nginx serves the directory.
#
# Built from spago.lock directly, with nothing but nixpkgs. Each registry
# package in the lock is one fixed-output fetch of the registry's tarball,
# checked against the `integrity` hash the lock records, so the inputs are
# pinned by content and the build runs with the network off. The compiler
# is nixpkgs' purescript (0.15.15 as of this writing, x86_64 and aarch64)
# and the bundler is nixpkgs' esbuild; spago itself is not needed to build.
# spago remains the tool that EDITS the lock: `spago install`, `spago
# upgrade` in this directory, then commit spago.yaml and spago.lock together.
#
# Why not mkSpagoDerivation: it fetches the registry tarballs during
# evaluation, so every evaluation of a host that references the page needs
# the network and waits on eighty downloads, and it brings two flake inputs
# and their own inputs into the consumer's lock. The lock file already holds
# everything a fixed-output fetch needs.
{
  lib,
  stdenvNoCC,
  fetchurl,
  purescript,
  esbuild,
}:
let
  lock = builtins.fromJSON (builtins.readFile ./spago.lock);

  # Every package the lock resolves. Only registry packages are supported;
  # a git or local dependency would need its own fetch, and none is used.
  packages = lib.mapAttrsToList (
    name: p:
    assert lib.assertMsg (p.type == "registry")
      "nixtune-web: spago.lock entry ${name} has type ${p.type}; only registry packages are fetched here";
    {
      inherit name;
      tarball = fetchurl {
        url = "https://packages.registry.purescript.org/${name}/${p.version}.tar.gz";
        hash = p.integrity;
      };
    }
  ) lock.packages;

  # The registry packs each tarball as one directory, <name>-<version>/,
  # holding src/ and the manifest. Each is unpacked under deps/<name>/ with
  # that directory stripped, so the compile glob is the same for all.
  unpack = lib.concatMapStringsSep "\n" (p: ''
    mkdir -p deps/${p.name}
    tar -xzf ${p.tarball} -C deps/${p.name} --strip-components=1
  '') packages;
in
stdenvNoCC.mkDerivation {
  pname = "nixtune-web";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./src
      ./index.html
    ];
  };

  nativeBuildInputs = [
    purescript
    esbuild
  ];

  buildPhase = ''
    runHook preBuild

    ${unpack}

    purs compile 'src/**/*.purs' 'deps/*/src/**/*.purs'

    # What `spago bundle --platform browser --bundle-type app` produces: the
    # compiled Main module's main, called once, in a single self-contained
    # script.
    echo 'import { main } from "./output/Main/index.js"; main();' > entry.js
    esbuild entry.js \
      --bundle \
      --minify \
      --platform=browser \
      --format=iife \
      --outfile=index.js

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp index.html index.js $out/
    runHook postInstall
  '';

  meta = {
    description = "The nixtune player's page";
    license = lib.licenses.agpl3Plus;
    platforms = purescript.meta.platforms;
  };
}
