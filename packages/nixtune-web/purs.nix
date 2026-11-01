# The PureScript compiler the page is built with: the upstream release
# binary of v0.15.16, which is statically linked on Linux. Nothing is
# patched, so it does not depend on which glibc, gmp or ncurses the
# host's nixpkgs carries.
#
# That dependency is what broke the build. nixpkgs' purescript (0.15.15)
# is the dynamically linked release binary with patchelf pointed at
# nixpkgs' own libraries, and on a nixpkgs newer than the one this flake
# pins it segfaults in its own install phase, at
# `purs --bash-completion-script`. purs-nix gets its compiler from
# purs-nix/purescript-tools, which packages 0.15.15 the same way and has
# the same failure. Upstream's Linux releases are static from 0.15.16-7
# on, which is what removes the dependency rather than moving it.
#
# The URLs and hashes are the ones purescript-overlay's manifest records
# for "0.15.16" (manifests/purs.json); the devShell takes spago from that
# overlay. The overlay's own builder is not used for the page because it
# evaluates stdenv.isDarwin, which prints a deprecation warning on every
# evaluation of every host that imports the module.
{
  lib,
  stdenvNoCC,
  fetchurl,
}:
let
  version = "0.15.16";

  release = "https://github.com/purescript/purescript/releases/download/v${version}";

  sources = {
    x86_64-linux = {
      url = "${release}/linux64.tar.gz";
      hash = "sha256-RNqe+4pOFFGej9U1Csw3ekuYHkI1GnjFPp+EBFvzjiI=";
    };
    aarch64-linux = {
      url = "${release}/linux-arm64.tar.gz";
      hash = "sha256-uNFTxcbg2MlhipCCTrNCtYGOFKkrC2zf91PZs1OpJ/M=";
    };
  };

  system = stdenvNoCC.hostPlatform.system;
in
stdenvNoCC.mkDerivation {
  pname = "purs";
  inherit version;

  src = fetchurl (
    sources.${system} or (throw "nixtune-web: no PureScript ${version} release binary for ${system}")
  );

  # The tarball unpacks to purescript/purs. A static binary has no
  # interpreter or rpath to fix, and stripping a release binary gains
  # nothing.
  dontPatchELF = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall
    install -D -m555 -T purs $out/bin/purs
    runHook postInstall
  '';

  # Runs the binary once, so a release that will not start on this
  # platform fails here and not halfway through the page build.
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    $out/bin/purs --version
    runHook postInstallCheck
  '';

  meta = {
    description = "PureScript compiler, upstream static release binary";
    homepage = "https://github.com/purescript/purescript";
    license = lib.licenses.bsd3;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = builtins.attrNames sources;
    mainProgram = "purs";
  };
}