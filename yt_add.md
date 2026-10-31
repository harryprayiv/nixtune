Before touching anything I'm checking what the pinned nixpkgs gives you for yt-dlp, because recent YouTube extraction depends on things a stale package won't have.

ShellCheck passes on the generated helper. Now I'm running it end to end with stand-in `yt-dlp` and `mpc` to test the URL handling, the file-already-there path, the rejection path and the error path.

The `\n` in the Python heredoc became a newline. Fixing that and recompiling.

Now build the helper itself, since writeShellApplication runs shellcheck at build time.

The YouTube feature is wired through. The page compiles with no warnings and passed a browser smoke test against a fake helper:

- The Fetch button stays disabled when the field is empty.
- A bad link shows "Not queued: …" and leaves the text so you can fix it.
- A good link shows "Fetching…" while the download runs, then "Queued: …" and clears the field.
- Guest pages don't show the form.
- There were no page errors.

On the Nix side, I evaluated the module against your pinned nixpkgs with `library.export` set and `youtube.enable = true`. It produces a system, and the generated units, socket, mount and nginx location look right.

I could not build the helper here: there is no binary cache access, so it tried to compile ffmpeg's dependencies from source. Run on its own, shellcheck passes on the helper script, and the helper behaved correctly in tests with stand-in yt-dlp and mpc. The first real build on your side is still the first build of the full closure.

## Before you rebuild

1. On the NAS, create the `_youtube` folder at the top of the Music export.
2. The export has to let the player write to it. Either the NFS rule maps all users to admin, or the `nixtune-youtube` user's uid has write permission on that folder. The library mount stays read-only. Only `_youtube` is mounted read-write, at `/srv/nixtune-youtube`.
3. Set `services.nixtune.youtube.enable = true;` in the player host's config in neoblade-config, then rebuild the way you normally do.

## Checks after deploy (on the player)

```fish
systemctl status nixtune-youtube.socket nixtune-youtube-ws.service --no-pager
```
```fish
sudo -u nixtune-youtube touch /srv/nixtune-youtube/.nixtune-write-test
```
```fish
sudo -u nixtune-youtube rm /srv/nixtune-youtube/.nixtune-write-test
```
```fish
journalctl -t nixtune-youtube -n 50 --no-pager
```

If `touch` fails with "Permission denied", the NAS export or folder permissions are the problem, not the module.

## Problems you should know about

- **Who can use it:** anyone who can open the page can make the Pi download up to 300 MB per request and write it to your NAS. That is the same reach the MPD websocket already gives them. The form only appears on the host page, but nothing on the player enforces that.
- **yt-dlp goes stale:** it breaks every few weeks as YouTube changes. When fetches start failing with extractor errors, update the flake or point `youtube.package` at a newer build.
- **Cover art:** art.nix caches one cover per directory, so every YouTube track shares whichever cover it finds first in `_youtube`.
- **Tags:** the tags come from YouTube. The uploader becomes the artist, which is usable for "Artist - Topic" channels and junk for everything else. There is usually no Album tag, so these tracks group under an empty album in the tag browser.

## nix/module/youtube.nix (new)

```nix
# Queueing a track from a YouTube link: yt-dlp fetches the audio into a
# folder inside the library on the NAS, MPD indexes that folder, and the
# track is added to the end of the queue.
#
# ============================================================================
# THE SHAPE
# ============================================================================
#
# The same shape as volume.nix. A systemd socket on loopback with
# Accept=yes, a templated unit that runs the helper below with stdin and
# stdout on the connection, websocat turning a browser websocket into that
# connection, and nginx serving it at /youtube. The page sends one line,
#   get <url>
# and reads back
#   fetching <id>       the link was understood and the download started
#   added <uri>         the file is on the NAS and at the end of the queue
#   err <reason>        nothing was queued, and why
#
# MPD can only play a file that is inside its music_directory, so the
# download lands in services.nixtune.youtube.directory, a folder at the top
# of the library export, and the helper asks MPD to rescan that folder
# before it adds the file. The library itself stays mounted read-only at
# /srv/music; the download folder alone is mounted read-write, at
# /srv/nixtune-youtube.
#
# ============================================================================
# WHAT THE HELPER WILL AND WILL NOT RUN
# ============================================================================
#
# The URL a browser sends is never handed to yt-dlp. The helper accepts a
# youtube.com watch, shorts or live link, or a youtu.be link, pulls the
# eleven character video id out of it, and builds the URL yt-dlp gets from
# that id alone. Anything else is refused, so the socket cannot be used to
# make the player fetch an arbitrary address on the LAN or the internet,
# and no part of what was sent reaches a shell or a command line.
#
# yt-dlp runs with --ignore-config, one video and never a playlist, a
# length limit (youtube.maxMinutes, which also refuses live streams), a
# size limit (youtube.maxSize) and a wall-clock limit of fifteen minutes.
# One download runs at a time across every connection; a second request
# waits for the first.
#
# Anyone who can reach the page can reach this socket, which is the same
# reach the MPD websocket already gives them (decision 8 in
# nixtune.allium). The page offers it on the host page only.
#
# ============================================================================
# THE FILE
# ============================================================================
#
# The best audio stream YouTube offers, extracted without re-encoding:
# Opus from a WebM stream, AAC from an M4A one. Title, uploader and date
# are written into the tags and the thumbnail is embedded as the cover, so
# art.nix finds a picture in it like any other file. The name is
# "<uploader> - <title> [<id>].<ext>", and a link whose id is already in
# the folder is queued from the file that is there without downloading
# again.
#
# yt-dlp works in a local cache directory and the finished file is copied
# to the NAS under a .part name and renamed into place, so MPD never sees
# a half-written file under a name it would index.
#
# ============================================================================
# KEEPING IT WORKING
# ============================================================================
#
# YouTube changes what yt-dlp has to do every few weeks, and a yt-dlp from
# a nixpkgs pin that is a few months old stops working against it. When
# fetches start failing with extractor errors, the fix is a newer yt-dlp:
# a flake update, or services.nixtune.youtube.package pointed at a newer
# build.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.nixtune;
  yt = cfg.youtube;

  enabled = cfg.enable && cfg.ui.enable && yt.enable;

  mount = "/srv/nixtune-youtube";
  cacheName = "nixtune-youtube";
  cacheDir = "/var/cache/${cacheName}";

  socketPort = 8603;
  bridgePort = 8604;

  helper = pkgs.writeShellApplication {
    name = "nixtune-youtube";
    runtimeInputs = [
      yt.package
      pkgs.mpc
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnugrep
      pkgs.util-linux
    ];
    text = ''
      dir=${lib.escapeShellArg mount}
      rel=${lib.escapeShellArg yt.directory}
      work=${lib.escapeShellArg cacheDir}/work
      lock=${lib.escapeShellArg cacheDir}/lock
      maxsec=${toString (yt.maxMinutes * 60)}
      maxsize=${lib.escapeShellArg yt.maxSize}

      player() {
        mpc --host 127.0.0.1 --port ${toString cfg.mpd.port} "$@"
      }

      # One line out, never more: the page reads replies line by line.
      reply() {
        printf '%s\n' "$*" | tr -d '\r' | head -n 1 | cut -c 1-400
      }

      # A watch, shorts or live link on youtube.com (www, m and music
      # included), or a youtu.be link. Group 5 is the video id.
      re='^https://(www\.|m\.|music\.)?(youtube\.com/(watch\?([^#]*&)?v=|shorts/|live/)|youtu\.be/)([A-Za-z0-9_-]{11})([?&#/]|$)'

      mkdir -p "$work"

      while read -r verb url rest; do
        if [ "$verb" != "get" ] || [ -z "$url" ] || [ -n "$rest" ]; then
          reply "err expected: get URL"
          continue
        fi
        if [[ ! $url =~ $re ]]; then
          reply "err not a YouTube video link"
          continue
        fi
        id=''${BASH_REMATCH[5]}
        reply "fetching $id"

        name=$(find "$dir" -maxdepth 1 -type f -name "*\[$id\].*" ! -name '*.part' -printf '%f\n' -quit)

        if [ -z "$name" ]; then
          rm -rf "''${work:?}/$id" "$work/$id.log"
          if ! out=$(flock "$lock" timeout 900 yt-dlp \
            --ignore-config \
            --no-playlist \
            --quiet \
            --no-warnings \
            --format bestaudio \
            --extract-audio \
            --match-filter "duration <= $maxsec & !is_live" \
            --max-filesize "$maxsize" \
            --embed-metadata \
            --embed-thumbnail \
            --convert-thumbnails jpg \
            --windows-filenames \
            --trim-filenames 180 \
            --paths "$work/$id" \
            --output "%(uploader)s - %(title)s [%(id)s].%(ext)s" \
            --print after_move:filepath \
            "https://www.youtube.com/watch?v=$id" 2>"$work/$id.log"); then
            reply "err $(grep -m 1 'ERROR' "$work/$id.log" || tail -n 1 "$work/$id.log")"
            rm -rf "''${work:?}/$id" "$work/$id.log"
            continue
          fi
          src=$(printf '%s\n' "$out" | tail -n 1)
          if [ -z "$src" ] || [ ! -f "$src" ]; then
            reply "err longer than ${toString yt.maxMinutes} minutes, larger than ${yt.maxSize}, or a live stream"
            rm -rf "''${work:?}/$id" "$work/$id.log"
            continue
          fi
          name=$(basename "$src")
          if ! cp "$src" "$dir/$name.part" || ! mv "$dir/$name.part" "$dir/$name"; then
            rm -f "$dir/$name.part"
            rm -rf "''${work:?}/$id" "$work/$id.log"
            reply "err could not write to the NAS folder"
            continue
          fi
          rm -rf "''${work:?}/$id" "$work/$id.log"
        fi

        # The library mount and the download mount are separate NFS mounts,
        # each with its own attribute cache, so the library side can take a
        # little while to see the new file. Rescan, try to add, and try
        # again for a minute and a half before giving up.
        uri="$rel/$name"
        added=0
        for _ in $(seq 1 18); do
          player --wait rescan "$rel" >/dev/null 2>&1 || true
          if player add "$uri" >/dev/null 2>&1; then
            added=1
            break
          fi
          sleep 5
        done
        if [ "$added" = 1 ]; then
          reply "added $uri"
        else
          reply "err downloaded, but MPD has not indexed it yet: $uri"
        fi
      done
    '';
  };
in
{
  options.services.nixtune.youtube.path = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    readOnly = true;
    internal = true;
    default = if enabled then "/youtube" else null;
    description = ''
      Where the page sends YouTube links, or null when the feature is off.
      Read by ui.nix for capabilities.json.
    '';
  };

  config = lib.mkIf enabled {
    assertions = [
      {
        assertion = cfg.library.export != null;
        message = "services.nixtune.youtube needs services.nixtune.library.export: the download folder is a folder inside the library export.";
      }
    ];

    users.users.nixtune-youtube = {
      isSystemUser = true;
      group = "nixtune-youtube";
      description = "nixtune YouTube downloads";
    };
    users.groups.nixtune-youtube = { };

    # The download folder, read-write, on its own. The library mount stays
    # read-only. The same reliability options as library.nix, for the same
    # reasons: the NAS may be down at boot, and a NAS that stops answering
    # gives an error rather than a process stuck in the kernel.
    fileSystems.${mount} = {
      device = "${cfg.library.export}/${yt.directory}";
      fsType = "nfs";
      options = [
        "rw"
        "nofail"
        "noatime"
        "noauto"
        "x-systemd.automount"
        "x-systemd.idle-timeout=600"
        "x-systemd.mount-timeout=30s"
        "_netdev"
        "x-systemd.requires=network-online.target"
        "x-systemd.after=network-online.target"
        "soft"
        "timeo=150"
        "retrans=3"
      ];
    };

    systemd.sockets.nixtune-youtube = {
      description = "nixtune: YouTube helper socket";
      wantedBy = [ "sockets.target" ];
      socketConfig = {
        ListenStream = "127.0.0.1:${toString socketPort}";
        Accept = "yes";
      };
    };

    systemd.services."nixtune-youtube@" = {
      description = "nixtune: fetch a YouTube track into the library and queue it";
      after = [
        "mpd.service"
        "network-online.target"
      ];
      wants = [ "network-online.target" ];
      # The download folder is an automount, and a service runs in its own
      # mount namespace: this makes systemd mount it before the namespace
      # is taken, as art.nix does for the library.
      unitConfig.RequiresMountsFor = [ mount ];
      serviceConfig = {
        ExecStart = lib.getExe helper;
        StandardInput = "socket";
        StandardOutput = "socket";
        StandardError = "journal";
        # A fixed user, so the NAS sees one uid for every file written.
        # With the export set to map all users to admin, that is what the
        # files are owned by on the NAS; without squashing, this uid needs
        # write permission on the folder.
        User = "nixtune-youtube";
        Group = "nixtune-youtube";
        # yt-dlp's working files and deno's cache. Shared by every
        # connection, which is also where the one-at-a-time lock lives.
        CacheDirectory = cacheName;
        Environment = [
          "HOME=${cacheDir}"
          "XDG_CACHE_HOME=${cacheDir}"
          "DENO_DIR=${cacheDir}/deno"
        ];
        ReadWritePaths = [ mount ];
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
      };
    };

    # One browser websocket to one TCP connection, which socket activation
    # turns into one run of the helper.
    systemd.services.nixtune-youtube-ws = {
      description = "nixtune: websocket to the YouTube helper";
      wantedBy = [ "multi-user.target" ];
      after = [ "nixtune-youtube.socket" ];
      wants = [ "nixtune-youtube.socket" ];
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

    services.nginx.virtualHosts.nixtune.locations."/youtube" = {
      proxyPass = "http://127.0.0.1:${toString bridgePort}";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_read_timeout 1h;
      '';
    };
  };
}
```

## nix/module/default.nix

```nix
# nixtune: a network music player as one NixOS module.
#
# MPD on a DAC through ALSA with hardware volume and nothing else in the
# chain; AirPlay and UPnP renderers as sub-options that are off by default;
# a Halogen page (packages/nixtune-web) that speaks the MPD protocol over a
# websocket. There is no settings database and no settings page: the options
# below are the configuration, and changing them means a new generation with
# the previous one a reboot away.
#
# This file declares every option and the wiring that is not one service.
# The parts live beside it:
#
#   hardware.nix   board and DAC facts per profile, the device tree overlay
#   mpd.nix        the daemon on the card
#   library.nix    the NFS export, mounted read-only at /srv/music
#   database.nix   what MPD indexes, and dropping its database when the
#                  export changes
#   volume.nix     writing the hardware volume, which MPD cannot do on this
#                  card
#   art.nix        pulling cover art out of the files into a served cache
#   ui.nix         nginx, websocat, capabilities.json, the page
#   youtube.nix    fetching a YouTube track into the library and queueing it
#   airplay.nix    shairport-sync and the arbitration hooks
#   upnp.nix       upmpdcli
#
# The module knows nothing about where its inputs come from. The wifi
# passphrase is a path to an environment file; how that file gets onto the
# machine (sops, agenix, a file copied by hand) is the consumer's business.
# The library is one "host:/export" string. What the module needs kept
# across a root wipe is published as services.nixtune.persistPaths for an
# impermanence setup to read.
#
# ============================================================================
# THE WIFI SECRET
# ============================================================================
#
# The passphrase is an ENVIRONMENT FILE, not a bare value, because
# NetworkManager's ensureProfiles runs envsubst over the keyfile with that
# file loaded. The file holds one line:
#   PSK=the-passphrase
# and the profile refers to $PSK. An SSID with no pskFile writes no profile
# and warns, so a machine can be built and booted on ethernet before the
# secret exists.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption types;

  cfg = config.services.nixtune;

  wantWifi = cfg.wifi.ssid != null;
  haveWifi = wantWifi && cfg.wifi.pskFile != null;

  station = types.submodule {
    options = {
      name = mkOption {
        type = types.str;
        description = "Name shown on the page.";
      };
      url = mkOption {
        type = types.str;
        description = "Stream URL handed to MPD.";
      };
    };
  };
in
{
  imports = [
    ./hardware.nix
    ./mpd.nix
    ./library.nix
    ./database.nix
    ./volume.nix
    ./art.nix
    ./ui.nix
    ./youtube.nix
    ./airplay.nix
    ./upnp.nix
  ];

  options.services.nixtune = {
    enable = lib.mkEnableOption "nixtune, the network music player";

    hardware.profile = mkOption {
      type = types.enum [
        "pi5-dac2hd"
        "none"
      ];
      default = "pi5-dac2hd";
      description = ''
        The board and DAC this host is built for.

        pi5-dac2hd  Raspberry Pi 5 with a HiFiBerry DAC2 HD. Device tree
                    overlay, ALSA card name and hardware mixer come from
                    hardware.nix. Needs the Raspberry Pi kernel, which
                    nixos-hardware's raspberry-pi-5 module provides.
        none        No sound card. MPD plays into a null output. For a
                    rehearsal VM, where everything but the DAC is exercised.
      '';
    };

    library.export = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "192.168.1.10:/volume1/music";
      description = ''
        The NFS export holding the library, as host:/path. Null means no
        library: radio and renderers only. Mounted read-only at /srv/music
        by library.nix, with nofail and automount, so a NAS that is down does
        not block boot.
      '';
    };

    wifi = {
      ssid = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "The network the player joins over wifi. Null means wired only.";
      };
      pskFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "/run/secrets/wifi-psk";
        description = ''
          Path, at runtime, to an environment file holding PSK=<passphrase>.
          Not a Nix path: its contents must never enter the store. With an
          ssid and no pskFile the profile is not written and a warning says
          so.
        '';
      };
    };

    mpd = {
      port = mkOption {
        type = types.port;
        default = 6600;
      };
      exposeOnLan = mkOption {
        type = types.bool;
        default = false;
        description = "Let MPD clients on the LAN connect directly, in addition to the page.";
      };
      maxVolume = mkOption {
        type = types.ints.between 0 100;
        default = 100;
        description = "Upper bound the page allows for the volume.";
      };
      maxOutputBuffer = mkOption {
        type = types.str;
        default = "32768";
        description = ''
          MPD's max_output_buffer_size, in kilobytes. MPD assembles a
          reply in one buffer and closes the client when the reply will
          not fit; the default of 8192 is exceeded by `listall` over a
          library of seventy thousand tracks. The buffer grows on demand,
          so a larger ceiling costs nothing until a reply needs it.
        '';
      };
      consume = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = ''
          Consume mode at every MPD start, or null to leave whatever was
          last chosen.

          MPD remembers consume, random, repeat and single in its state
          file across restarts, so null means a change made on the page
          survives a reboot. A value here overrides that remembered state
          on every start, which is what makes it a default rather than a
          preference: with true, a queue is a list of things waiting to be
          played and each one leaves as it finishes, and the page's
          Consume toggle still turns it off until the next start.
        '';
      };
    };

    radio.stations = mkOption {
      type = types.listOf station;
      default = [ ];
      description = "Stations offered on the page.";
    };

    ui = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Serve the page.";
      };
      package = mkOption {
        type = types.package;
        default = pkgs.callPackage ../../packages/nixtune-web { };
        defaultText = lib.literalExpression "nixtune's packages/nixtune-web, built with this host's pkgs";
        description = "The built page: a directory with index.html at its root.";
      };
      port = mkOption {
        type = types.port;
        default = 80;
      };
      publicUrl = mkOption {
        type = types.str;
        default = "http://${config.networking.hostName}.lan/";
        defaultText = lib.literalExpression ''"http://''${config.networking.hostName}.lan/"'';
        description = ''
          The address the QR code on the host page encodes: how a guest's
          phone reaches the guest page. A name the LAN's DNS resolves, or
          an address with a reservation behind it.
        '';
      };
      albumArt = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Show cover art beside what is playing.

          art.nix builds a cache: one cover.jpg per album directory, taken
          from a picture file beside the audio when there is one and pulled
          out of the tags with ffmpeg when there is not, since most
          libraries keep the cover inside the files. nginx serves that
          cache and nothing else, so no audio is reachable over HTTP. The
          first scan over a large library runs for a while at idle
          priority; afterwards only changed album directories cost
          anything.
        '';
      };
      albumArtSize = mkOption {
        type = types.ints.between 64 4096;
        default = 600;
        description = ''
          The longest edge, in pixels, a cached cover is scaled down to. A
          picture already smaller than this is left alone. 600 is about
          twice what the page draws on a phone, so it still looks right on
          a desktop and on a high-density screen.
        '';
      };
      hostPath = mkOption {
        type = types.strMatching "/.+";
        default = "/host";
        description = ''
          The path that opens the page in the host role, with the queue,
          transport, volume and the QR. Every other path is the guest
          page. A convention the page honours, not a credential: both
          roles reach the same websocket to MPD.
        '';
      };
    };

    party = {
      enable = lib.mkEnableOption ''
        party mode.

        The guest page gains the queue, read only, with a veto button on
        each entry. A guest's vote is written as an MPD sticker on the
        track's URI, so every browser sees the same count without
        anything on the player keeping score, and when the count reaches
        party.vetoes the track leaves the queue and its votes are
        cleared.

        This adds no security and removes none. The guest page already
        reaches the same websocket as the host page, so this is about
        what the page OFFERS a guest, not about what the player permits.
        A vote is one per browser per track, named by the nickname that
        browser made up for itself, and anyone who clears their browser
        storage votes again under a new name. For a room of invited
        people that is the right trade. It is not a voting system and
        should not be mistaken for one
      '';
      vetoes = mkOption {
        type = types.ints.positive;
        default = 3;
        description = ''
          How many distinct guests have to vote against a track before it
          leaves the queue.
        '';
      };
    };

    youtube = {
      enable = lib.mkEnableOption ''
        queueing a track from a YouTube link.

        The host page gains a field for a YouTube link. The player fetches
        the audio with yt-dlp into youtube.directory, a folder inside the
        library export on the NAS, has MPD index it, and adds it to the end
        of the queue. youtube.nix describes what the helper will and will
        not run.

        The folder has to exist on the NAS before the first fetch, and the
        export has to let this host write to it: either the export maps all
        users to admin, or the nixtune-youtube user's uid can write to the
        folder
      '';
      directory = mkOption {
        type = types.strMatching "[A-Za-z0-9_][A-Za-z0-9_.-]*";
        default = "_youtube";
        description = ''
          The folder the downloads go to, at the top of the library export:
          library.export with this appended is mounted read-write, and the
          tracks appear in MPD under this name. One path component, no
          spaces.
        '';
      };
      package = mkOption {
        type = types.package;
        default = pkgs.yt-dlp;
        defaultText = lib.literalExpression "pkgs.yt-dlp";
        description = ''
          The yt-dlp to run. YouTube changes what yt-dlp has to do every few
          weeks, so when fetches start failing with extractor errors, point
          this at a newer build or update the flake.
        '';
      };
      maxMinutes = mkOption {
        type = types.ints.between 1 600;
        default = 20;
        description = "The longest video, in minutes, the helper will fetch. Live streams are refused whatever this is.";
      };
      maxSize = mkOption {
        type = types.strMatching "[0-9]+[KMG]";
        default = "300M";
        description = "The largest audio stream the helper will download, in yt-dlp's notation.";
      };
    };

    arbitration.resumeAfterRenderer = mkOption {
      type = types.bool;
      default = true;
      description = "Resume MPD when a renderer that paused it stops streaming.";
    };

    renderers = {
      airplay = {
        enable = lib.mkEnableOption "AirPlay through shairport-sync";
        name = mkOption {
          type = types.str;
          default = config.networking.hostName;
          defaultText = lib.literalExpression "config.networking.hostName";
          description = "Name advertised to AirPlay senders.";
        };
      };
      upnp = {
        enable = lib.mkEnableOption "a UPnP renderer through upmpdcli";
        friendlyName = mkOption {
          type = types.str;
          default = config.networking.hostName;
          defaultText = lib.literalExpression "config.networking.hostName";
        };
        package = mkOption {
          type = types.package;
          default = pkgs.callPackage ../../packages/upmpdcli.nix { };
          defaultText = lib.literalExpression "nixtune's packages/upmpdcli.nix, built with this host's pkgs";
          description = "upmpdcli, which nixpkgs does not carry.";
        };
      };
    };

    # What nixtune writes and expects to find again after a reboot. Read by
    # an impermanence setup; nixtune itself does nothing with it.
    # Not readOnly: more than one part owns state, and each declares its
    # own, so the definitions merge into one list for the consumer to read.
    persistPaths = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Directories holding nixtune's state. Set by the parts that own them.";
    };

    # Set by hardware.nix from the profile; read by the other files.
    output = {
      kind = mkOption {
        type = types.enum [
          "alsa"
          "null"
        ];
        readOnly = true;
        internal = true;
      };
      card = mkOption {
        type = types.nullOr types.str;
        readOnly = true;
        internal = true;
      };
      device = mkOption {
        type = types.nullOr types.str;
        readOnly = true;
        internal = true;
      };
      mixer = mkOption {
        type = types.nullOr types.str;
        readOnly = true;
        internal = true;
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Wifi needs NetworkManager; the profile below is written through it.
    # mkDefault, so a host that already made that choice keeps it.
    networking.networkmanager.enable = lib.mkIf wantWifi (lib.mkDefault true);

    # A Pi 5 on wifi with powersave on drops off the network for seconds at
    # a time, which a stream notices and a phone's AirPlay sender notices
    # more. Off the moment a wifi SSID is declared.
    networking.networkmanager.wifi.powersave = lib.mkIf wantWifi false;

    networking.networkmanager.ensureProfiles = lib.mkIf haveWifi {
      environmentFiles = [ cfg.wifi.pskFile ];
      profiles.${cfg.wifi.ssid} = {
        connection = {
          id = cfg.wifi.ssid;
          type = "wifi";
          autoconnect = true;
        };
        wifi = {
          mode = "infrastructure";
          ssid = cfg.wifi.ssid;
        };
        wifi-security = {
          key-mgmt = "wpa-psk";
          psk = "$PSK";
        };
        ipv4.method = "auto";
        ipv6 = {
          method = "auto";
          addr-gen-mode = "stable-privacy";
        };
      };
    };

    assertions = [
      {
        assertion = wantWifi -> config.networking.networkmanager.enable;
        message = "services.nixtune.wifi.ssid is set but networking.networkmanager.enable is false; the wifi profile is written through NetworkManager.";
      }
    ];

    warnings = lib.optional (wantWifi && !haveWifi) ''
      ${config.networking.hostName}: services.nixtune.wifi.ssid is set and
      services.nixtune.wifi.pskFile is null, so no wifi profile is written
      and the player is reachable over ethernet only. Provide the PSK file
      (one line, PSK=<passphrase>) and rebuild.
    '';

    environment.systemPackages = [
      pkgs.alsa-utils
      pkgs.mpc
    ];
  };
}
```

## nix/module/ui.nix

```nix
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
      # Where volume changes go. Null means MPD's own mixer takes them
      # (setvol); a path means the helper in volume.nix does, because MPD
      # cannot write this card's mixer. The page reads the level from MPD
      # either way.
      volumePath = cfg.volume.path;
      # Where cover images are served from, or null when there is no
      # library or album art is off. art.nix fills that cache and owns the
      # nginx location that serves it.
      artPath = cfg.art.path;
      # Where YouTube links go, or null when youtube.nix is off. Like the
      # volume helper, a socket nginx serves beside the page.
      youtubePath = cfg.youtube.path;
      maxVolume = cfg.mpd.maxVolume;
      # Party mode and how many votes it takes to drop a track. Both are
      # build-time facts, like everything else here.
      party = cfg.party.enable;
      vetoes = cfg.party.vetoes;
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
        locations = {
          # Every path that is not a file is the page; the page reads the
          # path to choose its role (ui.hostPath).
          #
          # NO BROWSER CACHING, AND WHY. Every file here is in the Nix
          # store, where every mtime is 1970-01-01. nginx would send that
          # as Last-Modified with no lifetime, and a browser then applies
          # heuristic freshness, ten percent of the file's age: about five
          # years. A phone that loaded index.js once would not ask for it
          # again after a deploy. So the page is served no-store, and the
          # mtime-based validators are off because from the store they say
          # nothing. The bundle is kilobytes on a LAN.
          "/" = {
            tryFiles = "$uri $uri/ /index.html";
            extraConfig = ''
              add_header Cache-Control "no-store";
              etag off;
              if_modified_since off;
            '';
          };

          "/ws" = {
            proxyPass = "http://127.0.0.1:${toString websocketPort}";
            proxyWebsockets = true;
            extraConfig = ''
              proxy_read_timeout 1h;
            '';
          };
        };
      };
    };

    networking.firewall.allowedTCPPorts = [ cfg.ui.port ];
  };
}
```

## packages/nixtune-web/src/Caps.purs

```purescript
-- | What this host was built with: capabilities.json, written by the Nix
-- | module (nix/module/ui.nix) at build time and served beside the page.
-- | The page shows a module only if it is listed here, so a renderer that
-- | is off in Nix has no tab, badge or button.
module Caps
  ( Caps
  , Station
  , fetch
  ) where

import Prelude

import Affjax.ResponseFormat as ResponseFormat
import Affjax.Web as AX
import Data.Argonaut.Decode (decodeJson, printJsonDecodeError)
import Data.Bifunctor (lmap)
import Data.Either (Either(..))
import Data.Maybe (Maybe)
import Effect.Aff (Aff)

type Station = { name :: String, url :: String }

type Caps =
  { hostname :: String
  , hardware ::
      { profile :: String
      , output :: String
      , card :: Maybe String
      , mixer :: Maybe String
      }
  , modules :: Array String
  , library :: Boolean
  , stations :: Array Station
  , websocketPath :: String
  -- Null when MPD's own mixer takes volume changes; a path when the
  -- helper in nix/module/volume.nix does.
  , volumePath :: Maybe String
  -- Where cover images are served from, or null when the host serves
  -- none. See nix/module/ui.nix.
  , artPath :: Maybe String
  -- Where YouTube links are sent, or null when the host has no YouTube
  -- helper. See nix/module/youtube.nix.
  , youtubePath :: Maybe String
  , maxVolume :: Int
  , publicUrl :: String
  , hostPath :: String
  -- Party mode: guests see the queue and can vote a track off it. The
  -- vote is a sticker on the track's URI, so it is shared by every
  -- browser without anything on the player keeping score.
  , party :: Boolean
  , vetoes :: Int
  }

fetch :: Aff (Either String Caps)
fetch = do
  r <- AX.get ResponseFormat.json "capabilities.json"
  pure $ case r of
    Left e -> Left (AX.printError e)
    Right res -> lmap printJsonDecodeError (decodeJson res.body)
```

## packages/nixtune-web/src/Youtube.purs (new)

```purescript
-- | Queueing a track from a YouTube link: what the page sends to the
-- | helper in nix/module/youtube.nix, and what it makes of the replies.
-- |
-- | The helper does the work on the player: it checks the link, fetches
-- | the audio into the library on the NAS, has MPD index it and adds it to
-- | the queue. The page sends one line and shows what comes back. The new
-- | track reaches the queue view the way every change does, through MPD's
-- | idle connection, so nothing here touches the queue.
module Youtube
  ( submit
  , received
  , opened
  , closed
  ) where

import Prelude

import Data.Array as Array
import Data.Foldable (for_)
import Data.Maybe (Maybe(..))
import Data.String (Pattern(..), split, stripPrefix, trim)
import Effect.Aff (Milliseconds(..), delay)
import Effect.Aff.Class (class MonadAff)
import Effect.Class (liftEffect)
import Halogen as H
import Mpd as Mpd
import Net (connectYoutube)
import Types (M)
import Web.Event.Event (Event, preventDefault)
import Web.Socket.WebSocket as WS

-- | The field was submitted. One fetch at a time from this page: the
-- | helper runs them one at a time anyway, and a second link sent while
-- | the first is downloading would only queue behind it with no word on
-- | the page about which reply belongs to which.
submit :: forall o m. MonadAff m => Event -> M o m Unit
submit ev = do
  liftEffect (preventDefault ev)
  st <- H.get
  let
    url = trim st.ytText
  unless (url == "" || st.ytBusy) $ case st.ytLink of
    Just k | k.ready -> do
      liftEffect (WS.sendString k.socket ("get " <> url))
      H.modify_ _ { ytBusy = true, ytNote = Just "Sending the link to the player." }
    _ -> H.modify_ _ { ytNote = Just "The player's YouTube helper is not reachable." }

-- | A message from the helper. websocat frames by read rather than by
-- | line, but the helper writes one short line per reply and nothing
-- | else, so a message is one or more whole lines.
received :: forall o m. String -> M o m Unit
received raw = for_ (Array.filter (_ /= "") (map trim (split (Pattern "\n") raw))) line
  where
  line l = case stripPrefix (Pattern "fetching ") l, stripPrefix (Pattern "added ") l, stripPrefix (Pattern "err ") l of
    Just _, _, _ ->
      H.modify_ _ { ytNote = Just "Downloading. The track joins the end of the queue when it is on the NAS." }
    _, Just uri, _ ->
      H.modify_ _ { ytBusy = false, ytText = "", ytNote = Just ("Queued: " <> Mpd.basename uri) }
    _, _, Just why ->
      H.modify_ _ { ytBusy = false, ytNote = Just ("Not queued: " <> why) }
    _, _, _ -> pure unit

opened :: forall o m. M o m Unit
opened = H.modify_ \st -> st { ytLink = map (_ { ready = true }) st.ytLink }

-- | The socket went away: whatever was under way will not report back on
-- | it, so the field is freed, and the socket is opened again.
closed :: forall o m. MonadAff m => M o m Unit
closed = do
  busy <- H.gets _.ytBusy
  H.modify_ _ { ytLink = Nothing, ytBusy = false }
  when busy (H.modify_ _ { ytNote = Just "The connection to the helper dropped. The track may still arrive in the queue." })
  H.liftAff (delay (Milliseconds 2000.0))
  path <- H.gets (\st -> st.caps >>= _.youtubePath)
  for_ path connectYoutube
```

## packages/nixtune-web/src/Net.purs

```purescript
-- | The sockets. Three to MPD through websocat, and one to the volume
-- | helper when the host has one. Opening them, buffering what arrives on
-- | them, remembering what was asked, and the handful of requests the
-- | rest of the page sends by name.
-- |
-- | THE BUFFER IS NOT COMPONENT STATE, and that is the single most
-- | important thing in this module. Halogen renders the whole page
-- | synchronously on every state update whose result is a new value
-- | (Halogen.Aff.Driver.Eval, the State case). A reply to `list artist`
-- | on this library is around ten thousand lines; accumulating those
-- | through the state meant ten thousand renders for one reply, and
-- | opening the Library took the best part of a minute with the player
-- | answering in under a second. The partial tail and the lines of the
-- | reply being collected therefore live in Refs, which are written
-- | through liftEffect and never through modify_, so a whole reply costs
-- | exactly one render: the one that shows the result.
module Net where

import Prelude

import Control.Monad.Except (runExcept)
import Data.Array (snoc)
import Data.Array as Array
import Data.Either (hush)
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.String (Pattern(..), split, stripSuffix)
import Effect (Effect)
import Effect.Aff.Class (class MonadAff)
import Effect.Class (liftEffect)
import Effect.Ref as Ref
import Foreign (readString)
import Halogen as H
import Halogen.Query.Event as HQE
import Mpd as Mpd
import Types (Action(..), Conn(..), Link, M, Req(..), State)
import Web.HTML (window)
import Web.HTML.Location as Location
import Web.HTML.Window (location)
import Web.Socket.Event.EventTypes as WSE
import Web.Socket.Event.MessageEvent as ME
import Web.Socket.WebSocket as WS

-- | A path on this host as a websocket URL, with the scheme the page was
-- | served over.
socketUrl :: String -> Effect String
socketUrl path = do
  loc <- window >>= location
  proto <- Location.protocol loc
  host <- Location.host loc
  pure ((if proto == "https:" then "wss://" else "ws://") <> host <> path)

connect :: forall o m. MonadAff m => Conn -> M o m Unit
connect conn = do
  st <- H.modify \s -> s { sockets = s.sockets + 1 }
  let
    serial = st.sockets
    path = maybe "/ws" _.websocketPath st.caps
  url <- liftEffect (socketUrl path)
  socket <- liftEffect (WS.create url [])
  partial <- liftEffect (Ref.new "")
  block <- liftEffect (Ref.new "")
  let
    target = WS.toEventTarget socket
  void $ H.subscribe $ HQE.eventListener WSE.onOpen target (const (Just (Opened conn serial)))
  void $ H.subscribe $ HQE.eventListener WSE.onClose target (const (Just (Closed conn serial)))
  void $ H.subscribe $ HQE.eventListener WSE.onMessage target \ev -> do
    me <- ME.fromEvent ev
    s <- hush (runExcept (readString (ME.data_ me)))
    pure (Chunk conn serial s)
  setLink conn (Just { socket, serial, ready: false, asked: [], queued: [], partial, block })

-- | This connection's socket, when the event that arrived came from the
-- | socket the connection is actually using.
liveLink :: Conn -> Int -> State -> Maybe Link
liveLink conn serial st = case linkOf conn st of
  Just k | k.serial == serial -> Just k
  _ -> Nothing

-- | Drop a connection and open another in its place.
-- |
-- | MPD has no way to cancel a command it has started, and it answers one
-- | command at a time per connection in the order they arrived. So a
-- | click that lands while a large listing is in flight waits for that
-- | listing, and then for everything queued behind it, before the player
-- | even reads what the click asked for. Closing the socket is the
-- | cancel: the replies to the work nobody wants any more are never
-- | delivered, and what the click asked for goes out on a connection with
-- | nothing in front of it. Requests made before the new socket has
-- | greeted are held by `send` and flushed by the greeting, so nothing is
-- | lost in the gap.
reopen :: forall o m. MonadAff m => Conn -> M o m Unit
reopen conn = do
  st <- H.get
  for_ (linkOf conn st) \k -> liftEffect (WS.close k.socket)
  setLink conn Nothing
  connect conn
  where
  for_ m f = maybe (pure unit) f m

-- | Is this connection waiting on anything. A click only has to cancel
-- | when there is something to cancel.
busy :: Conn -> State -> Boolean
busy conn st = case linkOf conn st of
  Just k -> not (Array.null k.asked) || not (Array.null k.queued)
  Nothing -> false

-- | The volume socket. It carries one line per change and its replies are
-- | not read: the level the page shows always comes from MPD, which
-- | reports the mixer whoever moved it.
connectVolume :: forall o m. MonadAff m => String -> M o m Unit
connectVolume path = do
  url <- liftEffect (socketUrl path)
  socket <- liftEffect (WS.create url [])
  let
    target = WS.toEventTarget socket
  void $ H.subscribe $ HQE.eventListener WSE.onOpen target (const (Just VolOpened))
  void $ H.subscribe $ HQE.eventListener WSE.onClose target (const (Just VolClosed))
  H.modify_ _ { volLink = Just { socket, ready: false } }

-- | The YouTube helper's socket. Unlike the volume socket its replies
-- | are read: the helper says when a fetch starts, when the track is in
-- | the queue, and why when it is not.
connectYoutube :: forall o m. MonadAff m => String -> M o m Unit
connectYoutube path = do
  url <- liftEffect (socketUrl path)
  socket <- liftEffect (WS.create url [])
  let
    target = WS.toEventTarget socket
  void $ H.subscribe $ HQE.eventListener WSE.onOpen target (const (Just YtOpened))
  void $ H.subscribe $ HQE.eventListener WSE.onClose target (const (Just YtClosed))
  void $ H.subscribe $ HQE.eventListener WSE.onMessage target \ev -> do
    me <- ME.fromEvent ev
    s <- hush (runExcept (readString (ME.data_ me)))
    pure (YtChunk s)
  H.modify_ _ { ytLink = Just { socket, ready: false } }

linkOf :: Conn -> State -> Maybe Link
linkOf = case _ of
  Cmd -> _.cmd
  Idle -> _.idle
  Lib -> _.lib

setLink :: forall o m. Conn -> Maybe Link -> M o m Unit
setLink conn l = H.modify_ $ case conn of
  Cmd -> _ { cmd = l }
  Idle -> _ { idle = l }
  Lib -> _ { lib = l }

modifyLink :: forall o m. Conn -> (Link -> Link) -> M o m Unit
modifyLink conn f = H.modify_ $ case conn of
  Cmd -> \st -> st { cmd = map f st.cmd }
  Idle -> \st -> st { idle = map f st.idle }
  Lib -> \st -> st { lib = map f st.lib }

-- | What one message off the wire turns into: the complete lines it
-- | finished, with the unfinished tail left in the Ref for the next one.
-- |
-- | websocat frames by TCP read and not by line, so a message may carry
-- | several lines, part of one, or the end of one and the start of
-- | another. Only the tail is ever re-split, so this stays linear in the
-- | size of the reply however it is chopped up.
takeLines :: Link -> String -> Effect (Array String)
takeLines k raw = do
  held <- Ref.read k.partial
  let
    pieces = split (Pattern "\n") (held <> raw)
    complete = fromMaybe [] (Array.init pieces)
  Ref.write (fromMaybe "" (Array.last pieces)) k.partial
  pure (Array.filter (_ /= "") (map (\l -> fromMaybe l (stripSuffix (Pattern "\r") l)) complete))

-- | Add one line to the reply being collected. A string grows in place in
-- | every engine this runs on, where an array would be copied whole for
-- | every line of a ten thousand line reply.
pushLine :: Link -> String -> Effect Unit
pushLine k l = Ref.modify_ (_ <> l <> "\n") k.block

-- | The reply that just ended, as its lines, and the buffer emptied ready
-- | for the next one.
takeBlock :: Link -> Effect (Array String)
takeBlock k = do
  text <- Ref.read k.block
  Ref.write "" k.block
  pure (Array.filter (_ /= "") (split (Pattern "\n") text))

-- | One line to MPD, on the connection that owns that kind of work. The
-- | request joins that connection's own queue, so its reply is read
-- | against it and not against something another connection asked for.
-- | The idle connection sends only `idle` and keeps no queue.
send :: forall o m. MonadAff m => Conn -> Req -> String -> M o m Unit
send conn req line = do
  st <- H.get
  case linkOf conn st of
    -- Not greeted yet: hold it rather than drop it, and the greeting
    -- flushes what has piled up.
    Just k | not k.ready -> modifyLink conn \l -> l { queued = snoc l.queued { req, line } }
    Just k -> do
      liftEffect (WS.sendString k.socket line)
      when (conn /= Idle) (modifyLink conn \l -> l { asked = snoc l.asked req })
    _ -> pure unit

-- | What the page asks for the moment the command connection comes up.
-- | The queue itself is NOT here: `status` carries its length, which is
-- | all any view but the Queue needs, and fetching a few hundred entries
-- | nobody is looking at is what made browsing stall after queueing a
-- | track.
refreshAll :: forall o m. MonadAff m => M o m Unit
refreshAll = do
  send Cmd RStatus "status"
  send Cmd RCurrent "currentsong"
  send Cmd RStats "stats"
  -- Whether MPD can match a regular expression. Multi-value selections
  -- in the tag browser depend on it; the answer changes only with a
  -- different MPD build, so it is asked once per connection.
  send Cmd RProbe "find \"(title =~ '^$')\" window 0:1"

browse :: forall o m. MonadAff m => String -> M o m Unit
browse p = send Lib (RBrowse p) ("lsinfo " <> Mpd.quote p)
```

## packages/nixtune-web/src/Types.purs

```purescript
-- | What the page is, as data: the two roles, the three connections, the
-- | state the component carries, and every constant the rest of the
-- | modules agree on. Nothing here does anything; it is the vocabulary
-- | the other modules are written in, so it depends on none of them
-- | except Browse, which is the tag browser's own vocabulary.
module Types where

import Prelude

import Browse (Axis, Browser, emptyBrowser, tagOf)
import Caps (Caps, Station)
import Data.Array as Array
import Data.Maybe (Maybe(..), isJust, maybe)
import Data.Foldable (lookup)
import Data.String (Pattern(..), indexOf, split, trim)
import Data.Tuple (Tuple)
import Effect.Ref (Ref)
import Halogen as H
import Mpd (Entry, Song, Status)
import Mpd as Mpd
import Web.Event.Event (Event)
import Web.UIEvent.MouseEvent (MouseEvent)
import Web.Socket.WebSocket (WebSocket)
import Web.UIEvent.KeyboardEvent (KeyboardEvent)

-- | Which page this is. The host page has the transport, the queue, the
-- | volume and the QR code; the guest page has now playing and the
-- | library. Both reach the same websocket, so this is what the page
-- | offers, not what the player enforces.
data Role = Host | Guest

derive instance eqRole :: Eq Role

data View = NowPlaying | Queue | Library | Radio | Qr

derive instance eqView :: Eq View

-- | How the library is being looked at. The folder tree is what MPD
-- | indexes; the tag browser is what a person actually chooses music by.
data BrowseMode = Tags | Folders

derive instance eqBrowseMode :: Eq BrowseMode

-- | The three connections to MPD.
-- |
-- |   Cmd    transport, the queue, status, attribution
-- |   Idle   parked in MPD's idle command, told what changed
-- |   Lib    the library: browsing, the tag columns, search
-- |
-- | MPD answers one command at a time per connection, in order. Lib
-- | exists because of that: queueing a track makes MPD report a playlist
-- | change, the page answers by refetching the queue, and on a queue of
-- | a few hundred that reply is large. With one connection the next
-- | click on an artist waits behind it and the page looks dead, which
-- | invites a second click and a third. On its own connection a library
-- | query is never behind anything but another library query.
data Conn = Cmd | Idle | Lib

derive instance eqConn :: Eq Conn

-- | What a reply on a connection is for.
data Req
  = RStatus
  | RCurrent
  | RQueue
  | RStats
  | RBrowse String
  | RStickers
  | RVetoes
  -- A column's reply, with the generation it was asked at. A column is
  -- one `list` command whatever is selected, so one reply builds it.
  | RTagValues Axis Int
  -- A window of the track list:
  --
  --   gen     the selection it belongs to
  --   from    the row it starts at
  --   want    how many rows were asked for, so a short reply is visible
  | RTracks { gen :: Int, from :: Int, want :: Int }
  -- How many tracks the list's filter matches, at a generation.
  | RTrackCount Int
  -- Whether MPD takes regular expression filters, asked once per
  -- command connection. An ACK means it was built without pcre.
  | RProbe
  | RFire

-- | One connection: its socket, whether MPD has greeted on it, and two
-- | buffers.
-- |
-- | `asked` is this connection's own queue of outstanding requests, in
-- | the order they were sent, so a reply is read against the right one.
-- | `queued` is what was asked for before MPD had greeted on this
-- | connection. The three sockets open together and greet whenever they
-- | greet, so a request made in the reply to one of them can arrive
-- | before another is ready; without this it was dropped silently, and
-- | the column it was for simply never loaded.
-- |
-- | `partial` is the unfinished tail of the last message, because websocat
-- | frames by TCP read and not by line, and `block` is the reply being
-- | collected. Both are Refs rather than fields of this record, and Net
-- | says at length why: Halogen renders the page on every state update,
-- | and a reply of ten thousand lines collected through the state is ten
-- | thousand renders of the whole page.
-- |
-- | `serial` is which socket this is. A socket the page drops on purpose
-- | to cancel stale work goes on firing its close and message events
-- | after its replacement is live; every event carries the serial of the
-- | socket it came from, and one from a socket that is no longer the
-- | connection is ignored rather than mistaken for the player going
-- | away.
type Link =
  { socket :: WebSocket
  , serial :: Int
  , ready :: Boolean
  , asked :: Array Req
  , queued :: Array { req :: Req, line :: String }
  , partial :: Ref String
  , block :: Ref String
  }

-- | A queue row being dragged.
-- |
-- | The rows are measured once, when the drag starts, and not again: the
-- | list is not reordered under the finger, it is only drawn as though it
-- | had been, so the geometry the drag is reckoned against stays still.
-- | One `move` goes to MPD when the finger lifts, and the real order
-- | arrives back through the idle connection like any other change.
-- |
-- |   from     the row the drag started on, by index
-- |   startY   where the pointer went down, and where it is now
-- |   mids     the vertical middle of every row, at the moment of grabbing
-- |   advance  how far a displaced row moves: one row plus the gap
-- |   subs     the document listeners that run for the length of the drag
type Drag =
  { from :: Int
  , startY :: Number
  , y :: Number
  , mids :: Array Number
  , advance :: Number
  , subs :: Array H.SubscriptionId
  }

type State =
  { caps :: Maybe Caps
  , role :: Role
  , nickname :: String
  , view :: View
  , cmd :: Maybe Link
  , idle :: Maybe Link
  , lib :: Maybe Link
  -- How many sockets have been opened, which names the next one.
  , sockets :: Int
  , status :: Status
  , current :: Maybe Song
  , queue :: Array Song
  , songs :: Int
  -- MPD's db_update: the unix time of the last database update, and
  -- the key the browser's copy of the library index is stored under.
  , dbStamp :: Int
  , path :: String
  -- What is in the search box. The committed search is the browser's
  -- own (Browse.Browser.query); this is the text being typed, and
  -- queryTick names the latest keystroke so a pause can tell whether
  -- another came after it.
  , query :: String
  , queryTick :: Int
  , entries :: Array Entry
  , addedBy :: Array (Tuple String String)
  -- Who has voted against what, read from the nixtune.vetoes sticker.
  -- The value is the voters' nicknames, comma separated, so the count
  -- is distinct browsers rather than taps.
  , vetoes :: Array (Tuple String String)
  , error :: Maybe String
  , ticks :: Int
  -- Where the bar is being held. Shown immediately and kept until MPD
  -- reports that level back, so the thumb does not snap to a stale value
  -- between the command and the report.
  , volDraft :: Maybe Int
  -- The last level actually sent, and whether the sender is running. A
  -- drag produces an event per pixel; the sender turns that into one
  -- write per glide step, with the last value always sent.
  , volSent :: Maybe Int
  , volSending :: Boolean
  -- The level to return to when unmuting. MPD has no mute of its own.
  , volBeforeMute :: Maybe Int
  -- What is in the typed volume field while it is being edited. Nothing
  -- means the field shows the live level; a report from MPD arriving
  -- mid-keystroke must not overwrite what is being typed.
  , volText :: Maybe String
  -- The socket volume changes are written to, when the host has one.
  -- Null in capabilities.json means MPD takes them instead.
  , volLink :: Maybe { socket :: WebSocket, ready :: Boolean }
  -- Where the seek bar is being held. While this is set the one-second
  -- tick leaves elapsed alone, so the thumb does not fight the clock.
  , seekDraft :: Maybe Number
  -- Which cover file name is being tried for the current track. A
  -- library names them several ways and none of them is guaranteed, so
  -- the page walks the list as each one fails to load and shows nothing
  -- once the list runs out.
  , artTry :: Int
  -- The YouTube helper's socket, when the host has one; what is in the
  -- link field; whether a fetch is under way; and the last thing the
  -- helper said, shown under the field.
  , ytLink :: Maybe { socket :: WebSocket, ready :: Boolean }
  , ytText :: String
  , ytBusy :: Boolean
  , ytNote :: Maybe String
  -- The Clear button has been pressed once and is waiting for the
  -- second press that confirms it. The number names the press, so the
  -- timer that disarms it can tell whether a later press re-armed it.
  , clearArmed :: Maybe Int
  , clearTick :: Int
  -- The queue row under the finger, while one is being dragged.
  , drag :: Maybe Drag
  -- The tag browser or the folder tree.
  , mode :: BrowseMode
  -- The tag browser: its columns, their selections and the track list.
  , browser :: Browser
  }

initial :: State
initial =
  { caps: Nothing
  , role: Guest
  , nickname: ""
  , view: NowPlaying
  , cmd: Nothing
  , idle: Nothing
  , lib: Nothing
  , sockets: 0
  , status: Mpd.emptyStatus
  , current: Nothing
  , queue: []
  , songs: 0
  , dbStamp: 0
  , path: ""
  , query: ""
  , queryTick: 0
  , entries: []
  , addedBy: []
  , vetoes: []
  , error: Nothing
  , ticks: 0
  , volDraft: Nothing
  , volSent: Nothing
  , volSending: false
  , volBeforeMute: Nothing
  , volText: Nothing
  , seekDraft: Nothing
  , volLink: Nothing
  , artTry: 0
  , ytLink: Nothing
  , ytText: ""
  , ytBusy: false
  , ytNote: Nothing
  , clearArmed: Nothing
  , clearTick: 0
  , drag: Nothing
  , mode: Tags
  , browser: emptyBrowser 800.0
  }

data Action
  = Init
  | Opened Conn Int
  | Closed Conn Int
  | Chunk Conn Int String
  | Tick
  | Open View
  | Command String
  | SetVolume String
  | Nudge Int
  | ToggleMute
  | VolumeFocus
  | VolumeText String
  | CommitVolume
  | VolumeKey String
  | GrabRow Int Event
  | DragRow Event
  | DropRow
  | GripKey Int KeyboardEvent
  | VolOpened
  | VolClosed
  | ArtMissing
  | DragSeek String
  | CommitSeek String
  | Browse String
  | SetMode BrowseMode
  | ToggleGenreColumn
  -- A click on a value row: plain, shift or with the platform's
  -- modifier, which the handler reads off the event.
  | Choose Axis String MouseEvent
  -- The All row, or a chip on a phone: clear one column's selection.
  | ClearColumn Axis
  | JumpTo Axis String
  -- A click on a track row: plain picks one, the platform's modifier
  -- adds or removes one, shift extends from the last row picked.
  | ChooseTrack Int MouseEvent
  | ClearTracks
  | Scrolled Axis Event
  | ScrolledTracks Event
  -- The window changed size, or a view with lists in it was opened:
  -- measure the lists again.
  | Measure
  | Veto String (Maybe Int)
  | AddFilter
  | PlayFilter
  -- A keystroke in the search box, a pause after one, Enter, and the
  -- clear button.
  | SetQuery String
  | QueryPaused Int
  | Search Event
  | ClearQuery
  | PlayStation Station
  | AddPath String
  | PlayPath String
  | PlayPos Int
  | DeletePos Int
  -- Clearing the queue takes two presses: the first arms the button, the
  -- second within clearConfirmMs clears. The timer's disarm names the
  -- press it belongs to.
  | ClearQueue
  | ClearDisarm Int
  -- The YouTube helper: its socket opening and closing, a message off it,
  -- the link field, and the button that sends the link.
  | YtOpened
  | YtClosed
  | YtChunk String
  | YtText String
  | YtSubmit Event
  | UpdateLibrary

-- | The monad every handler and helper runs in.
type M o m = H.HalogenM State Action () o m

idleCommand :: String
idleCommand = "idle player mixer playlist options database update sticker"

stickerName :: String
stickerName = "nixtune.added_by"

vetoName :: String
vetoName = "nixtune.vetoes"

nicknameKey :: String
nicknameKey = "nixtune.nickname"

-- | How long typing has to pause before the search is applied, and how
-- | many characters it needs. Enter applies any length at once.
searchPauseMs :: Number
searchPauseMs = 250.0

searchMinChars :: Int
searchMinChars = 2

-- | How long the Clear button waits for the press that confirms it.
clearConfirmMs :: Number
clearConfirmMs = 3000.0

-- | The lowest level the bar itself can reach. The bar cannot silence the
-- | player: zero belongs to the mute button, which remembers what to come
-- | back to.
volumeFloor :: Int
volumeFloor = 1

-- | What one press of a stepper moves the level by.
volumeStep :: Int
volumeStep = 5

-- | Where unmute lands when no earlier level is remembered.
unmuteFloor :: Int
unmuteFloor = 20

-- | How far one step of the glide moves, and how long a step lasts. A
-- | press or a drag sets the target; the level walks to it rather than
-- | jumping, which is gentler on speakers and reads as deliberate rather
-- | than abrupt. A full-scale move takes about half a second.
volumeGlideStep :: Int
volumeGlideStep = 4

volumeGlideMs :: Number
volumeGlideMs = 40.0

maxVolumeOf :: State -> Int
maxVolumeOf st = maybe 100 _.maxVolume st.caps

-- | The level to show: the press just made, else what MPD last reported.
shownVolume :: State -> Maybe Int
shownVolume st = case st.volDraft of
  Just v -> Just v
  Nothing -> st.status.volume

-- | Has MPD reported the level the page asked for, give or take a step.
arrived :: Maybe Int -> Maybe Int -> Boolean
arrived want got = case want, got of
  Just a, Just b -> a - b <= 1 && b - a <= 1
  _, _ -> false

-- | A request whose failure is not worth a banner. A player whose
-- | sticker database is missing answers a sticker request with an error,
-- | and the only consequence is that nobody's name appears beside a queue
-- | entry. The regex probe failing is its answer, not a fault.
isQuiet :: Req -> Boolean
isQuiet = case _ of
  RStickers -> true
  RVetoes -> true
  RProbe -> true
  _ -> false

-- | Every attribution in the database, in one command.
stickerFind :: String
stickerFind = "sticker find song \"\" " <> stickerName

-- | Every vote in the database, likewise.
vetoFind :: String
vetoFind = "sticker find song \"\" " <> vetoName

-- | Who has voted against a track. The sticker holds nicknames
-- | separated by commas; a nickname is two words from the page's own
-- | lists and can never contain one.
votersAgainst :: State -> String -> Array String
votersAgainst st uri = case lookup uri st.vetoes of
  Nothing -> []
  Just raw -> Array.filter (_ /= "") (map trim (split (Pattern ",") raw))

-- | How many votes it takes.
vetoLimit :: State -> Int
vetoLimit st = maybe 3 _.vetoes st.caps

partyOn :: State -> Boolean
partyOn st = maybe false _.party st.caps

isStream :: String -> Boolean
isStream uri = isJust (indexOf (Pattern "://") uri)

-- | The scroll element of one column and of the track list, so a
-- | handler can move them and measure them.
colRef :: Axis -> H.RefLabel
colRef axis = H.RefLabel ("col-" <> tagOf axis)

tracksRef :: H.RefLabel
tracksRef = H.RefLabel "tracks"
```

## packages/nixtune-web/src/Main.purs

```purescript
-- | The player's page, in two roles from one bundle.
-- |
-- | Three websockets to MPD, each bridged by websocat to the daemon's TCP
-- | port. One carries commands and their replies, in order, so the page
-- | keeps a queue of what it asked and reads each reply against the head
-- | of that queue. One sits in MPD's `idle` command and is told what
-- | changed; the page then asks the first connection for the new status.
-- | One is the library's own, so a browse is never behind a queue fetch.
-- | Nothing is polled.
-- |
-- | What the page may show is read once from capabilities.json, which Nix
-- | wrote when the host was built. The ROLE is read from the path the page
-- | was opened at: capabilities.hostPath opens the host page (everything,
-- | plus the QR code); any other path opens the guest page, which shows
-- | now playing and lets a guest browse the library and append to the
-- | queue, and nothing else. The limit is the page's: both roles reach the
-- | same websocket, and there is no component on the player that knows
-- | which page a socket belongs to.
-- |
-- | A guest is named by a nickname this page generates on first visit and
-- | keeps in the browser's localStorage. When a guest appends a track the
-- | page also sets an MPD sticker on it, nixtune.added_by, which the host
-- | page reads back beside each queue entry.
-- |
-- | This module is the component: the state machine and the protocol. The
-- | rest is beside it.
-- |
-- |   Types.purs    the state, the actions, the constants
-- |   Browse.purs   the tag browser as data, and its arithmetic
-- |   Tags.purs     the tag browser's behaviour
-- |   Net.purs      the sockets and the requests
-- |   Volume.purs   the level, the glide, the bar
-- |   Reorder.purs  dragging a queue row
-- |   Art.purs      cover images from the library
-- |   Nick.purs     the role and the guest nickname
-- |   Cache.purs    the library index, kept between visits
-- |   Page.purs     everything drawn but the Library view
-- |   Library.purs  the Library view: search, tag browser, folders
-- |   Filter.purs   MPD filter expressions and their escaping
-- |   Youtube.purs  queueing a track from a YouTube link
-- |   Ui.purs       class attributes, glyphs, the format badge
-- |   Mpd.purs      the protocol's text, parsed
-- |   Caps.purs     capabilities.json
module Main (main) where

import Prelude

import Browse (emptyBrowser)
import Caps as Caps
import Data.Array (any, elem, filter, head, length, null, snoc, uncons, (:))
import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (for_)
import Data.Int (fromString, toNumber)
import Data.Maybe (Maybe(..), fromMaybe, isJust, isNothing, maybe)
import Data.Number as Number
import Data.String (joinWith, trim)
import Data.String.CodeUnits (toCharArray)
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Aff (Milliseconds(..), delay)
import Effect.Aff.Class (class MonadAff)
import Effect.Class (liftEffect)
import Effect.Timer (setInterval)
import Halogen as H
import Halogen.Aff as HA
import Halogen.Query.Event as HQE
import Halogen.Subscription as HS
import Halogen.VDom.Driver (runUI)
import Mpd (PlayState(..))
import Mpd as Mpd
import Net (browse, connect, connectVolume, connectYoutube, linkOf, liveLink, modifyLink, pushLine, refreshAll, send, setLink, takeBlock, takeLines)
import Nick (nicknameFor, roleFromPath)
import Page (render)
import Reorder (dragTarget, rowMiddles)
import Tags as Tags
import Types
  ( Action(..)
  , BrowseMode(..)
  , Conn(..)
  , M
  , Req(..)
  , Role(..)
  , View(..)
  , arrived
  , clearConfirmMs
  , idleCommand
  , initial
  , isQuiet
  , maxVolumeOf
  , searchMinChars
  , searchPauseMs
  , shownVolume
  , stickerFind
  , stickerName
  , unmuteFloor
  , vetoFind
  , vetoLimit
  , vetoName
  , volumeFloor
  , votersAgainst
  )
import Volume (setVolume)
import Youtube as Youtube
import Web.Event.Event (EventType(..), preventDefault)
import Web.HTML (window)
import Web.HTML.HTMLDocument as HTMLDocument
import Web.HTML.Window (document, innerHeight)
import Web.HTML.Window as Window
import Web.UIEvent.KeyboardEvent as KE
import Web.UIEvent.MouseEvent as MouseEvent

main :: Effect Unit
main = HA.runHalogenAff do
  body <- HA.awaitBody
  void (runUI component unit body)

component :: forall q i o m. MonadAff m => H.Component q i o m
component =
  H.mkComponent
    { initialState: const initial
    , render
    , eval: H.mkEval H.defaultEval { handleAction = handle, initialize = Just Init }
    }

handle :: forall o m. MonadAff m => Action -> M o m Unit
handle = case _ of
  Init -> do
    r <- H.liftAff Caps.fetch
    case r of
      Left e -> H.modify_ _ { error = Just ("capabilities.json could not be read: " <> e) }
      Right caps -> do
        role <- liftEffect (roleFromPath caps.hostPath)
        nick <- liftEffect nicknameFor
        win <- liftEffect window
        -- The lists are measured once they are on the page; until then
        -- the window's height is the guess, so nothing is drawn short.
        height <- liftEffect (innerHeight win)
        H.modify_ _ { caps = Just caps, role = role, nickname = nick, browser = emptyBrowser (toNumber height) }
        connect Cmd
        connect Idle
        connect Lib
        for_ caps.volumePath connectVolume
        for_ caps.youtubePath connectYoutube
        { emitter, listener } <- liftEffect HS.create
        _ <- liftEffect (setInterval 1000 (HS.notify listener Tick))
        void (H.subscribe emitter)
        void (H.subscribe (HQE.eventListener (EventType "resize") (Window.toEventTarget win) (const (Just Measure))))
  Opened _ _ -> pure unit
  -- Only the socket the connection is actually using closing means the
  -- player went away. A socket dropped on purpose to cancel stale work
  -- closes too, moments after its replacement is live, and that is not
  -- an outage and must not take the new socket down with it.
  Closed conn serial -> do
    st <- H.get
    when (isJust (liveLink conn serial st)) do
      setLink conn Nothing
      when (conn == Lib) Tags.dropPending
      H.modify_ _ { error = Just "The player went away. Reconnecting." }
      H.liftAff (delay (Milliseconds 2000.0))
      connect conn
  -- One message off the wire. Everything here that is not the end of a
  -- reply happens in Refs, through liftEffect, and touches no component
  -- state: Halogen renders the whole page on every state update, and a
  -- ten thousand line reply collected through the state rendered the
  -- page ten thousand times, which is what made opening the Library take
  -- most of a minute against a player that answered in under a second.
  Chunk conn serial raw -> do
    st <- H.get
    for_ (liveLink conn serial st) \k -> do
      lines <- liftEffect (takeLines k raw)
      for_ lines \line ->
        if Mpd.isGreeting line || Mpd.isEnd line then finished conn line
        else liftEffect (pushLine k line)
  Tick -> do
    before <- H.get
    let
      -- The host's clock is in the player bar, on every view; a guest's
      -- is on the Now playing card only, so a guest's page does not
      -- re-render once a second for a clock nobody is looking at. Every
      -- list on the page is drawn a slice at a time, so a render is a
      -- few hundred nodes whatever the library holds. Open NowPlaying
      -- asks for `status`, so a guest's clock is right again the moment
      -- it is visible.
      running =
        (before.role == Host || before.view == NowPlaying)
          && before.status.state == Playing
          && isNothing before.seekDraft
          && before.status.duration > 0.0
          && before.status.elapsed < before.status.duration
    when running $
      H.modify_ \st -> st { status = st.status { elapsed = st.status.elapsed + 1.0 } }
    -- A scan that runs for days changes the "database" subsystem only at
    -- its end, so the count is asked for every ten seconds while it runs.
    -- The counter only turns while a scan is running, which keeps an
    -- idle page from re-rendering on a timer at all.
    when before.status.updating do
      H.modify_ \st -> st { ticks = st.ticks + 1 }
      st <- H.get
      when (st.ticks `mod` 10 == 0) do
        send Cmd RStats "stats"
        when (st.view == Library) $ case st.mode of
          Folders -> browse st.path
          Tags -> Tags.recount
  Open v -> do
    H.modify_ _ { view = v }
    -- The clock stops advancing while another view is up (see Tick), so
    -- it is resynced on the way back rather than kept warm the whole
    -- time at the cost of a re-render a second.
    when (v == NowPlaying) (send Cmd RStatus "status")
    -- The queue is fetched when the Queue view opens and not before. On
    -- a few hundred entries that reply is the most expensive thing the
    -- page asks for, and every other view needs only its length, which
    -- `status` already carries.
    when (v == Queue) do
      send Cmd RQueue "playlistinfo"
      send Cmd RStickers stickerFind
      send Cmd RVetoes vetoFind
    when (v == Library) do
      st <- H.get
      case st.mode of
        Folders -> browse st.path
        Tags -> showTags
  Measure -> Tags.measure
  Command c -> send Cmd RFire c
  SetVolume raw -> for_ (fromString raw) \v -> do
    top <- H.gets maxVolumeOf
    H.modify_ _ { volBeforeMute = Nothing }
    setVolume (clamp volumeFloor top v)
  Nudge by -> do
    st <- H.get
    for_ (shownVolume st) \now -> do
      -- Floored like the bar, so a stepper can never silence the player.
      let
        v = clamp volumeFloor (maxVolumeOf st) (now + by)
      when (v /= now) do
        H.modify_ _ { volBeforeMute = Nothing }
        setVolume v
  VolumeFocus -> do
    st <- H.get
    H.modify_ _ { volText = Just (maybe "" show (shownVolume st)) }
  VolumeText t -> H.modify_ _ { volText = Just t }
  -- Committed on Enter and on leaving the field, not on the change event:
  -- Halogen writes the value property on every render, which clears the
  -- browser's dirty flag, and an input the browser thinks is unmodified
  -- never fires change. Typing a level and pressing Done would have been
  -- silently dropped.
  CommitVolume -> do
    st <- H.get
    H.modify_ _ { volText = Nothing }
    for_ (st.volText >>= (fromString <<< trim)) \typed -> do
      -- A typed zero is a deliberate silence, so it is allowed where the
      -- bar's floor forbids it, and it remembers where to come back to.
      if typed <= 0 then do
        for_ (shownVolume st) \now -> when (now > 0) (H.modify_ _ { volBeforeMute = Just now })
        setVolume 0
      else do
        H.modify_ _ { volBeforeMute = Nothing }
        setVolume (clamp volumeFloor (maxVolumeOf st) typed)
  VolumeKey k -> when (k == "Enter") (handle CommitVolume)
  GrabRow i ev -> do
    st <- H.get
    -- A pointer event is a mouse event, so one pair of handlers covers a
    -- mouse, a finger and a stylus. preventDefault stops the drag being
    -- read as a text selection; touch-action on the handle stops it
    -- being read as a scroll.
    for_ (MouseEvent.fromEvent ev) \me -> when (isNothing st.drag && length st.queue > 1) do
      liftEffect (preventDefault ev)
      mids <- rowMiddles (length st.queue)
      when (length mids == length st.queue) do
        doc <- liftEffect (window >>= document)
        let
          target = HTMLDocument.toEventTarget doc
          y = toNumber (MouseEvent.clientY me)
          at j = fromMaybe 0.0 (Array.index mids j)
          advance = case Array.index mids (i + 1), Array.index mids (i - 1) of
            Just below, _ -> below - at i
            _, Just above -> at i - above
            _, _ -> 0.0
        -- Listened for on the document, not the row: a finger that
        -- outruns the row still steers the drag, and a pointer released
        -- anywhere at all ends it.
        move <- H.subscribe (HQE.eventListener (EventType "pointermove") target (Just <<< DragRow))
        up <- H.subscribe (HQE.eventListener (EventType "pointerup") target (const (Just DropRow)))
        off <- H.subscribe (HQE.eventListener (EventType "pointercancel") target (const (Just DropRow)))
        H.modify_ _ { drag = Just { from: i, startY: y, y, mids, advance, subs: [ move, up, off ] } }
  DragRow ev -> do
    st <- H.get
    for_ st.drag \d -> for_ (MouseEvent.fromEvent ev) \me ->
      H.modify_ _ { drag = Just (d { y = toNumber (MouseEvent.clientY me) }) }
  DropRow -> do
    st <- H.get
    for_ st.drag \d -> do
      for_ d.subs H.unsubscribe
      H.modify_ _ { drag = Nothing }
      let
        to = dragTarget d
        at j = fromMaybe j (Array.index st.queue j >>= _.pos)
      when (to /= d.from) (send Cmd RFire ("move " <> show (at d.from) <> " " <> show (at to)))
  GripKey pos ev -> do
    st <- H.get
    let
      lastPos = length st.queue - 1
    case KE.key ev of
      "ArrowUp" -> when (pos > 0) do
        liftEffect (preventDefault (KE.toEvent ev))
        send Cmd RFire ("move " <> show pos <> " " <> show (pos - 1))
      "ArrowDown" -> when (pos < lastPos) do
        liftEffect (preventDefault (KE.toEvent ev))
        send Cmd RFire ("move " <> show pos <> " " <> show (pos + 1))
      _ -> pure unit
  ToggleMute -> do
    st <- H.get
    for_ (shownVolume st) \now ->
      if now > 0 then do
        H.modify_ _ { volBeforeMute = Just now }
        setVolume 0
      else do
        -- Always restores to something audible. A player left silent with
        -- no earlier level remembered comes back at unmuteFloor rather
        -- than leaving the button doing nothing, which is the dead state
        -- the first version of this had.
        let
          back = clamp volumeFloor (maxVolumeOf st) (fromMaybe unmuteFloor st.volBeforeMute)
        H.modify_ _ { volBeforeMute = Nothing }
        setVolume back
  VolOpened -> H.modify_ \st -> st { volLink = map (_ { ready = true }) st.volLink }
  VolClosed -> do
    H.modify_ _ { volLink = Nothing }
    H.liftAff (delay (Milliseconds 2000.0))
    path <- H.gets (\st -> st.caps >>= _.volumePath)
    for_ path connectVolume
  ArtMissing -> H.modify_ \st -> st { artTry = st.artTry + 1 }
  DragSeek raw -> for_ (Number.fromString raw) \t ->
    H.modify_ _ { seekDraft = Just t }
  CommitSeek raw -> for_ (Number.fromString raw) \t -> do
    H.modify_ \st -> st { seekDraft = Nothing, status = st.status { elapsed = t } }
    send Cmd RFire ("seekcur " <> show t)
  Browse p -> do
    H.modify_ _ { mode = Folders }
    browse p
  SetMode m -> do
    H.modify_ _ { mode = m }
    st <- H.get
    case m of
      Folders -> browse st.path
      Tags -> showTags
  ToggleGenreColumn -> Tags.toggleGenreColumn
  Choose axis v ev -> Tags.choose axis v ev
  ClearColumn axis -> Tags.clearColumn axis
  JumpTo axis l -> Tags.jumpTo axis l
  ChooseTrack row ev -> Tags.chooseTrack row ev
  ClearTracks -> Tags.clearPicked
  Scrolled axis ev -> Tags.scrolled axis ev
  ScrolledTracks ev -> Tags.scrolledTracks ev
  AddFilter -> Tags.filterCommand false
  PlayFilter -> Tags.filterCommand true
  -- One browser, one vote, per track. The tally is an MPD sticker on the
  -- track's URI, so every page sees the same number without anything on
  -- the player keeping score. Whoever casts the deciding vote is the one
  -- that removes the track, by id rather than by position so a racing
  -- removal cannot take the wrong one, and clears the tally so the track
  -- does not arrive pre-vetoed if somebody queues it again.
  Veto uri songId -> do
    st <- H.get
    let
      voters = votersAgainst st uri
      me = st.nickname
      updated = if elem me voters then voters else snoc voters me
    when (not (elem me voters)) do
      send Cmd RFire ("sticker set song " <> Mpd.quote uri <> " " <> vetoName <> " " <> Mpd.quote (joinWith "," updated))
      H.modify_ \s -> s { vetoes = (Tuple uri (joinWith "," updated)) : filter (\(Tuple u _) -> u /= uri) s.vetoes }
    when (length updated >= vetoLimit st) do
      -- Every copy of this track goes, because the tally is per URI and
      -- leaving a second copy queued would make the vote meaningless.
      for_ (filter (\q -> q.file == uri) st.queue) \q ->
        for_ q.id \i -> send Cmd RFire ("deleteid " <> show i)
      for_ songId \i -> when (not (any (\q -> q.file == uri) st.queue)) (send Cmd RFire ("deleteid " <> show i))
      send Cmd RFire ("sticker delete song " <> Mpd.quote uri <> " " <> vetoName)
      H.modify_ \s -> s { vetoes = filter (\(Tuple u _) -> u /= uri) s.vetoes }
  -- The search narrows the columns and the list as it is typed, once
  -- typing pauses. Each keystroke takes a number; a pause applies the
  -- search only if no keystroke came after the one it was waiting on.
  SetQuery q -> do
    st <- H.modify \s -> s { query = q, queryTick = s.queryTick + 1 }
    let
      tick = st.queryTick
    void $ H.fork do
      H.liftAff (delay (Milliseconds searchPauseMs))
      handle (QueryPaused tick)
  QueryPaused tick -> do
    st <- H.get
    when (tick == st.queryTick) (Tags.commitQuery (typedQuery false st.query))
  -- Enter applies whatever is there, however short, at once.
  Search ev -> do
    liftEffect (preventDefault ev)
    st <- H.modify \s -> s { queryTick = s.queryTick + 1 }
    Tags.commitQuery (typedQuery true st.query)
  ClearQuery -> do
    H.modify_ \s -> s { query = "", queryTick = s.queryTick + 1 }
    Tags.commitQuery Nothing
  PlayStation s -> do
    send Cmd RFire "clear"
    send Cmd RFire ("add " <> Mpd.quote s.url)
    send Cmd RFire "play"
    H.modify_ _ { view = NowPlaying }
  AddPath p -> do
    st <- H.get
    send Cmd RFire ("add " <> Mpd.quote p)
    when (st.role == Guest) do
      -- Attribution, on the file itself. For a folder MPD has no single
      -- URI to sticker, so a folder appended by a guest is unattributed.
      send Cmd RFire ("sticker set song " <> Mpd.quote p <> " " <> stickerName <> " " <> Mpd.quote st.nickname)
      H.modify_ \s -> s { addedBy = (Tuple p st.nickname) : s.addedBy }
      -- The one transport command a guest can cause: a silent player
      -- starts when a guest adds something to it.
      when (st.status.state == Stopped) (send Cmd RFire "play")
  PlayPath p -> do
    send Cmd RFire "clear"
    send Cmd RFire ("add " <> Mpd.quote p)
    send Cmd RFire "play"
    H.modify_ _ { view = NowPlaying }
  PlayPos n -> send Cmd RFire ("play " <> show n)
  DeletePos n -> send Cmd RFire ("delete " <> show n)
  ClearQueue -> do
    st <- H.get
    case st.clearArmed of
      Just _ -> do
        H.modify_ _ { clearArmed = Nothing }
        send Cmd RFire "clear"
      Nothing -> do
        let
          press = st.clearTick + 1
        H.modify_ _ { clearArmed = Just press, clearTick = press }
        void $ H.fork do
          H.liftAff (delay (Milliseconds clearConfirmMs))
          handle (ClearDisarm press)
  ClearDisarm press -> do
    armed <- H.gets _.clearArmed
    when (armed == Just press) (H.modify_ _ { clearArmed = Nothing })
  UpdateLibrary -> send Cmd RFire "update"
  YtOpened -> Youtube.opened
  YtClosed -> Youtube.closed
  YtChunk raw -> Youtube.received raw
  YtText t -> H.modify_ _ { ytText = t }
  YtSubmit ev -> Youtube.submit ev

-- | The tag browser has just come on screen. Its columns were fetched at
-- | startup, so this usually asks for nothing; a page whose fetch never
-- | happened (the library connection came up after the stamp) asks now.
-- | Either way the new elements are put where the state says they were
-- | and measured.
showTags :: forall o m. MonadAff m => M o m Unit
showTags = do
  st <- H.get
  when (null st.browser.artist.values && not st.browser.artist.pending) Tags.reload
  Tags.sync

-- | A greeting, or the line that ends a reply. These are the only two
-- | lines off the wire that change anything the page draws.
finished :: forall o m. MonadAff m => Conn -> String -> M o m Unit
finished conn l
  | Mpd.isGreeting l = do
      modifyLink conn _ { ready = true }
      H.modify_ _ { error = Nothing }
      held <- H.gets (maybe [] _.queued <<< linkOf conn)
      modifyLink conn _ { queued = [] }
      for_ held \h -> send conn h.req h.line
      case conn of
        Cmd -> refreshAll
        Idle -> send Idle RFire idleCommand
        -- The library connection asks for nothing until a view wants
        -- something from it, and a socket opened to cancel stale work
        -- already carries what the click asked for in `queued`. Only a
        -- connection that came back with nothing waiting on it has to
        -- ask again.
        Lib -> when (Array.null held) do
          st <- H.get
          when (st.view == Library) $ case st.mode of
            Folders -> browse st.path
            Tags -> Tags.reload
  | otherwise = do
      st <- H.get
      block <- case linkOf conn st of
        Just k -> liftEffect (takeBlock k)
        Nothing -> pure []
      case conn of
        Idle -> do
          changed block
          send Idle RFire idleCommand
        _ -> case uncons (maybe [] _.asked (linkOf conn st)) of
          Nothing -> pure unit
          Just { head: req, tail } -> do
            modifyLink conn _ { asked = tail }
            -- A missing sticker is reported by MPD as an error; it is
            -- the normal state of a track nobody attributed.
            when (Mpd.isError l && not (isQuiet req)) (H.modify_ _ { error = Just l })
            unless (Mpd.isError l) (reply req block)

-- | The idle connection's reply: which subsystems changed.
changed :: forall o m. MonadAff m => Array String -> M o m Unit
changed block = do
  send Cmd RStatus "status"
  send Cmd RCurrent "currentsong"
  st <- H.get
  when (elem "changed: playlist" block && st.view == Queue) (send Cmd RQueue "playlistinfo")
  when (elem "changed: sticker" block && st.view == Queue) do
    send Cmd RStickers stickerFind
    send Cmd RVetoes vetoFind
  -- A vote removes a track, so a guest watching the queue needs the
  -- playlist back even though the page's own tab is what gates the
  -- fetch above.
  when (elem "changed: playlist" block && st.view == Queue) (send Cmd RVetoes vetoFind)
  when (elem "changed: database" block || elem "changed: update" block) do
    -- Only the folder tree is refreshed here. The tag columns follow
    -- the database stamp that this `stats` carries, so reloading them
    -- here as well would fetch the artist list twice for one rescan.
    send Cmd RStats "stats"
    when (st.view == Library && st.mode == Folders) (browse st.path)

-- | A command connection's reply, read against what was asked.
reply :: forall o m. MonadAff m => Req -> Array String -> M o m Unit
reply req block = case req of
  RStatus -> do
    let
      status = Mpd.parseStatus block
      done st = not st.volSending && arrived st.volDraft status.volume
    H.modify_ \st ->
      st
        { status = status
        -- Cleared when MPD reports the level that was asked for, but
        -- only once the glide has finished: a report arriving mid-glide
        -- would otherwise end it early. One unit of slack, because the
        -- mapped write lands on the nearest 0.5 dB step and reading that
        -- back can round the other way.
        , volDraft = if done st then Nothing else st.volDraft
        , volSent = if done st then Nothing else st.volSent
        }
  RCurrent -> do
    let
      cur = head (Mpd.parseSongs block)
    H.modify_ \st ->
      st
        { current = cur
        , artTry = if map _.file cur == map _.file st.current then st.artTry else 0
        }
  RQueue -> H.modify_ _ { queue = Mpd.parseSongs block }
  RStats -> do
    before <- H.gets _.dbStamp
    let
      stats = Mpd.parseStats block
    H.modify_ _ { songs = stats.songs, dbStamp = stats.stamp }
    Tags.setLibraryCount stats.songs
    -- The index is fetched as soon as the stamp is known, not when the
    -- Library tab is first opened, so the column is already there when
    -- it is. On a warm cache this costs nothing at all.
    when (stats.stamp /= before) do
      mode <- H.gets _.mode
      when (mode == Tags) Tags.reload
  RBrowse p -> H.modify_ _ { path = p, entries = Mpd.parseEntries block }
  RStickers -> H.modify_ _ { addedBy = Mpd.parseStickers block }
  RVetoes -> H.modify_ _ { vetoes = Mpd.parseStickers block }
  RTagValues axis gen -> Tags.tagValues axis gen block
  RTrackCount gen -> Tags.trackCount gen block
  RTracks w -> Tags.tracks w block
  -- An OK is the answer; the reply's rows do not matter.
  RProbe -> Tags.modifyBrowser _ { regex = true }
  RFire -> pure unit

-- | What the search box holds, as a search: trimmed, and Nothing when it
-- | is empty or, unless Enter was pressed, shorter than searchMinChars.
typedQuery :: Boolean -> String -> Maybe String
typedQuery enter raw =
  let
    q = trim raw
  in
    if q == "" then Nothing
    else if enter || length (toCharArray q) >= searchMinChars then Just q
    else Nothing
```

## packages/nixtune-web/src/Page.purs

```purescript
-- | Everything the page draws apart from the Library view, which is in
-- | Library. No effects here: each function is state in, markup out, and
-- | every button names an Action for Main to handle.
module Page where

import Prelude

import Art (artUrl)
import Caps (Station)
import Data.Array (elem, length, null)
import Data.Array as Array
import Data.Foldable (lookup)
import Data.Maybe (Maybe(..), fromMaybe, isJust, isNothing, maybe)
import Data.String (joinWith)
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP
import Library (libraryView)
import Mpd (PlayState(..))
import Mpd as Mpd
import Player (playerBar, seekRow)
import Reorder (rowRef, rowShift)
import Types
  ( Action(..)
  , Role(..)
  , State
  , View(..)
  , isStream
  , partyOn
  , vetoLimit
  , votersAgainst
  )
import Ui (classes, cls, formatBadge, iconSized)
import Web.Event.Event (EventType(..))

render :: forall m. State -> H.ComponentHTML Action () m
render st = HH.main_
  [ HH.header [ cls "top" ]
      [ HH.div [ cls "brand" ]
          [ HH.span [ classes [ "dot", if online then "on" else "off" ] ] []
          , HH.span_ [ HH.text "nixtune" ]
          , HH.span [ cls "host" ] [ HH.text (maybe "" _.hostname st.caps) ]
          ]
      , HH.div [ cls "badges" ]
          ( map badge renderers
              <> [ HH.span [ classes ([ "badge" ] <> (if st.status.updating then [ "scanning" ] else [])) ]
                     [ HH.text (show st.songs <> " songs" <> (if st.status.updating then " · scanning" else "")) ]
                 ]
          )
      ]
  , HH.nav [ cls "tabs" ] tabs
  , HH.section [ cls "page" ] $ case st.view of
      NowPlaying -> nowPlaying st
      Queue -> queueView st
      Library -> libraryView st
      Radio -> radioView stations
      Qr -> qrView st
  , errorView st.error
  , if st.role == Host then playerBar st else HH.footer [ cls "me" ] [ HH.text ("you are " <> st.nickname) ]
  ]
  where
  online = maybe false _.ready st.cmd
  renderers = Array.filter (_ /= "mpd") (maybe [] _.modules st.caps)
  hasLibrary = maybe false _.library st.caps
  stations = maybe [] _.stations st.caps
  -- From `status`, not from the page's copy of the queue: the queue
  -- itself is only fetched while the Queue view is open.
  count = if st.status.queueLength == 0 then "" else " (" <> show st.status.queueLength <> ")"
  tabs = case st.role of
    Guest ->
      [ tab NowPlaying "Now playing" ]
        -- In party mode a guest sees the queue, so there is something to
        -- vote against.
        <> (if partyOn st then [ tab Queue ("Queue" <> count) ] else [])
        <> (if hasLibrary then [ tab Library "Library" ] else [])
    Host ->
      [ tab NowPlaying "Now playing", tab Queue ("Queue" <> count) ]
        <> (if hasLibrary then [ tab Library "Library" ] else [])
        <> (if null stations then [] else [ tab Radio "Radio" ])
        <> [ tab Qr "QR" ]
  tab v label =
    HH.button
      [ classes ([ "tab" ] <> (if st.view == v then [ "current" ] else []))
      , HE.onClick \_ -> Open v
      ]
      [ HH.text label ]

badge :: forall w i. String -> HH.HTML w i
badge m = HH.span [ cls "badge" ] [ HH.text (badgeName m) ]

badgeName :: String -> String
badgeName = case _ of
  "airplay" -> "AirPlay"
  "upnp_renderer" -> "UPnP"
  "spotify_connect" -> "Spotify"
  "squeezelite" -> "Squeezelite"
  "bluetooth" -> "Bluetooth"
  other -> other

whoAdded :: State -> String -> Maybe String
whoAdded st uri = lookup uri st.addedBy

-- | What the DAC is being fed, while something plays: the file's format,
-- | then the depth and rate the decoder is producing, then the bit rate
-- | for a stream, which is the only figure a stream has.
qualityBadges :: forall w i. State -> Array (HH.HTML w i)
qualityBadges st = case st.current of
  Nothing -> []
  Just song ->
    [ formatBadge song.file ]
      <> maybe [] (\r -> [ HH.span [ cls "fmt rate" ] [ HH.text r ] ]) rate
      <> maybe [] (\b -> [ HH.span [ cls "fmt rate" ] [ HH.text (show b <> " kbps") ] ]) kbps
  where
  rate = st.status.audio >>= Mpd.streamFormat
  -- Printed for a stream, where there is no file to name and no fixed
  -- depth; for a local file the depth and rate above say more.
  kbps = case st.current of
    Just s | isStream s.file -> st.status.bitrate
    _ -> Nothing

nowPlaying :: forall m. State -> Array (H.ComponentHTML Action () m)
nowPlaying st =
  [ HH.div [ classes ([ "now" ] <> (if isJust (artUrl st) then [ "withart" ] else [])) ]
      [ case artUrl st of
          Just url ->
            HH.img
              [ cls "art"
              , HP.src url
              , HP.alt ""
              , HE.onError \_ -> ArtMissing
              ]
          Nothing -> HH.text ""
      , HH.div [ cls "meta" ]
          [ HH.div [ cls "title" ] [ HH.text (maybe "Nothing queued" Mpd.songTitle st.current) ]
          , HH.div [ cls "line" ] [ HH.text (maybe "" Mpd.songLine st.current) ]
          , case qualityBadges st of
              [] -> HH.text ""
              bs -> HH.div [ cls "fmts" ] bs
          , case st.current >>= \s -> whoAdded st s.file of
              Just who -> HH.div [ cls "added" ] [ HH.text ("added by " <> who) ]
              Nothing -> HH.text ""
          ]
      -- The host's position is in the player bar under every view, with
      -- the transport it belongs with. A guest has no bar, so a guest's
      -- card keeps a plain progress line.
      , if st.role == Guest && st.status.duration > 0.0 then seekRow st else HH.text ""
      ]
  ]
    <>
      -- The transport and the position live in the bar at the bottom of
      -- every view (Player.playerBar). Here are the four MPD playback
      -- modes and Clear, which is the queue-wide action a host reaches
      -- for from this view. There is no Stop: pause does what a person
      -- means by it, and the bar has pause.
      ( if st.role == Host then
          [ HH.div [ cls "modes" ]
              [ toggle "Random" st.status.random ("random " <> flag st.status.random)
              , toggle "Repeat" st.status.repeat ("repeat " <> flag st.status.repeat)
              , toggle "Single" st.status.single ("single " <> flag st.status.single)
              , toggle "Consume" st.status.consume ("consume " <> flag st.status.consume)
              , clearButton st
              ]
          ]
        else
          [ HH.p [ cls "note" ] [ HH.text stateLine ] ]
      )
  where
  flag b = if b then "0" else "1"
  stateLine = case st.status.state of
    Playing -> "Playing. Add something from the library and it joins the queue."
    Paused -> "Paused by the host."
    Stopped -> "Nothing playing. The first thing you add starts it."
  toggle label on command =
    HH.button
      [ classes ([ "mode" ] <> (if on then [ "on" ] else []))
      , HE.onClick \_ -> Command command
      ]
      [ HH.text label ]

-- | Clear the queue, in two presses. MPD has no undo for `clear`, and a
-- | queue a room spent an evening building is one stray tap from gone, so
-- | the first press arms the button and says so, and only a second press
-- | within a few seconds clears.
clearButton :: forall m. State -> H.ComponentHTML Action () m
clearButton st =
  HH.button
    [ classes ([ "mode", "clear" ] <> (if armed then [ "armed" ] else []))
    , HP.disabled (st.status.queueLength == 0)
    , HP.title (if armed then "Press again to clear the queue" else "Clear the queue")
    , HE.onClick \_ -> ClearQueue
    ]
    [ HH.text (if armed then "Press again to clear" else "Clear queue") ]
  where
  armed = isJust st.clearArmed

queueView :: forall m. State -> Array (H.ComponentHTML Action () m)
queueView st =
  youtubeForm st
    <>
  [ if st.role == Host then
      HH.div [ cls "row-actions" ]
        [ clearButton st ]
    else if partyOn st then
      HH.p [ cls "note" ]
        [ HH.text ("Vote a track off and it goes when " <> show (vetoLimit st) <> " people agree. One vote each.") ]
    else HH.text ""
  , if null st.queue then HH.p [ cls "empty" ] [ HH.text "The queue is empty. Add something from the library or pick a station." ]
    else HH.ul [ classes ([ "list" ] <> (if isJust st.drag then [ "dragging" ] else [])) ] (Array.mapWithIndex item st.queue)
  ]
  where
  -- Where the player is. Everything before it has been played, which is
  -- what dims those rows; with random on the order is not the order they
  -- were heard in, so nothing is dimmed.
  playing = st.status.song
  held = map _.from st.drag
  item i s =
    HH.li
      ( [ HP.ref (rowRef i)
        , classes
            ( [ "song" ]
                <> (if Just pos == playing then [ "current" ] else [])
                <> (if not st.status.random && playing /= Nothing && Just pos < playing then [ "past" ] else [])
                <> (if held == Just i then [ "held" ] else [])
            )
        ]
          -- The style is left off entirely for a row that is not moving,
          -- which is almost all of them: a pointer event redraws the whole
          -- list, and a queue of a few hundred makes the difference between
          -- one attribute to compare per row and none worth having.
          <> ( case rowShift st.drag i of
                 0.0 -> []
                 dy -> [ HP.style ("transform: translateY(" <> show dy <> "px)") ]
             )
      )
      ( ( if st.role == Host then
            [ HH.button
                [ cls "grip"
                , HP.title "Drag to reorder, or focus and use the arrow keys"
                , HE.handler (EventType "pointerdown") (GrabRow i)
                , HE.onKeyDown (GripKey pos)
                ]
                [ iconSized "sm" "grip" ]
            ]
          else []
        )
          <> [ rowBody, formatBadge s.file, HH.span [ cls "time" ] [ HH.text (if s.duration > 0.0 then Mpd.clock s.duration else "") ] ]
          <> (if partyOn st then [ vetoButton st s ] else [])
          <>
            ( if st.role == Host then
                [ HH.button [ cls "ghost icon-btn", HP.title "Remove", HE.onClick \_ -> DeletePos pos ] [ iconSized "sm" "x" ] ]
              else []
            )
      )
    where
    -- The queue arrives in order, so the index is the position. Pos from
    -- MPD is used when it is there and the index covers a reply that
    -- left it out.
    pos = fromMaybe i s.pos
    rowBody =
      if st.role == Host then HH.button [ cls "grow", HE.onClick \_ -> PlayPos pos ] rowInner
      else HH.div [ cls "grow" ] rowInner
    rowInner =
      [ HH.div [ cls "title" ] [ HH.text (Mpd.songTitle s) ]
      , HH.div [ cls "line" ]
          [ HH.text
              ( joinWith " · "
                  (Array.filter (_ /= "") [ Mpd.songLine s, maybe "" (\w -> "added by " <> w) (whoAdded st s.file) ])
              )
          ]
      ]

-- | A YouTube link to fetch into the library and queue, on the host page
-- | of a host built with services.nixtune.youtube. The field stays as
-- | typed while the fetch runs and empties when the track is queued; the
-- | line under it is the last thing the helper said.
youtubeForm :: forall m. State -> Array (H.ComponentHTML Action () m)
youtubeForm st =
  if st.role /= Host || isNothing (st.caps >>= _.youtubePath) then []
  else
    [ HH.div [ cls "libtop" ]
        [ HH.form [ cls "search", HE.onSubmit YtSubmit ]
            [ HH.input
                [ HP.type_ HP.InputUrl
                , HP.placeholder "YouTube link to add to the queue"
                , HP.value st.ytText
                , HP.disabled st.ytBusy
                , HE.onValueInput YtText
                ]
            , HH.button
                [ HP.type_ HP.ButtonSubmit
                , HP.disabled (st.ytBusy || st.ytText == "" || not (maybe false _.ready st.ytLink))
                ]
                [ HH.text (if st.ytBusy then "Fetching…" else "Fetch") ]
            ]
        ]
    ]
      <> maybe [] (\note -> [ HH.p [ cls "note" ] [ HH.text note ] ]) st.ytNote

-- | The veto button and its tally. One vote per browser: a browser that
-- | has already voted sees the count and a disabled button, because the
-- | honest thing to show is that its vote is in, not a button that does
-- | nothing.
vetoButton :: forall m. State -> Mpd.Song -> H.ComponentHTML Action () m
vetoButton st s =
  HH.button
    [ classes ([ "veto" ] <> (if mine then [ "mine" ] else []) <> (if cast > 0 then [ "some" ] else []))
    , HP.disabled mine
    , HP.title title
    , HE.onClick \_ -> Veto s.file s.id
    ]
    [ iconSized "sm" "down", HH.span_ [ HH.text (show cast <> "/" <> show limit) ] ]
  where
  voters = votersAgainst st s.file
  cast = length voters
  limit = vetoLimit st
  mine = elem st.nickname voters
  title =
    if mine then "You voted against this: " <> show cast <> " of " <> show limit
    else "Vote against this track"

radioView :: forall m. Array Station -> Array (H.ComponentHTML Action () m)
radioView stations =
  [ HH.ul [ cls "list" ] (map station stations) ]
  where
  station s =
    HH.li [ cls "song" ]
      [ HH.button [ cls "grow", HE.onClick \_ -> PlayStation s ]
          [ HH.div [ cls "title" ] [ HH.text s.name ]
          , HH.div [ cls "line" ] [ HH.text s.url ]
          ]
      ]

qrView :: forall m. State -> Array (H.ComponentHTML Action () m)
qrView st =
  [ HH.div [ cls "qr" ]
      [ HH.img [ HP.src "qr.svg", HP.alt "QR code for the guest page" ]
      , HH.p [ cls "url" ] [ HH.text (maybe "" _.publicUrl st.caps) ]
      , HH.p [ cls "note" ] [ HH.text "Anyone who scans this gets the guest page: now playing, and the library to add from." ]
      ]
  ]

errorView :: forall w i. Maybe String -> HH.HTML w i
errorView = case _ of
  Just e -> HH.p [ cls "error" ] [ HH.text e ]
  Nothing -> HH.text ""
```

`index.html` is unchanged: the form reuses the existing `.libtop`, `.search` and `.note` styles.
