# AirPlay through shairport-sync, straight to the card with the same
# hardware mixer MPD uses, so volume is one number everywhere. On a card
# with no control (HDMI) shairport-sync attenuates in software instead.
#
# ============================================================================
# AIRPLAY 2
# ============================================================================
#
# renderers.airplay.version = 2, the default, runs nixpkgs'
# shairport-sync-airplay2 with nixtune's port range patch
# (packages/shairport-sync) and NQPTP beside it. Version 1 runs nixpkgs'
# classic build alone, unpatched. What AirPlay 2 adds for a listener: the
# player shows up in the Home app and in multi-speaker AirPlay from an
# iPhone or a Mac, and buffered audio, which starts at once and rides out
# wifi gaps. What it does not add: high-resolution audio. Both versions
# carry 44.1 or 48 kHz, so AirPlay is never the bit-perfect path; MPD is.
#
# NQPTP keeps the PTP clock that AirPlay 2 timing is measured against and
# hands it to shairport-sync through POSIX shared memory (/nqptp, created
# mode 0666) and a control socket on 127.0.0.1:9000. It needs exclusive use
# of UDP 319 and 320, so nothing else on the host may run a PTP daemon. The
# unit follows upstream's nqptp.service (a DynamicUser given
# CAP_NET_BIND_SERVICE for those two ports, LimitRTPRIO 6), with the
# capability bounding set cut down to that one capability.
#
# The firewall. Classic AirPlay needs TCP 5000 and UDP 6001 to 6011, which
# the NixOS shairport-sync module opens for version 1. The AirPlay 2 build
# serves both protocols on TCP 7000: AirPlay 2 itself, and classic AirPlay
# for a sender that falls back to it, whose streams still take UDP 6001 to
# 6011 (rtp.c, bind_UDP_port). NQPTP needs UDP 319 and 320.
#
# AirPlay 2's own event, control and audio sockets are the reason for the
# patch. Upstream binds them to port 0 (rtsp.c, bind_socket_and_port), the
# kernel picks any free port in its ephemeral range, 32768 to 60999, and the
# sender connects to that port, so upstream's documented firewall rule
# (TROUBLESHOOTING.md) and hifiberry-nixos open the whole range, which
# exposes any other program on the host that listens on an ephemeral port.
# With the patch, airplay_2_port_base and airplay_2_port_range put those
# sockets in TCP and UDP 6200 to 6231. Those ports are below the kernel's
# ephemeral range, so the kernel never gives them to another program; only a
# program that asks for one of them by number can have it, and nothing else
# nixtune runs does. 32 ports leave room for a new sender to take over while
# the old session is still closing its sockets.
#
# ============================================================================
# ARBITRATION
# ============================================================================
#
# shairport-sync runs a hook before its first audio frame and another after
# its last. The first pauses MPD if it was playing and leaves a marker; the
# second resumes MPD only if the marker is there and
# arbitration.resumeAfterRenderer is set. MPD closes the ALSA device on
# pause (close_on_pause in mpd.nix), so the card is free when AirPlay opens
# it.
#
# The marker lives in shairport-sync's own RuntimeDirectory, which the unit
# owns, so no extra tmpfiles rule and nothing survives a reboot.
#
# With multiroom on, pausing MPD is the coordinator's job, because AirPlay
# in a source room must not pause the whole group (KnownIssue
# renderer_hooks_pause_group). The hooks tell the coordinator the
# interruption starts and ends, and it pauses and resumes MPD when the room
# is alone, as here. When the coordinator does not answer, the first hook
# falls back to pausing MPD itself, and the marker it leaves makes the
# second hook resume MPD itself, so a coordinator that is down never
# leaves AirPlay without the DAC.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.nixtune;
  out = cfg.output;
  airplay2 = cfg.renderers.airplay.version == 2;
  mpc = "${lib.getExe pkgs.mpc} --host 127.0.0.1 --port ${toString cfg.mpd.port}";
  mark = "/run/shairport-sync/nixtune-paused-mpd";
  multiroom = cfg.multiroom.enable;
  ctl = "${lib.getExe cfg.multiroom.package} ctl --socket /run/nixtune-room/control.sock";

  # AirPlay 2's own sockets, TCP and UDP alike. Below the kernel's ephemeral
  # range (32768 to 60999), and clear of MPD (6600) and classic AirPlay's UDP
  # 6001 to 6011.
  airplay2Ports = {
    from = 6200;
    to = 6231;
  };

  # Classic AirPlay's stream ports, which the AirPlay 2 build also uses for a
  # sender that falls back to it. The NixOS module's openFirewall opens the
  # same range for version 1.
  classicPorts = {
    from = 6001;
    to = 6011;
  };

  pauseMpd = ''
    if ${mpc} status | grep -q '^\[playing\]'; then
      touch ${mark}
      ${mpc} pause
    fi
  '';

  beforePlay = pkgs.writeShellApplication {
    name = "nixtune-airplay-before-play";
    runtimeInputs = [ pkgs.gnugrep ];
    text =
      if multiroom then
        ''
          if ! ${ctl} interruption-starts airplay; then
            ${pauseMpd}
          fi
        ''
      else
        pauseMpd;
  };

  resumeMpd = ''
    rm -f ${mark}
    ${lib.optionalString cfg.arbitration.resumeAfterRenderer "${mpc} play"}
  '';

  afterPlay = pkgs.writeShellApplication {
    name = "nixtune-airplay-after-play";
    text = ''
      if [ -e ${mark} ]; then
        ${resumeMpd}
      ${lib.optionalString multiroom "else ${ctl} interruption-ends airplay"}
      fi
    '';
  };
in
{
  config = lib.mkIf (cfg.enable && cfg.renderers.airplay.enable) (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = out.kind == "alsa";
            message = "services.nixtune.renderers.airplay needs a sound card; services.nixtune.hardware.audio is \"${cfg.hardware.audio}\".";
          }
        ];

        # The hooks reach the coordinator's control socket.
        users.users.${config.services.shairport-sync.user}.extraGroups = lib.mkIf multiroom [ "nixtune-room" ];

        services.shairport-sync = {
          enable = true;
          package =
            if airplay2 then
              pkgs.callPackage ../../packages/shairport-sync { }
            else
              pkgs.shairport-sync;
          # Version 1 only; version 2 opens its own ports below and has no
          # use for the module's TCP 5000.
          openFirewall = !airplay2;
          arguments = "-c /etc/shairport-sync.conf";
          settings = {
            general = {
              name = cfg.renderers.airplay.name;
              output_backend = "alsa";
              interpolation = "soxr";
            }
            // lib.optionalAttrs airplay2 {
              airplay_2_port_base = airplay2Ports.from;
              airplay_2_port_range = airplay2Ports.to - airplay2Ports.from + 1;
            };
            alsa = {
              output_device = out.device;
            }
            // lib.optionalAttrs (out.mixer != null) {
              mixer_control_name = out.mixer;
              mixer_device = "hw:CARD=${out.card}";
            };
            sessioncontrol = {
              run_this_before_play_begins = lib.getExe beforePlay;
              run_this_after_play_ends = lib.getExe afterPlay;
              wait_for_completion = "yes";
            };
            diagnostics.log_verbosity = 0;
          };
        };
      }

      (lib.mkIf airplay2 {
        systemd.services.nqptp = {
          description = "NQPTP, the PTP clock monitor for shairport-sync's AirPlay 2";
          documentation = [ "https://github.com/mikebrady/nqptp" ];
          wantedBy = [ "multi-user.target" ];
          wants = [ "network-online.target" ];
          after = [
            "network.target"
            "network-online.target"
          ];
          before = [ "shairport-sync.service" ];
          serviceConfig = {
            ExecStart = lib.getExe pkgs.nqptp;
            DynamicUser = true;
            LimitRTPRIO = 6;
            AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
            CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
            Restart = "on-failure";
          };
        };

        systemd.services.shairport-sync = {
          wants = [ "nqptp.service" ];
          after = [ "nqptp.service" ];
        };

        networking.firewall = {
          allowedTCPPorts = [ 7000 ];
          allowedUDPPorts = [
            319
            320
          ];
          allowedTCPPortRanges = [ airplay2Ports ];
          allowedUDPPortRanges = [
            airplay2Ports
            classicPorts
          ];
        };
      })
    ]
  );
}