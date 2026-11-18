# The board and the audio output: services.nixtune.hardware.*, and the
# facts every other file reads from services.nixtune.output.
#
# Two choices, made separately. hardware.board is the computer: a Raspberry
# Pi Zero 2 W, 3, 4, 400 or 5, or something that is not a Raspberry Pi.
# hardware.audio is where the sound leaves it: a HiFiBerry card named by
# product (cards.nix), the Pi's own headphone jack, the Pi's HDMI, a USB
# DAC, or any other card (a HAT with its own overlay). The combinations the
# hardware does not have are refused at evaluation, with a message saying
# why.
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
#            48 kHz at most), HDMI (the iec958 plugin's formats) and the
#            cards in cards.nix whose chips take fewer rates.
#   mixer    the card's hardware volume control, or null. With a control,
#            the volume helper writes it (volume.nix); without one, MPD's
#            software mixer sets the level, the only option on HDMI.
#
# ============================================================================
# WHERE THE BOOT PATH COMES FROM
# ============================================================================
#
# The module does not boot a Pi by itself. A host imports one of two
# Raspberry Pi layers beside it, and this file writes to whichever is there.
# Each is recognised by the options it declares, so a host with neither (the
# rehearsal VM, a PC) evaluates and gets none of this.
#
# nixos-raspberrypi (github:nvmd/nixos-raspberrypi), through this flake's
# nixosModules.raspberry-pi-02, -3, -4 and -5, recognised by
# hardware.raspberry-pi.config. The vendor kernel and firmware come from
# that flake's own package set, which its binary cache holds, so the kernel
# is downloaded and not compiled whatever nixpkgs the host uses. On a Pi 5
# the GPU firmware boots the kernel directly (nixtune selects the
# generational "kernel" loader); on the other boards it chainloads U-Boot,
# which takes the firmware's device tree because nixos-raspberrypi leaves
# useGenerationDeviceTree off for U-Boot. Either way the firmware applies
# config.txt's dtoverlay lines to the tree the kernel gets, so an overlay is
# a config.txt entry and nothing else. The build-time overlay below is NOT
# written on this path: the "kernel" loader installs the generation's own
# DTBs, and an overlay applied at build time would then be applied a second
# time by the firmware.
#
# nixos-hardware's Raspberry Pi profiles, recognised by
# hardware.raspberry-pi.configtxt. They carry a firmware-partition module
# (hardware.raspberry-pi.firmware) that owns the firmware partition: GPU
# boot code, the vendor device trees and overlays, a config.txt rendered
# from Nix options, and, when firmware.uboot.enable is set, U-Boot. WITHOUT
# uboot.enable the firmware has no kernel line and the board does not boot
# at all; the SD image built on 2026-10-29 failed exactly that way. With it,
# the GPU firmware merges config.txt's dtoverlay lines into its own device
# tree and hands that to U-Boot, and nixos-hardware turns off
# useGenerationDeviceTree so U-Boot does not reload a bare tree and lose
# them. On that path an overlay is a config.txt line, which is what this
# file writes. The firmware's own overlay loader does not check compatible
# strings, so a vendor .dtbo applies as shipped. The kernel is built from
# source on this path.
#
# The third route is nixpkgs' own: hardware.deviceTree.overlays applied at
# build time to the generation's DTB, which U-Boot loads through extlinux's
# FDTDIR when useGenerationDeviceTree is true. nixpkgs applies an overlay
# only when it shares a compatible string with the DTB
# (pkgs/os-specific/linux/device-tree/apply_overlays.py), the kernel ships
# every HiFiBerry overlay as "brcm,bcm2835", and each board's DTB names its
# own SoC, so for that route the dtbo is copied and that one string
# rewritten to the board's. It is written beside nixos-hardware's config.txt
# line, so whichever device tree the kernel is given carries the card. It
# cannot carry an overlay parameter (Amp100's auto_mute); config.txt does.
#
# ============================================================================
# THE PI'S OWN AUDIO
# ============================================================================
#
# The onboard analog audio (snd_bcm2835) is switched off with
# dtparam=audio=off and its module blacklisted on every output but the
# headphone jack. The Raspberry Pi kernel registers that card even with the
# dtparam off, and a second card is one more thing for a person reading
# /proc/asound/cards to mistake for the output.
#
# HDMI audio is part of the KMS display driver, vc4-kms-v3d. On
# nixos-hardware an HDMI output keeps that overlay in config.txt and every
# other output drops it, as a headless player has no use for it, and the
# firmware's framebuffer still gives an HDMI console. On nixos-raspberrypi,
# which keeps vc4-kms-v3d on by default, every output but HDMI sets its
# noaudio parameter, which removes the HDMI sound cards and keeps the
# display.
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

  cards = import ./cards.nix;

  boards = {
    zero2w = {
      raspberryPi = true;
      soc = "brcm,bcm2837";
      headphones = false;
      hdmiPorts = 1;
    };
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
    pi400 = {
      raspberryPi = true;
      soc = "brcm,bcm2711";
      headphones = false;
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

  # The HiFiBerry card in use: the DAC2 HD for audio = "dac2hd", the one
  # hardware.hifiberry names for audio = "hifiberry", and null otherwise.
  # null as well when hifiberry is chosen and no card is named; an
  # assertion below says so.
  hifiberry =
    if hw.audio == "dac2hd" then
      cards.dac2hd
    else if hw.audio == "hifiberry" && hw.hifiberry != null then
      cards.${hw.hifiberry}
    else
      null;

  # A HiFiBerry output. card.mixer replaces the card's control when it is
  # set, and card.convert turns conversion on for a card whose chip turns
  # out to refuse some of the library's rates.
  hifiberryOutput = c: {
    kind = "alsa";
    inherit (c) overlay params;
    card = "sndrpihifiberry";
    mixer = if hw.card.mixer != null then hw.card.mixer else c.mixer;
    convert = c.convert || hw.card.convert;
    hdmi = false;
  };

  outputs = {
    dac2hd = {
      kind = "alsa";
      inherit (cards.dac2hd) overlay params mixer convert;
      card = "sndrpihifiberry";
      hdmi = false;
    };
    hifiberry =
      if hifiberry == null then
        {
          kind = "alsa";
          overlay = null;
          params = { };
          card = "sndrpihifiberry";
          mixer = null;
          convert = false;
          hdmi = false;
        }
      else
        hifiberryOutput hifiberry;
    # snd_bcm2835. Its volume control has been "PCM" on this card since
    # the driver gave the jack a card of its own (it was "Headphone" in
    # 2018's staging driver), and both Raspberry Pi kernels are far newer.
    headphones = {
      kind = "alsa";
      overlay = null;
      params = { };
      card = "Headphones";
      mixer = if hw.card.mixer != null then hw.card.mixer else "PCM";
      convert = true;
      hdmi = false;
    };
    hdmi = {
      kind = "alsa";
      overlay = null;
      params = { };
      card = hdmiCard;
      mixer = null;
      convert = true;
      hdmi = true;
    };
    usb = {
      kind = "alsa";
      overlay = null;
      params = { };
      card = hw.card.id;
      mixer = hw.card.mixer;
      convert = hw.card.convert;
      hdmi = false;
    };
    hat = {
      kind = "alsa";
      overlay = hw.card.overlay;
      params = { };
      card = hw.card.id;
      mixer = hw.card.mixer;
      convert = hw.card.convert;
      hdmi = false;
    };
    none = {
      kind = "null";
      overlay = null;
      params = { };
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
    "hifiberry"
    "headphones"
    "hdmi"
    "hat"
  ];
  namedOutputs = [
    "usb"
    "hat"
  ];

  # The Pi's own analog audio stays on only when it is the output.
  onboardAudioOff = board.raspberryPi && hw.audio != "headphones";

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

  # Which Raspberry Pi layer the host imported, by the options it declares.
  # Neither on a host that is not a Pi.
  haveRpiOptions = options.hardware ? raspberry-pi;
  nixosRaspberrypi = haveRpiOptions && options.hardware.raspberry-pi ? config;
  nixosHardware = haveRpiOptions && options.hardware.raspberry-pi ? configtxt;

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
          echo "nixtune: this output needs the Raspberry Pi kernel (nixtune's raspberry-pi modules, or one of nixos-hardware's)" >&2
          exit 1
        fi
        cp "$src" "$out"
        chmod u+w "$out"
        fdtput -t s "$out" / compatible "${board.soc}"
      '';

  # nixos-hardware's overlay list: the card's overlay with its parameters,
  # and vc4-kms-v3d only for HDMI.
  configtxtOverlays =
    lib.optional (audio.overlay != null) { ${audio.overlay} = audio.params; }
    ++ lib.optional audio.hdmi { vc4-kms-v3d = { }; };

  cardNames = lib.attrNames cards;
in
{
  options.services.nixtune.hardware = {
    board = mkOption {
      type = types.enum [
        "zero2w"
        "pi3"
        "pi4"
        "pi400"
        "pi5"
        "other"
      ];
      default = "pi5";
      description = ''
        The computer this host is built for.

        zero2w  Raspberry Pi Zero 2 W. No headphone jack, one mini HDMI.
                With nixtune's nixosModules.raspberry-pi-02, or
                nixos-hardware's raspberry-pi-3 module.
        pi3     Raspberry Pi 3 B, 3 B+ and 3 A+. With nixtune's
                nixosModules.raspberry-pi-3, or nixos-hardware's
                raspberry-pi-3 module.
        pi4     Raspberry Pi 4 B and Compute Module 4. With nixtune's
                nixosModules.raspberry-pi-4, or nixos-hardware's
                raspberry-pi-4 module. A Compute Module 4 has no
                headphone jack, which this choice cannot tell.
        pi400   Raspberry Pi 400. No headphone jack. With nixtune's
                nixosModules.raspberry-pi-4 and this set over its default,
                or nixos-hardware's raspberry-pi-4 module.
        pi5     Raspberry Pi 5, 500 and Compute Module 5. With nixtune's
                nixosModules.raspberry-pi-5, or nixos-hardware's
                raspberry-pi-5 module.
        other   Anything that is not a Raspberry Pi: a PC, another board,
                a rehearsal VM.

        nixtune's raspberry-pi modules set this themselves.
      '';
    };

    audio = mkOption {
      type = types.enum [
        "dac2hd"
        "hifiberry"
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
                    hardware volume. The same as hifiberry with
                    hardware.hifiberry = "dac2hd".
        hifiberry   The HiFiBerry card hardware.hifiberry names. The
                    overlay, the ALSA card, the volume control and whether
                    MPD converts all come from that choice.
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

    hifiberry = mkOption {
      type = types.nullOr (types.enum cardNames);
      default = null;
      example = "dacplus-pro";
      description = ''
        With audio = "hifiberry": the card, by product.

        ${lib.concatMapStringsSep "\n" (n: "${n}: ${cards.${n}.products}") cardNames}

        Every card is ALSA card sndrpihifiberry. Only the DAC2 HD has played
        through nixtune; the rest are taken from the Raspberry Pi kernel's
        overlays and codec drivers. card.mixer replaces the card's volume
        control, and card.convert = true lets MPD convert, for a card that
        refuses some of the library's rates (MPD then fails to open the
        output). dac8x runs only on a Raspberry Pi 5.
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
          software volume. With audio = "headphones" or "hifiberry": the
          control's name, when it is not the one nixtune expects.
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
          With audio = "usb", "hat" or "hifiberry": let MPD resample and
          convert the format. Off keeps the path bit-perfect; turn it on
          for a card that refuses some of the library's rates or depths,
          which MPD reports as a failure to open the output. A HiFiBerry
          card whose chip is known to take fewer rates converts whatever
          this says.
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
            message = "services.nixtune.hardware.audio = \"headphones\" needs a board with a 3.5 mm jack: pi3 or pi4. The Zero 2 W, the 400 and the Pi 5 have none.";
          }
          {
            assertion = !(lib.elem hw.audio piOutputs) || board.raspberryPi;
            message = "services.nixtune.hardware.audio = \"${hw.audio}\" is a Raspberry Pi output; on another computer use \"usb\" or \"none\".";
          }
          {
            assertion = hw.audio != "hdmi" || !board.raspberryPi || hw.hdmiPort < board.hdmiPorts;
            message = "services.nixtune.hardware.hdmiPort = 1 needs a board with two HDMI ports, a Pi 4, 400 or 5; this board has one, which is port 0.";
          }
          {
            assertion = !(lib.elem hw.audio namedOutputs) || hw.card.id != null;
            message = "services.nixtune.hardware.audio = \"${hw.audio}\" needs hardware.card.id, the card's ALSA id from /proc/asound/cards.";
          }
          {
            assertion = hw.audio != "hifiberry" || hw.hifiberry != null;
            message = "services.nixtune.hardware.audio = \"hifiberry\" needs hardware.hifiberry, the card by product: ${lib.concatStringsSep ", " cardNames}.";
          }
          {
            assertion = hifiberry == null || !hifiberry.pi5Only || hw.board == "pi5";
            message = "services.nixtune.hardware.hifiberry = \"${toString hw.hifiberry}\" runs only on a Raspberry Pi 5; hardware.board is \"${hw.board}\".";
          }
        ];
      }

      (lib.mkIf onboardAudioOff {
        boot.blacklistedKernelModules = [ "snd_bcm2835" ];
      })

      # The build-time route, beside nixos-hardware or with no Pi layer at
      # all. Not on nixos-raspberrypi (see the top of this file).
      (lib.mkIf (audio.overlay != null && board.raspberryPi && !nixosRaspberrypi) {
        hardware.deviceTree.overlays = [
          {
            name = audio.overlay;
            dtboFile = dtbo;
          }
        ];
      })

      # nixos-hardware's config.txt. optionalAttrs, not mkIf alone: mkIf
      # keeps the attribute path in the definition, and a host without the
      # module would then fail with "option hardware.raspberry-pi does not
      # exist".
      (lib.optionalAttrs nixosHardware (
        lib.mkIf board.raspberryPi (
          lib.mkMerge [
            {
              # Chainload U-Boot from the GPU firmware. Without this the
              # firmware partition has no kernel line and the board never
              # boots.
              hardware.raspberry-pi.firmware.uboot.enable = lib.mkDefault true;

              # The card's overlay, and vc4-kms-v3d only for HDMI. This
              # replaces nixos-hardware's default list for [all], which is
              # vc4-kms-v3d alone; the firmware's framebuffer still gives an
              # HDMI console for debugging without it.
              hardware.raspberry-pi.configtxt.deviceTreeOverlays.all = configtxtOverlays;
            }
            (lib.mkIf onboardAudioOff {
              # Replaces nixos-hardware's default, [ "audio=on" ].
              hardware.raspberry-pi.configtxt.settings.all.dtparam = [ "audio=off" ];
            })
          ]
        )
      ))

      # nixos-raspberrypi's config.txt.
      (lib.optionalAttrs nixosRaspberrypi (
        lib.mkIf board.raspberryPi (
          lib.mkMerge [
            (lib.mkIf (audio.overlay != null) {
              hardware.raspberry-pi.config.all.dt-overlays.${audio.overlay} = {
                enable = true;
                params = lib.mapAttrs (_: on: { enable = on; }) audio.params;
              };
            })
            (lib.mkIf (!audio.hdmi) {
              hardware.raspberry-pi.config.all.dt-overlays.vc4-kms-v3d.params.noaudio.enable = true;
            })
            (lib.mkIf onboardAudioOff {
              # nixos-raspberrypi's configtxt.nix sets this value at normal
              # priority; 90 replaces it and still yields to a host's
              # mkForce.
              hardware.raspberry-pi.config.all.base-dt-params.audio = {
                enable = true;
                value = lib.mkOverride 90 "off";
              };
            })
          ]
        )
      ))
    ]
  );
}