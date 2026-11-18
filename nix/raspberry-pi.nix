# The Raspberry Pi layer, one module per board: nixosModules.raspberry-pi-02,
# -3, -4 and -5. Each imports nixos-raspberrypi's board module and sets
# services.nixtune.hardware.board to match.
#
# What a host gets from one of these, beside nixosModules.default:
#
#   the vendor kernel and firmware from nixos-raspberrypi's own package set,
#   which nixos-raspberrypi.cachix.org holds, so they are downloaded and not
#   compiled. The board modules take them from that flake's packages, built
#   with that flake's pinned nixpkgs, not from the host's pkgs, so the cache
#   applies whatever nixpkgs the host follows.
#
#   that cache as a substituter on the Pi (nixos-raspberrypi's
#   trusted-nix-caches). A workstation that builds the Pi's system needs
#   the same substituter and key in its own nix.settings.
#
#   the firmware partition and config.txt, managed at every switch. The GPU
#   firmware boots the kernel directly on a Pi 5 and through U-Boot on the
#   others (nixos-raspberrypi's defaults per board). hardware.nix writes the
#   card's overlay and the audio parameters into hardware.raspberry-pi.config.
#
# What a host still supplies: nixpkgs.hostPlatform, fileSystems."/" and
# fileSystems."/boot/firmware" (nixos-raspberrypi's sd-image module,
# nixosModules.sd-image here, declares both for an SD card), the hostname
# and everything else.
#
# nixos-raspberrypi's board modules read the flake through a module argument
# named nixos-raspberrypi, which its own lib.nixosSystem passes in
# specialArgs. These modules set it with _module.args instead, so a host
# built with nixpkgs.lib.nixosSystem needs nothing extra. The argument is
# used only in config values, never in imports, which is what makes
# _module.args enough.
#
# Do not import nixos-hardware's raspberry-pi modules beside these. Both
# declare hardware.raspberry-pi.*, and the definitions collide.
#
# ============================================================================
# THE KERNEL ON A NEWER NIXPKGS
# ============================================================================
#
# nixos-raspberrypi builds its kernels with its own nixpkgs, nixos-26.05 at
# the time of writing. nixos-unstable's modules read two attributes of the
# kernel that 26.05's kernel builder does not set: kernel.target
# (system.boot.loader.kernelFile, and nixos-raspberrypi's own loader, which
# reads it on any release from 26.11) and kernel.buildDTBs
# (hardware.deviceTree.enable). Without them a host on nixos-unstable fails
# to evaluate: "attribute 'buildDTBs' missing", then "attribute 'target'
# missing".
#
# withKernelAttrs adds both to the kernel as plain attributes. That changes
# no derivation, so the kernel is the one in the cache. NixOS overrides the
# kernel again in boot.kernelPackages' apply (to add kernelPatches and
# features), which returns a fresh attribute set, so the override function
# is wrapped to add the two attributes to whatever it returns. A kernel that
# already has target, which is every kernel once nixos-raspberrypi moves to
# a nixpkgs that sets it, passes through untouched.
{ nixos-raspberrypi }:
let
  rpi = nixos-raspberrypi.nixosModules;

  withKernelAttrs =
    linuxPackages:
    let
      add =
        kernel:
        if kernel ? target then
          kernel
        else
          kernel
          // {
            # What nixpkgs' kernel builder picks on aarch64, which is the
            # only platform these boards run nixtune on.
            target = "Image";
            buildDTBs = true;
            override = f: add (kernel.override f);
          };
    in
    linuxPackages.extend (_: prev: { kernel = add prev.kernel; });

  board =
    name: variant: boardModule:
    {
      lib,
      options,
      pkgs,
      ...
    }:
    {
      imports = [
        boardModule
        # The bootloader, kernel, firmware and vendor packages as overlays
        # on the host's pkgs, as nixos-raspberrypi's lib.nixosSystem adds
        # them. nixpkgs applies these on top of nixpkgs.pkgs too, when a
        # host sets that.
        nixos-raspberrypi.lib.inject-overlays
        rpi.trusted-nix-caches
      ];

      config = lib.mkMerge [
        {
          _module.args.nixos-raspberrypi = nixos-raspberrypi;

          # The board module's kernel, with the two attributes above. 900
          # is above the board module's mkDefault and below a host's plain
          # setting.
          boot.kernelPackages = lib.mkOverride 900 (
            withKernelAttrs
              nixos-raspberrypi.packages.${pkgs.stdenv.hostPlatform.system}."linuxPackages_rpi${variant}"
          );
        }

        # optionalAttrs on the option's presence, so this module also
        # evaluates on a host that has not imported nixosModules.default.
        (lib.optionalAttrs (options.services ? nixtune) {
          services.nixtune.hardware.board = lib.mkDefault name;
        })
      ];
    };
in
{
  raspberry-pi-02 = board "zero2w" "02" rpi.raspberry-pi-02.base;

  raspberry-pi-3 = board "pi3" "3" rpi.raspberry-pi-3.base;

  # The Pi 4 B, 400 and Compute Module 4. A Pi 400 sets
  # services.nixtune.hardware.board = "pi400" over this default.
  raspberry-pi-4 = board "pi4" "4" rpi.raspberry-pi-4.base;

  raspberry-pi-5 =
    { lib, ... }:
    {
      imports = [ (board "pi5" "5" rpi.raspberry-pi-5.base) ];

      # nixos-raspberrypi defaults the Pi 5 to "kernelboot", which it has
      # deprecated and warns about at every evaluation, and recommends the
      # generational "kernel" loader, which its own SD images use. 900 is
      # above its mkDefault and below a host's plain setting.
      boot.loader.raspberry-pi.bootloader = lib.mkOverride 900 "kernel";
    };

  # An SD card's partitions, firmware population and image, from
  # nixos-raspberrypi.
  sd-image = rpi.sd-image;
}
