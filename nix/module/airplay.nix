# AirPlay through shairport-sync, straight to the DAC with the same hardware
# mixer MPD uses, so volume is one number everywhere.
#
# Arbitration: shairport-sync runs a hook before its first audio frame and
# another after its last. The first pauses MPD if it was playing and leaves a
# marker; the second resumes MPD only if the marker is there and
# arbitration.resumeAfterRenderer is set. MPD closes the ALSA device on pause
# (close_on_pause in mpd.nix), so the card is free when AirPlay opens it.
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
  mpc = "${lib.getExe pkgs.mpc} --host 127.0.0.1 --port ${toString cfg.mpd.port}";
  mark = "/run/shairport-sync/nixtune-paused-mpd";
  multiroom = cfg.multiroom.enable;
  ctl = "${lib.getExe cfg.multiroom.package} ctl --socket /run/nixtune-room/control.sock";

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
  config = lib.mkIf (cfg.enable && cfg.renderers.airplay.enable) {
    assertions = [
      {
        assertion = out.kind == "alsa";
        message = "services.nixtune.renderers.airplay needs a sound card; services.nixtune.hardware.profile is \"${cfg.hardware.profile}\".";
      }
    ];

    # The hooks reach the coordinator's control socket.
    users.users.${config.services.shairport-sync.user}.extraGroups = lib.mkIf multiroom [ "nixtune-room" ];

    services.shairport-sync = {
      enable = true;
      openFirewall = true;
      arguments = "-c /etc/shairport-sync.conf";
      settings = {
        general = {
          name = cfg.renderers.airplay.name;
          output_backend = "alsa";
          interpolation = "soxr";
        };
        alsa = {
          output_device = out.device;
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
  };
}