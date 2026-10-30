# MPD on the DAC, with hardware volume and nothing between the decoder and
# the card.
{
  config,
  lib,
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

  alsaOutput = {
    type = "alsa";
    name = out.card;
    device = out.device;
    mixer_type = "hardware";
    mixer_device = "hw:CARD=${out.card}";
    mixer_control = out.mixer;
    # The DAC takes what the file is. No resampling, no channel or format
    # conversion in software unless the card refuses the stream.
    auto_resample = "no";
    auto_channels = "no";
    auto_format = "no";
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
          # The mixer level the DAC was left at is read back at start; the
          # page clamps changes to maxVolume. No software volume anywhere.
          replaygain = "off";
          audio_output = [ (if out.kind == "alsa" then alsaOutput else nullOutput) ];
        };
      };

      # alsactl stores and restores the mixer levels, so the hardware volume
      # survives a reboot.
      hardware.alsa.enablePersistence = lib.mkDefault (out.kind == "alsa");
    })
  ];
}