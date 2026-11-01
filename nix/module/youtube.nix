# Queueing tracks from a YouTube link: yt-dlp fetches the audio into a
# folder inside the library on the NAS, MPD indexes that folder, and each
# track is added to the end of the queue. A video link queues that video; a
# playlist link queues the playlist's videos in order.
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
# and reads back, for each video in turn,
#   fetching <id> <i>/<n>   video i of n is being fetched
#   added <uri>             it is on the NAS and at the end of the queue
#   skip <id> <reason>      it was not queued, and why
# then
#   done <added>/<n>        the request is finished
# A playlist link first says
#   playlist <n>            how many of its videos will be fetched
# and a request that queues nothing at all ends with
#   err <reason>            a link that is neither, or a playlist that
#                           could not be read
# A video link is a request of one: fetching, then added or skip, then
# done 1/1 or done 0/1.
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
# youtube.com watch, shorts or live link, a youtu.be link, or a youtube.com
# playlist link, pulls the video or playlist id out of it, and builds the
# URL yt-dlp gets from that id alone. A watch link that also carries a
# list= is the one video, not the list. Anything else is refused, so the
# socket cannot be used to make the player fetch an arbitrary address on
# the LAN or the internet, and no part of what was sent reaches a shell or
# a command line. A playlist is read with --flat-playlist, which lists ids
# without fetching anything, and only ids of the video id's shape go on to
# be fetched, each through the same path as a single link.
#
# yt-dlp runs with --ignore-config, one video and never a playlist, a
# length limit (youtube.maxMinutes, which also refuses live streams), a
# size limit (youtube.maxSize) and a wall-clock limit of fifteen minutes.
# A playlist is cut at youtube.maxPlaylistItems. One download runs at a
# time across every connection; a second request waits for the one under
# way, video by video.
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
# Opus from a WebM stream, AAC from an M4A one. The thumbnail is embedded
# as the cover, so art.nix finds a picture in it like any other file. The
# name is "<uploader> - <title> [<id>].<ext>", and a link whose id is
# already in the folder is queued from the file that is there without
# downloading again.
#
# A download is part of the library from the moment it lands: it stays in
# the folder, MPD indexes it, and the page's search finds it like any
# other track. Its tags are what yt-dlp knows (title, artist, date) with
# two set here:
#   album artist   youtube.artist, "YouTube" unless set otherwise, so every
#                  download sits under one row of the artist column, which
#                  the page pins to the top of that column
#   album          the album YouTube names for the track when it has one
#                  (YouTube Music does), else the uploader, so the album
#                  column under that row groups the downloads by channel
# Retagging a file with a real album artist moves it out of that row and
# into the rest of the library, wherever the file itself lives. A file
# renamed without its [<id>] is no longer recognised as that video, and the
# same link fetches it again.
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
      maxitems=${toString yt.maxPlaylistItems}

      player() {
        mpc --host 127.0.0.1 --port ${toString cfg.mpd.port} "$@"
      }

      # One line out, never more: the page reads replies line by line.
      reply() {
        printf '%s\n' "$*" | tr -d '\r' | head -n 1 | cut -c 1-400
      }

      # A watch, shorts or live link on youtube.com (www, m and music
      # included), or a youtu.be link. Group 5 is the video id. A watch link
      # that also names a list is this video alone.
      video_re='^https://(www\.|m\.|music\.)?(youtube\.com/(watch\?([^#]*&)?v=|shorts/|live/)|youtu\.be/)([A-Za-z0-9_-]{11})([?&#/]|$)'

      # A playlist link on youtube.com (www, m and music included). Group 3
      # is the playlist id.
      list_re='^https://(www\.|m\.|music\.)?youtube\.com/playlist\?([^#]*&)?list=([A-Za-z0-9_-]{2,64})([&#]|$)'

      # The first ERROR line yt-dlp wrote to the log $1, else its last line.
      why() {
        grep -m 1 'ERROR' "$1" || tail -n 1 "$1"
      }

      # The file in the download folder for the video $1, fetched first when
      # it is not there yet. Prints the file's name, or the reason and
      # returns 1. Writes nothing else to stdout, because the caller keeps
      # what it prints.
      fetch() {
        local id=$1 name out src
        name=$(find "$dir" -maxdepth 1 -type f -name "*\[$id\].*" ! -name '*.part' -printf '%f\n' -quit)
        if [ -n "$name" ]; then
          printf '%s\n' "$name"
          return 0
        fi
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
          --parse-metadata "%(nixtune_unset|${yt.artist})s:%(meta_album_artist)s" \
          --parse-metadata "%(album,uploader)s:%(meta_album)s" \
          --embed-metadata \
          --embed-thumbnail \
          --convert-thumbnails jpg \
          --windows-filenames \
          --trim-filenames 180 \
          --paths "$work/$id" \
          --output "%(uploader)s - %(title)s [%(id)s].%(ext)s" \
          --print after_move:filepath \
          "https://www.youtube.com/watch?v=$id" 2>"$work/$id.log"); then
          why "$work/$id.log"
          rm -rf "''${work:?}/$id" "$work/$id.log"
          return 1
        fi
        src=$(printf '%s\n' "$out" | tail -n 1)
        if [ -z "$src" ] || [ ! -f "$src" ]; then
          printf '%s\n' "longer than ${toString yt.maxMinutes} minutes, larger than ${yt.maxSize}, or a live stream"
          rm -rf "''${work:?}/$id" "$work/$id.log"
          return 1
        fi
        name=$(basename "$src")
        if ! cp "$src" "$dir/$name.part" || ! mv "$dir/$name.part" "$dir/$name"; then
          rm -f "$dir/$name.part"
          rm -rf "''${work:?}/$id" "$work/$id.log"
          printf '%s\n' "could not write to the NAS folder"
          return 1
        fi
        rm -rf "''${work:?}/$id" "$work/$id.log"
        printf '%s\n' "$name"
      }

      # Add $1, a file in the download folder, to the end of the queue.
      #
      # The library mount and the download mount are separate NFS mounts,
      # each with its own attribute cache, so the library side can take a
      # little while to see the new file. Rescan, try to add, and try again
      # for a minute and a half before giving up.
      queue() {
        local uri="$rel/$1"
        for _ in $(seq 1 18); do
          player --wait rescan "$rel" >/dev/null 2>&1 || true
          if player add "$uri" >/dev/null 2>&1; then
            return 0
          fi
          sleep 5
        done
        return 1
      }

      # One video, as step $2 ("3/12") of a request: fetched, queued, and
      # reported as added or skipped.
      item() {
        local id=$1 step=$2 name
        reply "fetching $id $step"
        if ! name=$(fetch "$id"); then
          reply "skip $id $name"
          return 1
        fi
        if ! queue "$name"; then
          reply "skip $id downloaded, but MPD has not indexed it yet: $rel/$name"
          return 1
        fi
        reply "added $rel/$name"
      }

      # A playlist: its first maxitems entries, fetched and queued one at a
      # time in playlist order, so the queue fills while the rest download.
      # An entry that cannot be fetched (private, removed, too long) is
      # skipped and the rest carry on.
      playlist() {
        local pl=$1 ids id n i=0 added=0
        local -a entries
        if ! ids=$(timeout 120 yt-dlp \
          --ignore-config \
          --flat-playlist \
          --quiet \
          --no-warnings \
          --playlist-end "$maxitems" \
          --print id \
          "https://www.youtube.com/playlist?list=$pl" 2>"$work/$pl.log"); then
          reply "err $(why "$work/$pl.log")"
          rm -f "$work/$pl.log"
          return
        fi
        rm -f "$work/$pl.log"
        mapfile -t entries < <(printf '%s\n' "$ids" | grep -E '^[A-Za-z0-9_-]{11}$' || true)
        n=''${#entries[@]}
        if [ "$n" -eq 0 ]; then
          reply "err the playlist is empty, private, or not found"
          return
        fi
        reply "playlist $n"
        for id in "''${entries[@]}"; do
          i=$((i + 1))
          if item "$id" "$i/$n"; then
            added=$((added + 1))
          fi
        done
        reply "done $added/$n"
      }

      mkdir -p "$work"

      while read -r verb url rest; do
        if [ "$verb" != "get" ] || [ -z "$url" ] || [ -n "$rest" ]; then
          reply "err expected: get URL"
        elif [[ $url =~ $video_re ]]; then
          if item "''${BASH_REMATCH[5]}" 1/1; then
            reply "done 1/1"
          else
            reply "done 0/1"
          fi
        elif [[ $url =~ $list_re ]]; then
          playlist "''${BASH_REMATCH[3]}"
        else
          reply "err not a YouTube video or playlist link"
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

  options.services.nixtune.youtube.pinnedArtist = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    readOnly = true;
    internal = true;
    default = if enabled then yt.artist else null;
    description = ''
      The album artist the page pins to the top of the artist column, or
      null when the feature is off. Read by ui.nix for capabilities.json.
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