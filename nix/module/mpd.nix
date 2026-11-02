# MPD on the card hardware.nix chose. On a DAC: hardware volume and nothing
# between the decoder and the card. On the Pi's headphone jack or HDMI: MPD
# converts to what the output takes, and on HDMI sets the level itself.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.nixtune;
  out = cfg.output;

  # The NFS library mounts at /srv/music, outside MPD's StateDirectory. The
  # mpd module turns a music_directory under /var/lib/mpd into a systemd
  # StateDirectory, and systemd then chowns it on every start, which fails on
  # an NFS export that squashes root and takes the unit down with it.
  musicDirectory = if cfg.library.export != null then "/srv/music" else "/var/lib/mpd/music";

  yesNo = b: if b then "yes" else "no";

  # With a control on the card, the card sets the level. Without one, MPD
  # scales the samples, which is the only volume HDMI has.
  mixer =
    if out.mixer != null then
      {
        mixer_type = "hardware";
        mixer_device = "hw:CARD=${out.card}";
        mixer_control = out.mixer;
      }
    else
      { mixer_type = "software"; };

  alsaOutput = mixer // {
    type = "alsa";
    name = out.card;
    device = out.device;
    # A DAC takes what the file is: no resampling, no channel or format
    # conversion. The headphone jack (16 bits, 48 kHz at most) and HDMI
    # (the iec958 plugin's formats) do not, and with these off MPD fails to
    # open them for most of a library; hardware.nix says which is which.
    auto_resample = yesNo out.convert;
    auto_channels = yesNo out.convert;
    auto_format = yesNo out.convert;
    # Release the device on pause so a renderer can open it. The
    # arbitration hooks in airplay.nix depend on this.
    close_on_pause = "yes";
  };

  nullOutput = {
    type = "null";
    name = "null";
    mixer_type = "software";
  };
in
{
  config = lib.mkMerge [
    {
      # Published whether or not nixtune is enabled, so a consumer can read
      # it unconditionally.
      services.nixtune.persistPaths = [ "/var/lib/mpd" ];
    }

    (lib.mkIf cfg.enable {
      services.mpd = {
        enable = true;
        openFirewall = cfg.mpd.exposeOnLan;
        settings = {
          bind_to_address = if cfg.mpd.exposeOnLan then "any" else "127.0.0.1";
          port = cfg.mpd.port;
          music_directory = musicDirectory;
          # NOT auto_update. With it on, MPD walks the whole music tree
          # installing an inotify watch per directory, on its main thread,
          # before it reports ready to systemd (mpd_inotify_init runs
          # before sd_notify in Main.cxx). On the first boot against the
          # NAS that walk outlasted the start timeout and systemd killed
          # MPD mid-scan. The watches would also never fire: the kernel
          # emits inotify events for local writes only, and the library
          # is written on the NAS. library.nix rescans on a timer instead.
          auto_update = false;
          restore_paused = true;
          # MPD builds a reply in one buffer and drops the client when the
          # reply does not fit. The default is 8 MB, which `listall` over a
          # library of this size exceeds, and which the tag browser's
          # unfiltered `list artist` could reach on a large enough
          # collection. Raising it costs nothing until a reply is actually
          # that large, because the buffer grows on demand.
          max_output_buffer_size = cfg.mpd.maxOutputBuffer;
          # The mixer level the card was left at is read back at start; the
          # page clamps changes to maxVolume. Software volume only on an
          # output with no control of its own.
          replaygain = "off";
          audio_output = [ (if out.kind == "alsa" then alsaOutput else nullOutput) ];
        };
      };

      # alsactl stores and restores the mixer levels, so the hardware volume
      # survives a reboot.
      hardware.alsa.enablePersistence = lib.mkDefault (out.kind == "alsa");

      # The playback modes MPD remembers are set back to the host's
      # defaults at every start, for the ones the host states an opinion
      # about. Only consume today. MPD has no config setting for it: the
      # modes live in its state file, so the only way to express a default
      # is to set it once MPD is listening.
      systemd.services.nixtune-mpd-defaults = lib.mkIf (cfg.mpd.consume != null) {
        description = "nixtune: MPD playback modes this host defaults to";
        wantedBy = [ "mpd.service" ];
        after = [ "mpd.service" ];
        path = [ pkgs.mpc ];
        serviceConfig = {
          Type = "oneshot";
          DynamicUser = true;
        };
        script = ''
          # mpd.service is ready when systemd says so, but the socket can
          # still refuse the first connection by a hair. Five tries over
          # five seconds, then stop and say so in the journal rather than
          # failing the unit and with it the boot.
          for _ in 1 2 3 4 5; do
            if mpc --host 127.0.0.1 --port ${toString cfg.mpd.port} consume ${if cfg.mpd.consume then "on" else "off"}; then
              exit 0
            fi
            sleep 1
          done
          echo "nixtune: could not set consume mode; MPD did not answer"
        '';
      };
    })
  ];
}