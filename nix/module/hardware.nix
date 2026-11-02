# The board and the audio output: services.nixtune.hardware.*, and the
# facts every other file reads from services.nixtune.output.
#
# Two choices, made separately. hardware.board is the computer: a Raspberry
# Pi 3, 4 or 5, or something that is not a Raspberry Pi. hardware.audio is
# where the sound leaves it: a HiFiBerry DAC2 HD, the Pi's own headphone
# jack, the Pi's HDMI, a USB DAC, or any other card (a HAT with its own
# overlay). The combinations the hardware does not have are refused at
# evaluation, with a message saying why.
#
# What an output decides:
#
#   device   the ALSA PCM that MPD, shairport-sync and the multiroom player
#            open. hw:CARD=<id>,DEV=0 for a card that takes the file as it
#            is; for HDMI, alsa-lib's iec958 plugin over the card, because
#            the vc4-hdmi device accepts only IEC958 subframes.
#   convert  whether MPD may resample and convert the format. Off for a
#            DAC, which takes every rate and depth the library has, so the
#            path stays bit-perfect. On for the headphone jack (16 bits,
#            48 kHz at most) and HDMI (the iec958 plugin's formats).
#   mixer    the card's hardware volume control, or null. With a control,
#            the volume helper writes it (volume.nix); without one, MPD's
#            software mixer sets the level, the only option on HDMI.
#
# ============================================================================
# TWO WAYS AN OVERLAY CAN REACH THE KERNEL, AND WHICH ONE A PI USES
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
# them. On that path an overlay is a config.txt line, which is what this
# file writes when those options exist. The firmware's own overlay loader
# does not check compatible strings, so a vendor .dtbo applies as shipped.
#
# The other path is nixpkgs' own: hardware.deviceTree.overlays applied at
# build time to the generation's DTB, which U-Boot loads through extlinux's
# FDTDIR when useGenerationDeviceTree is true. nixpkgs applies an overlay
# only when it shares a compatible string with the DTB
# (pkgs/os-specific/linux/device-tree/apply_overlays.py), the kernel ships
# every HiFiBerry overlay as "brcm,bcm2835", and each board's DTB names its
# own SoC, so for that path the dtbo is copied and that one string
# rewritten to the board's. This file writes both, so whichever device tree
# the kernel is given carries the card.
#
# HDMI audio is part of the KMS display driver, vc4-kms-v3d, so an HDMI
# output keeps that overlay in config.txt; every other output drops it, as
# a headless player has no use for it. The headphone jack is switched on
# by dtparam=audio=on, which nixos-hardware's config.txt defaults already
# carry.
{
  config,
  lib,
  options,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption types;

  cfg = config.services.nixtune;
  hw = cfg.hardware;

  boards = {
    pi3 = {
      raspberryPi = true;
      soc = "brcm,bcm2837";
      headphones = true;
      hdmiPorts = 1;
    };
    pi4 = {
      raspberryPi = true;
      soc = "brcm,bcm2711";
      headphones = true;
      hdmiPorts = 2;
    };
    pi5 = {
      raspberryPi = true;
      soc = "brcm,bcm2712";
      headphones = false;
      hdmiPorts = 2;
    };
    other = {
      raspberryPi = false;
      soc = null;
      headphones = false;
      hdmiPorts = 0;
    };
  };

  board = boards.${hw.board};

  # vc4-hdmi names its card vc4hdmi on a board with one port, and
  # vc4hdmi0 and vc4hdmi1 on a board with two.
  hdmiCard = if board.hdmiPorts == 1 then "vc4hdmi" else "vc4hdmi${toString hw.hdmiPort}";

  # The iec958 plugin alsa-lib's vc4-hdmi.conf defines, with the channel
  # status its own default PCM uses: AES3=0x01 is "sample rate not
  # indicated", which the plugin fills in with the stream's real rate.
  # Plain hdmi:CARD=... takes AES3 from pcm/hdmi.conf, whose default,
  # 0x02, marks every stream 48 kHz whatever its rate.
  hdmiDevice = "hdmi:CARD=${hdmiCard},DEV=0,AES0=0x04,AES1=0x82,AES2=0x00,AES3=0x01";

  outputs = {
    dac2hd = {
      kind = "alsa";
      overlay = "hifiberry-dacplushd";
      card = "sndrpihifiberry";
      mixer = "DAC";
      convert = false;
      hdmi = false;
    };
    # snd_bcm2835. Its volume control has been "PCM" on this card since
    # the driver gave the jack a card of its own (it was "Headphone" in
    # 2018's staging driver), and the Raspberry Pi kernel nixos-hardware
    # builds is far newer.
    headphones = {
      kind = "alsa";
      overlay = null;
      card = "Headphones";
      mixer = if hw.card.mixer != null then hw.card.mixer else "PCM";
      convert = true;
      hdmi = false;
    };
    hdmi = {
      kind = "alsa";
      overlay = null;
      card = hdmiCard;
      mixer = null;
      convert = true;
      hdmi = true;
    };
    usb = {
      kind = "alsa";
      overlay = null;
      card = hw.card.id;
      mixer = hw.card.mixer;
      convert = hw.card.convert;
      hdmi = false;
    };
    hat = {
      kind = "alsa";
      overlay = hw.card.overlay;
      card = hw.card.id;
      mixer = hw.card.mixer;
      convert = hw.card.convert;
      hdmi = false;
    };
    none = {
      kind = "null";
      overlay = null;
      card = null;
      mixer = null;
      convert = false;
      hdmi = false;
    };
  };

  audio = outputs.${hw.audio};

  # Outputs that exist only on a Raspberry Pi, and outputs named by
  # card.id.
  piOutputs = [
    "dac2hd"
    "headphones"
    "hdmi"
    "hat"
  ];
  namedOutputs = [
    "usb"
    "hat"
  ];

  device =
    if audio.card == null then
      null
    else if audio.hdmi then
      hdmiDevice
    else
      "hw:CARD=${audio.card},DEV=0";

  # The profiles of earlier releases, as a board and an output.
  legacy = {
    pi5-dac2hd = {
      board = "pi5";
      audio = "dac2hd";
    };
    none = {
      board = "other";
      audio = "none";
    };
  };

  # nixos-hardware's Raspberry Pi options are present only when one of its
  # Pi profiles is imported. A host without them (the rehearsal VM, or a
  # board that is not a Pi) gets nothing from the firmware branch below.
  haveRpiOptions = options.hardware ? raspberry-pi;

  kernel = config.boot.kernelPackages.kernel;

  dtbo =
    pkgs.runCommand "${audio.overlay}-${lib.replaceStrings [ "," ] [ "-" ] board.soc}.dtbo"
      {
        nativeBuildInputs = [ pkgs.dtc ];
      }
      ''
        src="${kernel}/dtbs/overlays/${audio.overlay}.dtbo"
        if [ ! -e "$src" ]; then
          echo "nixtune: ${kernel.name} ships no ${audio.overlay}.dtbo under dtbs/overlays" >&2
          echo "nixtune: this output needs the Raspberry Pi kernel (one of nixos-hardware's raspberry-pi modules)" >&2
          exit 1
        fi
        cp "$src" "$out"
        chmod u+w "$out"
        fdtput -t s "$out" / compatible "${board.soc}"
      '';

  firmwareOverlays =
    lib.optional (audio.overlay != null) { ${audio.overlay} = { }; }
    ++ lib.optional audio.hdmi { vc4-kms-v3d = { }; };
in
{
  options.services.nixtune.hardware = {
    board = mkOption {
      type = types.enum [
        "pi3"
        "pi4"
        "pi5"
        "other"
      ];
      default = "pi5";
      description = ''
        The computer this host is built for.

        pi3    Raspberry Pi 3 B, 3 B+, 3 A+, and the Zero 2 W, which has
               the same SoC. With nixos-hardware's raspberry-pi-3 module.
        pi4    Raspberry Pi 4 B, 400 and Compute Module 4. With
               nixos-hardware's raspberry-pi-4 module.
        pi5    Raspberry Pi 5, 500 and Compute Module 5. With
               nixos-hardware's raspberry-pi-5 module.
        other  Anything that is not a Raspberry Pi: a PC, another board,
               a rehearsal VM.
      '';
    };

    audio = mkOption {
      type = types.enum [
        "dac2hd"
        "headphones"
        "hdmi"
        "usb"
        "hat"
        "none"
      ];
      default = "dac2hd";
      description = ''
        Where the sound leaves the computer.

        dac2hd      A HiFiBerry DAC2 HD on a Raspberry Pi. Bit-perfect, with
                    hardware volume.
        headphones  The 3.5 mm jack of a Pi 3 or Pi 4 B. 16 bits, 48 kHz at
                    most, so MPD converts. Volume on the card's control,
                    "PCM" unless card.mixer names another.
        hdmi        A Raspberry Pi's HDMI port (hdmiPort), to a TV or an AV
                    receiver that is on when the Pi boots. MPD converts and
                    sets the level in software.
        usb         A USB DAC or sound card, named by card.id, on any
                    computer.
        hat         Any other sound card or HAT, named by card.id, with
                    card.overlay for a HAT's device tree overlay.
        none        No sound card. MPD plays into a null output. For a
                    rehearsal VM, where everything but the sound is
                    exercised.
      '';
    };

    hdmiPort = mkOption {
      type = types.ints.between 0 1;
      default = 0;
      description = ''
        With audio = "hdmi": which HDMI port, on a board with two. 0 is the
        port next to the power connector.
      '';
    };

    card = {
      id = mkOption {
        type = types.nullOr (types.strMatching "[A-Za-z0-9_-]+");
        default = null;
        example = "DAC";
        description = ''
          With audio = "usb" or "hat": the card's ALSA id, the name in
          square brackets in /proc/asound/cards on the running machine.
        '';
      };
      mixer = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "PCM";
        description = ''
          With audio = "usb" or "hat": the card's playback volume control,
          as `amixer -c <id> scontrols` names it, or null for MPD's
          software volume. With audio = "headphones": the control's name
          if it is not "PCM".
        '';
      };
      overlay = mkOption {
        type = types.nullOr (types.strMatching "[A-Za-z0-9_-]+");
        default = null;
        example = "hifiberry-dacplus";
        description = ''
          With audio = "hat": the device tree overlay the HAT needs, as its
          maker names it for config.txt's dtoverlay line, or null for one
          the firmware detects from the HAT's EEPROM.
        '';
      };
      convert = mkOption {
        type = types.bool;
        default = false;
        description = ''
          With audio = "usb" or "hat": let MPD resample and convert the
          format. Off keeps the path bit-perfect; turn it on for a card that
          refuses some of the library's rates or depths, which MPD reports
          as a failure to open the output.
        '';
      };
    };

    profile = mkOption {
      type = types.nullOr (
        types.enum [
          "pi5-dac2hd"
          "none"
        ]
      );
      default = null;
      description = ''
        The single setting of earlier releases, kept so their hosts build:
        "pi5-dac2hd" is board "pi5" with audio "dac2hd", and "none" is
        board "other" with audio "none". New hosts set board and audio.
      '';
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      # Written out per option rather than mapped over legacy: the module
      # system needs a definition's attribute names before it can read
      # hw.profile, and names computed from hw.profile would recurse.
      (lib.mkIf (hw.profile != null) {
        services.nixtune.hardware.board = lib.mkDefault legacy.${hw.profile}.board;
        services.nixtune.hardware.audio = lib.mkDefault legacy.${hw.profile}.audio;
      })

      {
        services.nixtune.output = {
          inherit (audio) kind card mixer convert;
          inherit device;
        };

        assertions = [
          {
            assertion = hw.audio != "headphones" || !board.raspberryPi || board.headphones;
            message = "services.nixtune.hardware.audio = \"headphones\" needs a board with a 3.5 mm jack: a Pi 3 or Pi 4 B. The Pi 5 and 500, the 400 and the Zero 2 W have none.";
          }
          {
            assertion = !(lib.elem hw.audio piOutputs) || board.raspberryPi;
            message = "services.nixtune.hardware.audio = \"${hw.audio}\" is a Raspberry Pi output; on another computer use \"usb\" or \"none\".";
          }
          {
            assertion = hw.audio != "hdmi" || !board.raspberryPi || hw.hdmiPort < board.hdmiPorts;
            message = "services.nixtune.hardware.hdmiPort = 1 needs a board with two HDMI ports, a Pi 4 or Pi 5; a Pi 3 has one, which is port 0.";
          }
          {
            assertion = !(lib.elem hw.audio namedOutputs) || hw.card.id != null;
            message = "services.nixtune.hardware.audio = \"${hw.audio}\" needs hardware.card.id, the card's ALSA id from /proc/asound/cards.";
          }
        ];
      }

      # The generation-DTB path.
      (lib.mkIf (audio.overlay != null && board.raspberryPi) {
        hardware.deviceTree.overlays = [
          {
            name = audio.overlay;
            dtboFile = dtbo;
          }
        ];
      })

      # The firmware path, when nixos-hardware's Pi module is present.
      # optionalAttrs, not mkIf alone: mkIf keeps the attribute path in the
      # definition, and a host without the Pi module would then fail with
      # "option hardware.raspberry-pi does not exist".
      (lib.optionalAttrs haveRpiOptions (
        lib.mkIf board.raspberryPi {
          # Chainload U-Boot from the GPU firmware. Without this the
          # firmware partition has no kernel line and the board never
          # boots.
          hardware.raspberry-pi.firmware.uboot.enable = lib.mkDefault true;

          # The card's overlay, and vc4-kms-v3d only for HDMI. This
          # replaces nixos-hardware's default list for [all], which is
          # vc4-kms-v3d alone; the firmware's framebuffer still gives an
          # HDMI console for debugging without it.
          hardware.raspberry-pi.configtxt.deviceTreeOverlays.all = firmwareOverlays;
        }
      ))
    ]
  );
}