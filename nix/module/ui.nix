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
      publicUrl = cfg.ui.publicUrl;
      hostPath = cfg.ui.hostPath;
    }
  );

  # The QR code the host page shows, rendered once at build time. Nothing
  # in the bundle knows how to draw one, and the address it encodes is a
  # build-time fact.
  qr =
    pkgs.runCommand "nixtune-qr"
      {
        nativeBuildInputs = [ pkgs.qrencode ];
      }
      ''
        mkdir -p $out
        qrencode -t SVG -m 2 -o $out/qr.svg ${lib.escapeShellArg cfg.ui.publicUrl}
      '';

  root = pkgs.symlinkJoin {
    name = "nixtune-ui-root";
    paths = [
      cfg.ui.package
      capabilities
      qr
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
        # Every path that is not a file is the page; the page reads the
        # path to choose its role (ui.hostPath).
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