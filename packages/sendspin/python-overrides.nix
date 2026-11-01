# The Sendspin Python packages at the releases nixtune is built and tested
# against, newer than nixpkgs carries. A Python package-set extension
# (pyFinal: pyPrev: { ... }), used two ways: packages/sendspin builds the
# player from a Python set extended with it, so nothing else on a host
# changes, and the flake's overlays.sendspin adds it to every Python set
# for a host that wants these versions everywhere.
#
# Sendspin has no stable branch: releases are tags cut from main, often
# several a week. nixtune follows the tags. To move to a newer release, set
# version and tag, set hash to lib.fakeHash, build, and copy the hash Nix
# reports; then run the rehearsal before deploying, because the spec is a
# preview (KnownIssue spec_is_preview) and a release can change the wire
# format or the player's state files (KnownIssue
# player_store_is_private_format).
{ fetchFromGitHub }:
_pyFinal: pyPrev: {
  aiosendspin = pyPrev.aiosendspin.overridePythonAttrs (_: {
    version = "10.2.2";
    src = fetchFromGitHub {
      owner = "Sendspin";
      repo = "aiosendspin";
      tag = "10.2.2";
      hash = "sha256-Y8DXmuoQHXA3dtnQVGjp0sQX3R4NYjQVU2JtpsorqRQ=";
    };
  });

  sendspin = pyPrev.sendspin.overridePythonAttrs (old: {
    version = "9.1.0";
    src = fetchFromGitHub {
      owner = "Sendspin";
      repo = "sendspin-cli";
      tag = "9.1.0";
      hash = "sha256-cEISCLSmu5IgvlJ6Dsuc2rk04OL5+Ic0pErApnoT93c=";
    };
    # KnownIssue player_start_hook_does_not_wait: the daemon runs its
    # start hook in the background, so the player could open the DAC
    # while MPD still holds it. With this patch, audio is held back until
    # the hook returns. To be offered upstream as an option.
    patches = (old.patches or [ ]) ++ [ ./hook-start-waits.patch ];
  });
}
