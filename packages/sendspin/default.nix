# The Sendspin player each room runs on its DAC: sendspin-cli's
# `sendspin daemon`, at the release in ./python-overrides.nix, with
# nixtune's patch. Built from a Python set of its own, so the host's other
# Python packages keep nixpkgs' versions.
{
  python3,
  fetchFromGitHub,
}:
let
  python = python3.override {
    self = python;
    packageOverrides = import ./python-overrides.nix { inherit fetchFromGitHub; };
  };
in
python.pkgs.toPythonApplication python.pkgs.sendspin
