# Board and DAC facts, keyed by services.nixtune.hardware.profile.
#
# pi5-dac2hd: Raspberry Pi 5 with a HiFiBerry DAC2 HD. A PCM1796 behind I2S
# and an I2C control bus, with a low-jitter clock of its own and hardware
# volume on the ALSA control named "DAC". The Raspberry Pi kernel ships its
# overlay as hifiberry-dacplushd.
#
# ============================================================================
# THE OVERLAY'S COMPATIBLE STRING HAS TO BE REWRITTEN
# ============================================================================
#
# nixpkgs applies a device tree overlay to a DTB only when the two share a
# compatible string (pkgs/os-specific/linux/device-tree/apply_overlays.py).
# The kernel ships every HiFiBerry overlay as "brcm,bcm2835", and the Pi 5
# DTB is "raspberrypi,5-model-b" plus "brcm,bcm2712", so the shipped file is
# skipped with a one-line message in the build log and the card never
# appears. The derivation below copies the kernel's own dtbo and changes
# that one property. Nothing else in the overlay is touched, and the symbols
# it fixes up against (i2s_clk_consumer, i2c1, sound) exist in the Pi 5 DTB.
#
# WHY NOT config.txt. The generic aarch64 SD image boots firmware, then
# U-Boot, then extlinux, and extlinux hands U-Boot the DTB NixOS built, with
# the overlays already applied. dtoverlay= lines in config.txt affect only the
# firmware's copy, which U-Boot then replaces.
{
  config,
  lib,
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
    };
    none = {
      kind = "null";
      overlay = null;
      card = null;
      mixer = null;
    };
  };

  profile = profiles.${cfg.hardware.profile};

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

      (lib.mkIf (profile.overlay != null) {
        hardware.deviceTree.overlays = [
          {
            name = profile.overlay;
            dtboFile = dtbo;
          }
        ];
      })
    ]
  );
}
