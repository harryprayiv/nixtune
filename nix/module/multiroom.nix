# Multiroom: services.nixtune.multiroom.*, specified in
# .inference/nixtune-multiroom.allium.
#
# Each room runs two services beside MPD:
#
#   nixtune-room    the coordinator and the room's Sendspin server, one
#                   process. It reads MPD's multiroom fifo and serves its
#                   control socket, both in /run/nixtune-room. Pages and
#                   peers reach it through nginx at /room.
#   nixtune-player  sendspin-cli's player on the DAC, listening on 8928 for
#                   the servers of the declared rooms and nothing else. Its
#                   credentials are written from the secret files before
#                   every start (rule PlayerCredentialsProvisioned).
#
# MPD gains a fifo output named "multiroom", off until the coordinator
# turns it on. A room alone keeps today's path exactly: MPD straight to
# the DAC (M4).
#
# Unlike the rest of the module, the options are declared here rather than
# in default.nix: they are one subsystem, off by default, and default.nix
# reads none of them.
#
# SECRETS. Every secret is a path at runtime to a file holding one
# base64url value, which is what `nixtune-room keys` writes and what a sops
# secret becomes. How the file gets onto the machine is the consumer's
# business, as with the wifi passphrase. The server's key and PSKs must be
# readable by the nixtune-room user, the player's by nixtune-player; with
# sops-nix that is `owner` on each secret.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption types;

  cfg = config.services.nixtune;
  mr = cfg.multiroom;
  out = cfg.output;

  roomName = types.strMatching "[a-z][a-z0-9-]*";
  key = types.strMatching "[A-Za-z0-9_-]{43}";

  peer = types.submodule {
    options = {
      host = mkOption {
        type = types.str;
        example = "lab.lan";
        description = "The room's host, as this room reaches it.";
      };
      port = mkOption {
        type = types.port;
        default = 80;
        description = "The port the room's page is served on, where nginx proxies /room to its coordinator.";
      };
      serverKey = mkOption {
        type = key;
        description = "The room's Sendspin server_id: its server's public key, as `nixtune-room keys` prints it.";
      };
      playerKey = mkOption {
        type = key;
        description = "The room's Sendspin client_id: its player's public key, as `nixtune-room keys` prints it.";
      };
      outputDelay = mkOption {
        type = types.ints.between 0 5000;
        default = 0;
        description = ''
          Milliseconds between the room's DAC output and the sound leaving
          its speakers. 0 for every room so far: no DSP anywhere in the
          chains.
        '';
      };
    };
  };

  # The coordinator's websocket, behind nginx at /room.
  roomPort = 8605;
  playerPort = 8928;
  runtimeDir = "/run/nixtune-room";
  controlSocket = "${runtimeDir}/control.sock";
  fifo = "${runtimeDir}/fifo";
  playerState = "/var/lib/nixtune-player";

  alsaOutputName = if out.kind == "alsa" then out.card else "null";

  # sendspin-cli finds its device among the ones PortAudio lists, by name
  # prefix; a bare hw:CARD=...,DEV=... name is not among them, and its
  # fallback for one needs aplay and then cannot check the stream's format
  # against the card. PortAudio does list the PCMs of the user's
  # ~/.asoundrc, so the player gets one, named nixtune, that is the card
  # MPD uses, with no plugin between them.
  playerAsoundrc = pkgs.writeText "nixtune-player-asoundrc" ''
    pcm.nixtune {
      type hw
      card "${toString mr.playerCard}"
      device ${toString mr.playerCardDevice}
    }
  '';

  roomJson = pkgs.writeText "room.json" (
    builtins.toJSON {
      room = mr.room;
      peers = lib.mapAttrs (_: p: {
        inherit (p) host port serverKey playerKey;
        path = "/room";
        outputDelayMs = p.outputDelay;
      }) mr.peers;
      acoustics = mr.acoustics;
      timing = {
        audienceGraceMs = mr.timing.audienceGrace;
        orphanTimeoutMs = mr.timing.orphanTimeout;
        playerReadyTimeoutMs = mr.timing.playerReadyTimeout;
        maxSuspensionMs = mr.timing.maxSuspension;
        reconcileIntervalMs = mr.timing.reconcileInterval;
        peerTimeoutMs = mr.timing.peerTimeout;
      };
      listen = {
        websocketHost = "127.0.0.1";
        websocketPort = roomPort;
        inherit controlSocket;
      };
      mpd = {
        host = "127.0.0.1";
        port = cfg.mpd.port;
        alsaOutput = alsaOutputName;
        fifoOutput = "multiroom";
      };
      secrets = {
        serverKey = mr.secrets.serverKeyFile;
        playerKey = mr.secrets.playerKeyFile;
        serverPsks = mr.secrets.serverPskFiles;
        playerPsks = mr.secrets.playerPskFiles;
      };
      sendspin = {
        inherit playerPort;
        playerPath = "/sendspin";
        inherit fifo;
        format = mr.streamFormat;
      };
    }
  );

  ctl = "${lib.getExe mr.package} ctl --socket ${controlSocket}";

  # The player's hooks carry the server_id. A declared room's server is a
  # peer the coordinator itself asked for, so there is nothing to do; any
  # other server is an interrupter. With unpaired access off and only the
  # declared rooms in the player's pairing store, no other server can get
  # this far yet; the interrupters option (stage 5) is what lets one.
  declaredServers = lib.concatStringsSep " " (lib.mapAttrsToList (_: p: p.serverKey) mr.peers);
  playerHook =
    event:
    pkgs.writeShellApplication {
      name = "nixtune-player-${event}";
      text = ''
        for known in ${declaredServers}; do
          if [ "''${SENDSPIN_SERVER_ID:-}" = "$known" ]; then
            exit 0
          fi
        done
        exec ${ctl} interruption-${event} foreign-sendspin
      '';
    };
in
{
  options.services.nixtune.multiroom = {
    enable = lib.mkEnableOption ''
      multiroom: this room can play another room's music in sync, and
      serve its own to other rooms, over Sendspin. Off contributes nothing
    '';

    package = mkOption {
      type = types.package;
      default = pkgs.callPackage ../../packages/nixtune-room { };
      defaultText = lib.literalExpression "nixtune's packages/nixtune-room, built with this host's pkgs";
      description = "nixtune-room: the coordinator and the room's Sendspin server.";
    };

    playerPackage = mkOption {
      type = types.package;
      default = pkgs.callPackage ../../packages/sendspin { };
      defaultText = lib.literalExpression "nixtune's packages/sendspin: sendspin-cli at the tested release, patched";
      description = "The Sendspin player. Its `sendspin daemon` is what runs.";
    };

    room = mkOption {
      type = roomName;
      default = config.networking.hostName;
      defaultText = lib.literalExpression "config.networking.hostName";
      example = "kitchen";
      description = "This room's name, which must be a key of peers.";
    };

    peers = mkOption {
      type = types.attrsOf peer;
      default = { };
      description = ''
        Every room in the home, this one included, by room name. The same
        attrset on every room: put it in a file the hosts share. The keys
        are what `nixtune-room keys --rooms a,b,c --out DIR` prints.
      '';
    };

    acoustics = mkOption {
      type = types.attrsOf (types.attrsOf (types.ints.between 0 5000));
      default = { };
      example = {
        kitchen.lab = 9;
      };
      description = ''
        acoustics.<focus>.<room>: milliseconds of travel from <room>'s
        speakers to the listening spot in <focus>. Rooms that cannot be
        heard from <focus> are left out. Found by calibration, then
        declared here, identically on every room.
      '';
    };

    streamFormat = mkOption {
      type = types.enum [
        "44100:24:2"
        "48000:24:2"
        "44100:16:2"
        "48000:16:2"
      ];
      default = "44100:24:2";
      description = ''
        What MPD resamples to in group mode only, streamed as PCM (M19).
        44.1 kHz because most of the library is 44.1 kHz and is then not
        resampled; 24 bits so 16-bit files pass through unchanged.
      '';
    };

    playerCard = mkOption {
      type = types.nullOr types.str;
      default = out.card;
      defaultText = lib.literalExpression "config.services.nixtune.output.card";
      description = ''
        The ALSA card id the player opens: the DAC MPD uses, which the two
        never hold at once. A rehearsal VM with no sound card points this
        at snd-aloop's "Loopback".
      '';
    };

    playerCardDevice = mkOption {
      type = types.ints.unsigned;
      default = 0;
      description = "The PCM device number on playerCard.";
    };

    secrets = {
      serverKeyFile = mkOption {
        type = types.str;
        example = "/run/secrets/nixtune-room/server-key";
        description = "This room's server private key. Readable by nixtune-room.";
      };
      playerKeyFile = mkOption {
        type = types.str;
        example = "/run/secrets/nixtune-room/player-key";
        description = "This room's player private key. Readable by nixtune-player.";
      };
      serverPskFiles = mkOption {
        type = types.attrsOf types.str;
        default = { };
        example = lib.literalExpression ''{ lab = "/run/secrets/nixtune-room/server-psk/lab"; }'';
        description = ''
          For every room in peers, this one included: the PSK this room's
          server shares with that room's player. Readable by nixtune-room.
        '';
      };
      playerPskFiles = mkOption {
        type = types.attrsOf types.str;
        default = { };
        example = lib.literalExpression ''{ lab = "/run/secrets/nixtune-room/player-psk/lab"; }'';
        description = ''
          For every room in peers, this one included: the PSK this room's
          player shares with that room's server. Readable by nixtune-player.
        '';
      };
    };

    timing = {
      audienceGrace = mkOption {
        type = types.ints.positive;
        default = 10000;
        description = "Milliseconds a source keeps its server path after its last follower leaves.";
      };
      orphanTimeout = mkOption {
        type = types.ints.positive;
        default = 180000;
        description = "Milliseconds a follower waits for an unreachable source before going back to its own queue. Longer than a Pi takes to reboot.";
      };
      playerReadyTimeout = mkOption {
        type = types.ints.positive;
        default = 10000;
        description = "Milliseconds a hold waits for the player to report itself available.";
      };
      maxSuspension = mkOption {
        type = types.ints.positive;
        default = 1800000;
        description = "Milliseconds a source keeps an interrupted follower in its audience.";
      };
      reconcileInterval = mkOption {
        type = types.ints.positive;
        default = 2000;
        description = "Milliseconds between a coordinator's checks of what is against what it intends.";
      };
      peerTimeout = mkOption {
        type = types.ints.positive;
        default = 2000;
        description = "Milliseconds a coordinator waits for another room to answer.";
      };
    };
  };

  config = lib.mkMerge [
    {
      services.nixtune.persistPaths = lib.mkIf mr.enable [ playerState ];
    }

    (lib.mkIf (cfg.enable && mr.enable) {
      assertions = [
        {
          assertion = mr.peers ? ${mr.room};
          message = "services.nixtune.multiroom.peers must include this room, ${mr.room}.";
        }
        {
          assertion = mr.playerCard != null;
          message = "services.nixtune.multiroom needs a card for the player; with hardware.profile \"none\" set multiroom.playerCard.";
        }
        {
          assertion = cfg.ui.enable;
          message = "services.nixtune.multiroom reaches other rooms through the page's nginx at /room; services.nixtune.ui.enable must be true.";
        }
        {
          assertion = lib.attrNames mr.secrets.serverPskFiles == lib.attrNames mr.peers;
          message = "services.nixtune.multiroom.secrets.serverPskFiles needs exactly one file per room in peers.";
        }
        {
          assertion = lib.attrNames mr.secrets.playerPskFiles == lib.attrNames mr.peers;
          message = "services.nixtune.multiroom.secrets.playerPskFiles needs exactly one file per room in peers.";
        }
      ];

      users.groups.nixtune-room = { };
      users.users.nixtune-room = {
        isSystemUser = true;
        group = "nixtune-room";
        description = "nixtune multiroom coordinator";
      };
      users.users.nixtune-player = {
        isSystemUser = true;
        group = "nixtune-room";
        extraGroups = [ "audio" ];
        home = playerState;
        description = "nixtune Sendspin player";
      };
      # MPD writes the fifo, 0660 in a 0750 directory, both nixtune-room's.
      users.users.${config.services.mpd.user}.extraGroups = [ "nixtune-room" ];

      # MPD sets up its fifo output when it starts, enabled or not, and
      # makes the fifo itself when the path is missing, failing outright
      # when the directory is. MPD starts before nixtune-room, so the
      # directory and the fifo are made at boot rather than by either
      # service. A fifo MPD finds already there, MPD never removes. Not a
      # RuntimeDirectory of nixtune-room, which systemd would delete,
      # fifo included, every time that unit stops.
      systemd.tmpfiles.rules = [
        "d ${runtimeDir} 0750 nixtune-room nixtune-room -"
        "p ${fifo} 0660 nixtune-room nixtune-room -"
      ];

      services.mpd.settings.audio_output = lib.mkAfter [
        {
          type = "fifo";
          name = "multiroom";
          path = fifo;
          format = mr.streamFormat;
          # The coordinator turns it on when the room's first follower
          # arrives and off after the last leaves (RoomBoots, M4).
          enabled = "no";
        }
      ];

      systemd.services.nixtune-room = {
        description = "nixtune: multiroom coordinator and Sendspin server";
        wantedBy = [ "multi-user.target" ];
        after = [
          "mpd.service"
          "network-online.target"
        ];
        wants = [ "network-online.target" ];
        requires = [ "mpd.service" ];
        serviceConfig = {
          ExecStart = "${lib.getExe mr.package} run --config ${roomJson}";
          User = "nixtune-room";
          Group = "nixtune-room";
          # ProtectSystem=strict makes /run read-only; the control socket
          # is created here.
          ReadWritePaths = [ runtimeDir ];
          UMask = "0007";
          Restart = "always";
          RestartSec = 2;
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          PrivateDevices = true;
          RestrictAddressFamilies = [
            "AF_UNIX"
            "AF_INET"
            "AF_INET6"
          ];
        };
      };

      systemd.services.nixtune-player = {
        description = "nixtune: Sendspin player on the DAC";
        wantedBy = [ "multi-user.target" ];
        after = [
          "nixtune-room.service"
          "sound.target"
          "network-online.target"
        ];
        wants = [ "network-online.target" ];
        # PortAudio leaves out a card it cannot open while listing devices,
        # so the player cannot start while MPD plays on the DAC (KnownIssue
        # player_starts_only_with_dac_free). It keeps retrying instead of
        # hitting systemd's start limit.
        startLimitIntervalSec = 0;
        environment.HOME = playerState;
        serviceConfig = {
          ExecStartPre = [
            # Written fresh from the secret files before every start, so
            # the player's own store never drifts from the declaration.
            "${lib.getExe mr.package} provision-player --config ${roomJson} --state-dir ${playerState}"
            "${pkgs.coreutils}/bin/ln -sfn ${playerAsoundrc} ${playerState}/.asoundrc"
          ];
          ExecStart = lib.concatStringsSep " " [
            "${mr.playerPackage}/bin/sendspin daemon"
            "--settings-dir ${playerState}"
            "--name ${mr.room}"
            "--port ${toString playerPort}"
            "--audio-device nixtune"
            "--audio-format pcm:${mr.streamFormat}"
            "--output-delay-ms ${toString mr.peers.${mr.room}.outputDelay}"
            # sendspin-cli's hardware volume mutes the DAC2 HD; the
            # volume is MPD's, written by volume.nix.
            "--hardware-volume false"
            "--unpaired-access false"
            "--disable-mpris"
            "--hook-start ${lib.getExe (playerHook "starts")}"
            "--hook-stop ${lib.getExe (playerHook "ends")}"
          ];
          User = "nixtune-player";
          Group = "nixtune-room";
          StateDirectory = "nixtune-player";
          StateDirectoryMode = "0700";
          Restart = "always";
          RestartSec = 2;
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
        };
      };

      services.nginx.virtualHosts.nixtune.locations."/room" = {
        proxyPass = "http://127.0.0.1:${toString roomPort}";
        proxyWebsockets = true;
        extraConfig = ''
          proxy_read_timeout 1h;
        '';
      };

      # The player is reached by the other rooms' servers. Noise with
      # per-pair PSKs is what keeps anything else out.
      networking.firewall.allowedTCPPorts = [ playerPort ];

      environment.systemPackages = [ mr.package ];
    })
  ];
}