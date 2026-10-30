# nixtune: a network music player as one NixOS module.
#
# MPD on a DAC through ALSA with hardware volume and nothing else in the
# chain; AirPlay and UPnP renderers as sub-options that are off by default;
# a Halogen page (packages/nixtune-web) that speaks the MPD protocol over a
# websocket. There is no settings database and no settings page: the options
# below are the configuration, and changing them means a new generation with
# the previous one a reboot away.
#
# This file declares every option and the wiring that is not one service.
# The parts live beside it:
#
#   hardware.nix   board and DAC facts per profile, the device tree overlay
#   mpd.nix        the daemon on the card
#   library.nix    the NFS export, mounted read-only at /srv/music
#   database.nix   what MPD indexes, and dropping its database when the
#                  export changes
#   ui.nix         nginx, websocat, capabilities.json, the page
#   airplay.nix    shairport-sync and the arbitration hooks
#   upnp.nix       upmpdcli
#
# The module knows nothing about where its inputs come from. The wifi
# passphrase is a path to an environment file; how that file gets onto the
# machine (sops, agenix, a file copied by hand) is the consumer's business.
# The library is one "host:/export" string. What the module needs kept
# across a root wipe is published as services.nixtune.persistPaths for an
# impermanence setup to read.
#
# ============================================================================
# THE WIFI SECRET
# ============================================================================
#
# The passphrase is an ENVIRONMENT FILE, not a bare value, because
# NetworkManager's ensureProfiles runs envsubst over the keyfile with that
# file loaded. The file holds one line:
#   PSK=the-passphrase
# and the profile refers to $PSK. An SSID with no pskFile writes no profile
# and warns, so a machine can be built and booted on ethernet before the
# secret exists.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption types;

  cfg = config.services.nixtune;

  wantWifi = cfg.wifi.ssid != null;
  haveWifi = wantWifi && cfg.wifi.pskFile != null;

  station = types.submodule {
    options = {
      name = mkOption {
        type = types.str;
        description = "Name shown on the page.";
      };
      url = mkOption {
        type = types.str;
        description = "Stream URL handed to MPD.";
      };
    };
  };
in
{
  imports = [
    ./hardware.nix
    ./mpd.nix
    ./library.nix
    ./database.nix
    ./ui.nix
    ./airplay.nix
    ./upnp.nix
  ];

  options.services.nixtune = {
    enable = lib.mkEnableOption "nixtune, the network music player";

    hardware.profile = mkOption {
      type = types.enum [
        "pi5-dac2hd"
        "none"
      ];
      default = "pi5-dac2hd";
      description = ''
        The board and DAC this host is built for.

        pi5-dac2hd  Raspberry Pi 5 with a HiFiBerry DAC2 HD. Device tree
                    overlay, ALSA card name and hardware mixer come from
                    hardware.nix. Needs the Raspberry Pi kernel, which
                    nixos-hardware's raspberry-pi-5 module provides.
        none        No sound card. MPD plays into a null output. For a
                    rehearsal VM, where everything but the DAC is exercised.
      '';
    };

    library.export = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "192.168.1.10:/volume1/music";
      description = ''
        The NFS export holding the library, as host:/path. Null means no
        library: radio and renderers only. Mounted read-only at /srv/music
        by library.nix, with nofail and automount, so a NAS that is down does
        not block boot.
      '';
    };

    wifi = {
      ssid = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "The network the player joins over wifi. Null means wired only.";
      };
      pskFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "/run/secrets/wifi-psk";
        description = ''
          Path, at runtime, to an environment file holding PSK=<passphrase>.
          Not a Nix path: its contents must never enter the store. With an
          ssid and no pskFile the profile is not written and a warning says
          so.
        '';
      };
    };

    mpd = {
      port = mkOption {
        type = types.port;
        default = 6600;
      };
      exposeOnLan = mkOption {
        type = types.bool;
        default = false;
        description = "Let MPD clients on the LAN connect directly, in addition to the page.";
      };
      maxVolume = mkOption {
        type = types.ints.between 0 100;
        default = 100;
        description = "Upper bound the page allows for the volume.";
      };
    };

    radio.stations = mkOption {
      type = types.listOf station;
      default = [ ];
      description = "Stations offered on the page.";
    };

    ui = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Serve the page.";
      };
      package = mkOption {
        type = types.package;
        default = pkgs.callPackage ../../packages/nixtune-web { };
        defaultText = lib.literalExpression "nixtune's packages/nixtune-web, built with this host's pkgs";
        description = "The built page: a directory with index.html at its root.";
      };
      port = mkOption {
        type = types.port;
        default = 80;
      };
      publicUrl = mkOption {
        type = types.str;
        default = "http://${config.networking.hostName}.lan/";
        defaultText = lib.literalExpression ''"http://''${config.networking.hostName}.lan/"'';
        description = ''
          The address the QR code on the host page encodes: how a guest's
          phone reaches the guest page. A name the LAN's DNS resolves, or
          an address with a reservation behind it.
        '';
      };
      hostPath = mkOption {
        type = types.strMatching "/.+";
        default = "/host";
        description = ''
          The path that opens the page in the host role, with the queue,
          transport, volume and the QR. Every other path is the guest
          page. A convention the page honours, not a credential: both
          roles reach the same websocket to MPD.
        '';
      };
    };

    arbitration.resumeAfterRenderer = mkOption {
      type = types.bool;
      default = true;
      description = "Resume MPD when a renderer that paused it stops streaming.";
    };

    renderers = {
      airplay = {
        enable = lib.mkEnableOption "AirPlay through shairport-sync";
        name = mkOption {
          type = types.str;
          default = config.networking.hostName;
          defaultText = lib.literalExpression "config.networking.hostName";
          description = "Name advertised to AirPlay senders.";
        };
      };
      upnp = {
        enable = lib.mkEnableOption "a UPnP renderer through upmpdcli";
        friendlyName = mkOption {
          type = types.str;
          default = config.networking.hostName;
          defaultText = lib.literalExpression "config.networking.hostName";
        };
        package = mkOption {
          type = types.package;
          default = pkgs.callPackage ../../packages/upmpdcli.nix { };
          defaultText = lib.literalExpression "nixtune's packages/upmpdcli.nix, built with this host's pkgs";
          description = "upmpdcli, which nixpkgs does not carry.";
        };
      };
    };

    # What nixtune writes and expects to find again after a reboot. Read by
    # an impermanence setup; nixtune itself does nothing with it.
    persistPaths = mkOption {
      type = types.listOf types.str;
      readOnly = true;
      description = "Directories holding nixtune's state. Set by the parts that own them.";
    };

    # Set by hardware.nix from the profile; read by the other files.
    output = {
      kind = mkOption {
        type = types.enum [
          "alsa"
          "null"
        ];
        readOnly = true;
        internal = true;
      };
      card = mkOption {
        type = types.nullOr types.str;
        readOnly = true;
        internal = true;
      };
      device = mkOption {
        type = types.nullOr types.str;
        readOnly = true;
        internal = true;
      };
      mixer = mkOption {
        type = types.nullOr types.str;
        readOnly = true;
        internal = true;
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Wifi needs NetworkManager; the profile below is written through it.
    # mkDefault, so a host that already made that choice keeps it.
    networking.networkmanager.enable = lib.mkIf wantWifi (lib.mkDefault true);

    # A Pi 5 on wifi with powersave on drops off the network for seconds at
    # a time, which a stream notices and a phone's AirPlay sender notices
    # more. Off the moment a wifi SSID is declared.
    networking.networkmanager.wifi.powersave = lib.mkIf wantWifi false;

    networking.networkmanager.ensureProfiles = lib.mkIf haveWifi {
      environmentFiles = [ cfg.wifi.pskFile ];
      profiles.${cfg.wifi.ssid} = {
        connection = {
          id = cfg.wifi.ssid;
          type = "wifi";
          autoconnect = true;
        };
        wifi = {
          mode = "infrastructure";
          ssid = cfg.wifi.ssid;
        };
        wifi-security = {
          key-mgmt = "wpa-psk";
          psk = "$PSK";
        };
        ipv4.method = "auto";
        ipv6 = {
          method = "auto";
          addr-gen-mode = "stable-privacy";
        };
      };
    };

    assertions = [
      {
        assertion = wantWifi -> config.networking.networkmanager.enable;
        message = "services.nixtune.wifi.ssid is set but networking.networkmanager.enable is false; the wifi profile is written through NetworkManager.";
      }
    ];

    warnings = lib.optional (wantWifi && !haveWifi) ''
      ${config.networking.hostName}: services.nixtune.wifi.ssid is set and
      services.nixtune.wifi.pskFile is null, so no wifi profile is written
      and the player is reachable over ethernet only. Provide the PSK file
      (one line, PSK=<passphrase>) and rebuild.
    '';

    environment.systemPackages = [
      pkgs.alsa-utils
      pkgs.mpc
    ];
  };
}