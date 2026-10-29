# The page: static files from packages/nixtune-web, one websocket to MPD
# through websocat, and a capabilities file written at build time so the
# page knows which modules exist without asking anything.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.nixtune;

  modules = [
    {
      kind = "mpd";
      enabled = true;
    }
    {
      kind = "airplay";
      enabled = cfg.renderers.airplay.enable;
    }
    {
      kind = "upnp_renderer";
      enabled = cfg.renderers.upnp.enable;
    }
  ];

  capabilities = pkgs.writeTextDir "capabilities.json" (
    builtins.toJSON {
      hostname = config.networking.hostName;
      hardware = {
        profile = cfg.hardware.profile;
        output = cfg.output.kind;
        card = cfg.output.card;
        mixer = cfg.output.mixer;
      };
      modules = map (m: m.kind) (lib.filter (m: m.enabled) modules);
      library = cfg.library.export != null;
      stations = cfg.radio.stations;
      websocketPath = "/ws";
      maxVolume = cfg.mpd.maxVolume;
    }
  );

  root = pkgs.symlinkJoin {
    name = "nixtune-ui-root";
    paths = [
      cfg.ui.package
      capabilities
    ];
  };

  websocketPort = 8600;
in
{
  config = lib.mkIf (cfg.enable && cfg.ui.enable) {
    # websocat turns one browser websocket into one MPD connection. Text
    # mode: the MPD protocol is UTF-8 lines, and the browser gets one message
    # per line.
    systemd.services.nixtune-websocket = {
      description = "nixtune: websocket to MPD";
      wantedBy = [ "multi-user.target" ];
      after = [ "mpd.service" ];
      requires = [ "mpd.service" ];
      serviceConfig = {
        ExecStart = "${lib.getExe pkgs.websocat} -t -E ws-l:127.0.0.1:${toString websocketPort} tcp:127.0.0.1:${toString cfg.mpd.port}";
        Restart = "always";
        RestartSec = 2;
        DynamicUser = true;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
      };
    };

    services.nginx = {
      enable = true;
      recommendedProxySettings = true;
      virtualHosts.nixtune = {
        default = true;
        listen = [
          {
            addr = "0.0.0.0";
            port = cfg.ui.port;
          }
        ];
        inherit root;
        locations."/" = {
          tryFiles = "$uri $uri/ /index.html";
        };
        locations."/ws" = {
          proxyPass = "http://127.0.0.1:${toString websocketPort}";
          proxyWebsockets = true;
          extraConfig = ''
            proxy_read_timeout 1h;
          '';
        };
      };
    };

    networking.firewall.allowedTCPPorts = [ cfg.ui.port ];
  };
}
