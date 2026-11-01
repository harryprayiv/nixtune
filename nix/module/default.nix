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
#   volume.nix     writing the hardware volume, which MPD cannot do on this
#                  card
#   art.nix        pulling cover art out of the files into a served cache
#   ui.nix         nginx, websocat, capabilities.json, the page
#   youtube.nix    fetching a YouTube track into the library and queueing it
#   airplay.nix    shairport-sync and the arbitration hooks
#   upnp.nix       upmpdcli
#   multiroom.nix  services.nixtune.multiroom: the coordinator, the room's
#                  Sendspin server and player. It declares its own
#                  options, being one subsystem that nothing here reads.
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
    ./volume.nix
    ./art.nix
    ./ui.nix
    ./youtube.nix
    ./airplay.nix
    ./upnp.nix
    ./multiroom.nix
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
      maxOutputBuffer = mkOption {
        type = types.str;
        default = "32768";
        description = ''
          MPD's max_output_buffer_size, in kilobytes. MPD assembles a
          reply in one buffer and closes the client when the reply will
          not fit; the default of 8192 is exceeded by `listall` over a
          library of seventy thousand tracks. The buffer grows on demand,
          so a larger ceiling costs nothing until a reply needs it.
        '';
      };
      consume = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = ''
          Consume mode at every MPD start, or null to leave whatever was
          last chosen.

          MPD remembers consume, random, repeat and single in its state
          file across restarts, so null means a change made on the page
          survives a reboot. A value here overrides that remembered state
          on every start, which is what makes it a default rather than a
          preference: with true, a queue is a list of things waiting to be
          played and each one leaves as it finishes, and the page's
          Consume toggle still turns it off until the next start.
        '';
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
      albumArt = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Show cover art beside what is playing.

          art.nix builds a cache: one cover.jpg per album directory, taken
          from a picture file beside the audio when there is one and pulled
          out of the tags with ffmpeg when there is not, since most
          libraries keep the cover inside the files. nginx serves that
          cache and nothing else, so no audio is reachable over HTTP. The
          first scan over a large library runs for a while at idle
          priority; afterwards only changed album directories cost
          anything.
        '';
      };
      albumArtSize = mkOption {
        type = types.ints.between 64 4096;
        default = 600;
        description = ''
          The longest edge, in pixels, a cached cover is scaled down to. A
          picture already smaller than this is left alone. 600 is about
          twice what the page draws on a phone, so it still looks right on
          a desktop and on a high-density screen.
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

    party = {
      enable = lib.mkEnableOption ''
        party mode.

        The guest page gains the queue, read only, with a veto button on
        each entry. A guest's vote is written as an MPD sticker on the
        track's URI, so every browser sees the same count without
        anything on the player keeping score, and when the count reaches
        party.vetoes the track leaves the queue and its votes are
        cleared.

        This adds no security and removes none. The guest page already
        reaches the same websocket as the host page, so this is about
        what the page OFFERS a guest, not about what the player permits.
        A vote is one per browser per track, named by the nickname that
        browser made up for itself, and anyone who clears their browser
        storage votes again under a new name. For a room of invited
        people that is the right trade. It is not a voting system and
        should not be mistaken for one
      '';
      vetoes = mkOption {
        type = types.ints.positive;
        default = 3;
        description = ''
          How many distinct guests have to vote against a track before it
          leaves the queue.
        '';
      };
    };

    youtube = {
      enable = lib.mkEnableOption ''
        queueing tracks from a YouTube link.

        The host page gains a field for a YouTube video or playlist link.
        The player fetches the audio with yt-dlp into youtube.directory, a
        folder inside the library export on the NAS, has MPD index it, and
        adds it to the end of the queue: one track for a video, the
        playlist's tracks in order for a playlist. youtube.nix describes
        what the helper will and will not run.

        The folder has to exist on the NAS before the first fetch, and the
        export has to let this host write to it: either the export maps all
        users to admin, or the nixtune-youtube user's uid can write to the
        folder
      '';
      directory = mkOption {
        type = types.strMatching "[A-Za-z0-9_][A-Za-z0-9_.-]*";
        default = "_youtube";
        description = ''
          The folder the downloads go to, at the top of the library export:
          library.export with this appended is mounted read-write, and the
          tracks appear in MPD under this name. One path component, no
          spaces.
        '';
      };
      package = mkOption {
        type = types.package;
        default = pkgs.yt-dlp;
        defaultText = lib.literalExpression "pkgs.yt-dlp";
        description = ''
          The yt-dlp to run. YouTube changes what yt-dlp has to do every few
          weeks, so when fetches start failing with extractor errors, point
          this at a newer build or update the flake.
        '';
      };
      maxMinutes = mkOption {
        type = types.ints.between 1 600;
        default = 20;
        description = "The longest video, in minutes, the helper will fetch. Live streams are refused whatever this is.";
      };
      maxSize = mkOption {
        type = types.strMatching "[0-9]+[KMG]";
        default = "300M";
        description = "The largest audio stream the helper will download, in yt-dlp's notation.";
      };
      artist = mkOption {
        type = types.strMatching "[A-Za-z0-9][A-Za-z0-9 ._-]*";
        default = "YouTube";
        description = ''
          The album artist every download is tagged with. The page pins this
          row to the top of its artist column, so the downloads are one
          place to look until they are retagged. Letters, digits, spaces,
          dots, underscores and hyphens.
        '';
      };
      maxPlaylistItems = mkOption {
        type = types.ints.between 1 500;
        default = 50;
        description = ''
          How many videos of a playlist link the helper fetches, from the
          top. The limits above apply to each of them. The videos are fetched
          one after another, so a long playlist fills the queue over minutes.
        '';
      };
    };

    arbitration.resumeAfterRenderer = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Resume MPD when a renderer that paused it stops streaming. With
        multiroom on, AirPlay's pause and resume go through the
        coordinator, which resumes what it paused; this then applies only
        when the coordinator did not answer and the hook paused MPD itself.
      '';
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
    # Not readOnly: more than one part owns state, and each declares its
    # own, so the definitions merge into one list for the consumer to read.
    persistPaths = mkOption {
      type = types.listOf types.str;
      default = [ ];
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