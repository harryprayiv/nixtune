# Board and DAC facts, keyed by services.nixtune.hardware.profile.
#
# pi5-dac2hd: Raspberry Pi 5 with a HiFiBerry DAC2 HD. A PCM1796 behind I2S
# and an I2C control bus, with a low-jitter clock of its own and hardware
# volume on the ALSA control named "DAC". The Raspberry Pi kernel ships its
# overlay as hifiberry-dacplushd.
#
# ============================================================================
# TWO WAYS THE OVERLAY CAN REACH THE KERNEL, AND WHICH ONE A PI 5 USES
# ============================================================================
#
# nixos-hardware's Raspberry Pi profiles carry a firmware-partition module
# (hardware.raspberry-pi.firmware). On a Pi it owns the firmware partition:
# GPU boot code, the vendor device trees and overlays, a config.txt rendered
# from Nix options, and, when firmware.uboot.enable is set, U-Boot. WITHOUT
# uboot.enable the firmware has no kernel line and the board does not boot
# at all; the SD image built on 2026-10-29 failed exactly that way. With it,
# the GPU firmware merges config.txt's dtoverlay lines into its own device
# tree and hands that to U-Boot, and nixos-hardware turns off
# useGenerationDeviceTree so U-Boot does not reload a bare tree and lose
# them. On that path the overlay is a config.txt line, which is what this
# file writes when those options exist. The firmware's own overlay loader
# does not check compatible strings, so the vendor hifiberry-dacplushd.dtbo
# applies as shipped.
#
# The other path is nixpkgs' own: hardware.deviceTree.overlays applied at
# build time to the generation's DTB, which U-Boot loads through extlinux's
# FDTDIR when useGenerationDeviceTree is true. nixpkgs applies an overlay
# only when it shares a compatible string with the DTB
# (pkgs/os-specific/linux/device-tree/apply_overlays.py), the kernel ships
# every HiFiBerry overlay as "brcm,bcm2835", and the Pi 5 DTB is
# "brcm,bcm2712", so for that path the dtbo is copied and that one string
# rewritten. This file writes both, so whichever device tree the kernel is
# given carries the DAC.
{
  config,
  lib,
  options,
  pkgs,
  ...
}:
let
  cfg = config.services.nixtune;

  profiles = {
    pi5-dac2hd = {
      kind = "alsa";
      overlay = "hifiberry-dacplushd";
      card = "sndrpihifiberry";
      mixer = "DAC";
      raspberryPi = true;
    };
    none = {
      kind = "null";
      overlay = null;
      card = null;
      mixer = null;
      raspberryPi = false;
    };
  };

  profile = profiles.${cfg.hardware.profile};

  # nixos-hardware's Raspberry Pi options are present only when one of its
  # Pi profiles is imported. A host without them (the rehearsal VM, or a
  # board that is not a Pi) gets nothing from the firmware branch below.
  haveRpiOptions = options.hardware ? raspberry-pi;

  kernel = config.boot.kernelPackages.kernel;

  dtbo =
    pkgs.runCommand "${profile.overlay}-bcm2712.dtbo"
      {
        nativeBuildInputs = [ pkgs.dtc ];
      }
      ''
        src="${kernel}/dtbs/overlays/${profile.overlay}.dtbo"
        if [ ! -e "$src" ]; then
          echo "nixtune: ${kernel.name} ships no ${profile.overlay}.dtbo under dtbs/overlays" >&2
          echo "nixtune: this profile needs the Raspberry Pi kernel (nixos-hardware's raspberry-pi-5 module)" >&2
          exit 1
        fi
        cp "$src" "$out"
        chmod u+w "$out"
        fdtput -t s "$out" / compatible "brcm,bcm2712"
      '';
in
{
  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        services.nixtune.output = {
          inherit (profile) kind card mixer;
          device = if profile.card == null then null else "hw:CARD=${profile.card},DEV=0";
        };
      }

      # The generation-DTB path.
      (lib.mkIf (profile.overlay != null) {
        hardware.deviceTree.overlays = [
          {
            name = profile.overlay;
            dtboFile = dtbo;
          }
        ];
      })

      # The firmware path, when nixos-hardware's Pi module is present.
      # optionalAttrs, not mkIf alone: mkIf keeps the attribute path in the
      # definition, and a host without the Pi module would then fail with
      # "option hardware.raspberry-pi does not exist".
      (lib.optionalAttrs haveRpiOptions (lib.mkIf profile.raspberryPi {
        # Chainload U-Boot from the GPU firmware. Without this the firmware
        # partition has no kernel line and the board never boots.
        hardware.raspberry-pi.firmware.uboot.enable = lib.mkDefault true;

        # The DAC, as a config.txt line. This replaces nixos-hardware's
        # default list for [all], which is vc4-kms-v3d alone; a headless
        # player has no use for the KMS display driver, and the firmware's
        # framebuffer still gives an HDMI console for debugging.
        hardware.raspberry-pi.configtxt.deviceTreeOverlays.all = [
          { ${profile.overlay} = { }; }
        ];
      }))
    ]
  );
}