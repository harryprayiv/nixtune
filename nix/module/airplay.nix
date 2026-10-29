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

  beforePlay = pkgs.writeShellApplication {
    name = "nixtune-airplay-before-play";
    runtimeInputs = [ pkgs.gnugrep ];
    text = ''
      if ${mpc} status | grep -q '^\[playing\]'; then
        touch ${mark}
        ${mpc} pause
      fi
    '';
  };

  afterPlay = pkgs.writeShellApplication {
    name = "nixtune-airplay-after-play";
    text = ''
      if [ -e ${mark} ]; then
        rm -f ${mark}
        ${lib.optionalString cfg.arbitration.resumeAfterRenderer "${mpc} play"}
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
