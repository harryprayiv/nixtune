# A UPnP renderer through upmpdcli.
#
# No arbitration hook here: upmpdcli does not open the DAC. It drives MPD
# over the MPD protocol, so a UPnP controller playing something is MPD
# playing something, and the page sees it as such.
#
# upmpdcli is not in nixpkgs. packages/upmpdcli.nix builds it and its two
# libraries; services.nixtune.renderers.upnp.package defaults to that build.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.nixtune;

  upnpPort = 49152;

  conf = pkgs.writeText "upmpdcli.conf" ''
    friendlyname = ${cfg.renderers.upnp.friendlyName}
    mpdhost = 127.0.0.1
    mpdport = ${toString cfg.mpd.port}
    upnpport = ${toString upnpPort}
    ownqueue = 1
    openhome = 1
    cachedir = /var/cache/upmpdcli
  '';
in
{
  config = lib.mkIf (cfg.enable && cfg.renderers.upnp.enable) {
    systemd.services.upmpdcli = {
      description = "nixtune: UPnP renderer (upmpdcli)";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "mpd.service"
      ];
      wants = [ "network-online.target" ];
      requires = [ "mpd.service" ];
      serviceConfig = {
        ExecStart = "${lib.getExe cfg.renderers.upnp.package} -c ${conf}";
        Restart = "on-failure";
        RestartSec = 5;
        DynamicUser = true;
        CacheDirectory = "upmpdcli";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
      };
    };

    networking.firewall = {
      allowedTCPPorts = [ upnpPort ];
      # SSDP discovery.
      allowedUDPPorts = [ 1900 ];
    };
  };
}
