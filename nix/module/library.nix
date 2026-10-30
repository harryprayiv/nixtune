# Where the music comes from: one NFS export, mounted read-only at /srv/music,
# with nofail and automount so a NAS that is down does not block boot and a
# NAS that comes up later is picked up by MPD's auto_update.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.nixtune;
in
{
  config = lib.mkIf (cfg.enable && cfg.library.export != null) {
    boot.supportedFilesystems = [ "nfs" ];
    services.rpcbind.enable = true;

    fileSystems."/srv/music" = {
      device = cfg.library.export;
      fsType = "nfs";
      options = [
        "ro"
        "nofail"
        "noatime"
        "noauto"
        "x-systemd.automount"
        "x-systemd.idle-timeout=600"
        "x-systemd.mount-timeout=30s"
        # The first boot on hardware showed the automount being triggered
        # by MPD before the interface had an address, three attempts of
        # "Network is unreachable" and a failed mount unit left behind.
        # _netdev puts the mount in remote-fs ordering; the two x-systemd
        # lines make the mount itself wait for the network to be online.
        "_netdev"
        "x-systemd.requires=network-online.target"
        "x-systemd.after=network-online.target"
        # A bounded retry budget: a NAS that stops answering mid-track gives
        # an error in MPD rather than a process stuck in the kernel. timeo
        # is deciseconds.
        "soft"
        "timeo=150"
        "retrans=3"
      ];
    };

    # MPD reads the export as its own user. The export's squash settings on
    # the NAS decide whether that works: with "map all users to admin" or
    # no squash, mpd reads; with root squash alone it also reads, because mpd
    # is not root. Starting MPD after the network is online keeps its first
    # scan from triggering the automount before a route exists.
    systemd.services.mpd = {
      after = [
        "network-online.target"
        "srv-music.automount"
      ];
      wants = [
        "network-online.target"
        "srv-music.automount"
      ];
    };

    environment.systemPackages = [ pkgs.nfs-utils ];
  };
}