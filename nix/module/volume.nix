# Writing the hardware volume, because MPD cannot write this one.
#
# ============================================================================
# WHY THIS EXISTS
# ============================================================================
#
# MPD's ALSA mixer reads the control correctly and reports every change
# through its "mixer" idle event, which is how the page learns the level.
# Its WRITES are the problem. MPD sets volume through
# snd_mixer_selem_set_playback_dB_all (src/mixer/plugins/VolumeMapping.cxx),
# and it takes that path whenever the control's dB range is wider than 24 dB,
# which the HiFiBerry DAC2 HD's is: 0 to 240 in 0.5 dB steps, 120 dB, with
# raw 0 reported as the TLV mute sentinel. On this card every setvol through
# that path lands on raw 0, which is a hard mute, and once muted it stays
# muted. Measured on 2026-10-30: five consecutive setvol commands at 30, 60,
# 90, 40 and 75 all left the control at 0 and MPD reporting 0%.
#
# The same card takes writes without complaint from amixer, both the raw
# form and the mapped form, and they hold. So the DAC and the driver are
# fine and MPD's write path is not usable here.
#
# This is the split moOde uses, without moOde's database or PHP: MPD keeps
# the mixer for reading, and writes go through a helper that performs the
# same mapped write amixer does. The page sends one line per change to a
# websocket, nginx hands it to websocat, websocat opens a TCP connection,
# and systemd socket activation runs the script below for that connection.
#
# The scale is the one MPD reports, so the number the page sends and the
# number MPD sends back mean the same thing: amixer -M and MPD both use
# ALSA's normalized mapping, where the percentage is 10^(dB/60). 100 is
# 0 dB, 70 is -9.5 dB, 50 is -18 dB, 25 is -36 dB, and 0 is mute.
#
# ============================================================================
# WHO CAN USE IT
# ============================================================================
#
# Anyone who can reach the page. That is the same reach the MPD websocket
# already has, where a guest can queue and skip tracks, so this adds no
# access that was not there. It is not a credential boundary and it is not
# meant to be one.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.nixtune;
  out = cfg.output;

  # Only when there is a real card to write to. With the null output MPD's
  # software mixer works properly and the page keeps using setvol.
  enabled = cfg.enable && cfg.ui.enable && out.kind == "alsa";

  socketPort = 8601;
  bridgePort = 8602;

  helper = pkgs.writeShellApplication {
    name = "nixtune-volume";
    runtimeInputs = [
      pkgs.alsa-utils
      pkgs.gawk
      pkgs.coreutils
    ];
    text = ''
      card_id=${lib.escapeShellArg out.card}
      control=${lib.escapeShellArg out.mixer}

      # amixer wants the card's index. Resolving it from /proc/asound/cards
      # rather than passing the id to -c, which only resolves through
      # alsa-lib's config and reports a missing control device as an
      # invalid card number.
      card=$(awk -v id="$card_id" '$0 ~ "\\[" id "[ ]*\\]" { print $1; exit }' /proc/asound/cards)
      if [ -z "$card" ]; then
        echo "err no card called $card_id"
        exit 1
      fi

      # One line per request: "set N", N from 0 to 100 on MPD's scale. A
      # line that is not understood is answered and ignored, so a stray
      # message cannot move the volume.
      while read -r verb value rest; do
        if [ -n "$rest" ] || [ "$verb" != "set" ]; then
          echo "err expected: set N"
          continue
        fi
        case "$value" in
          "" | *[!0-9]*)
            echo "err not a number: $value"
            continue
            ;;
        esac
        if [ "$value" -gt 100 ]; then
          echo "err out of range: $value"
          continue
        fi
        if amixer -M -c "$card" sset "$control" "$value%" >/dev/null 2>&1; then
          echo "ok $value"
        else
          echo "err amixer failed"
        fi
      done
    '';
  };
in
{
  options.services.nixtune.volume.path = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    readOnly = true;
    internal = true;
    default = if enabled then "/volume" else null;
    description = ''
      Where the page sends volume changes, or null when MPD's own mixer is
      used. Read by ui.nix for capabilities.json.
    '';
  };

  config = lib.mkIf enabled {
    systemd.sockets.nixtune-volume = {
      description = "nixtune: volume helper socket";
      wantedBy = [ "sockets.target" ];
      socketConfig = {
        ListenStream = "127.0.0.1:${toString socketPort}";
        Accept = "yes";
      };
    };

    systemd.services."nixtune-volume@" = {
      description = "nixtune: write the hardware volume";
      serviceConfig = {
        ExecStart = lib.getExe helper;
        StandardInput = "socket";
        StandardOutput = "socket";
        StandardError = "journal";
        DynamicUser = true;
        # The control device is owned by the audio group, and over a
        # network login there is no seat for logind to grant an ACL to.
        SupplementaryGroups = [ "audio" ];
        DeviceAllow = [ "char-alsa rw" ];
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateNetwork = false;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
        ];
      };
    };

    # One browser websocket to one TCP connection, which socket activation
    # turns into one run of the helper.
    systemd.services.nixtune-volume-ws = {
      description = "nixtune: websocket to the volume helper";
      wantedBy = [ "multi-user.target" ];
      after = [ "nixtune-volume.socket" ];
      wants = [ "nixtune-volume.socket" ];
      serviceConfig = {
        ExecStart = "${lib.getExe pkgs.websocat} -t -E ws-l:127.0.0.1:${toString bridgePort} tcp:127.0.0.1:${toString socketPort}";
        Restart = "always";
        RestartSec = 2;
        DynamicUser = true;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
      };
    };

    services.nginx.virtualHosts.nixtune.locations."/volume" = {
      proxyPass = "http://127.0.0.1:${toString bridgePort}";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_read_timeout 1h;
      '';
    };
  };
}