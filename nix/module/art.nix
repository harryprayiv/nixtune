# Cover art, because the pictures are inside the files.
#
# ============================================================================
# WHY THIS EXISTS
# ============================================================================
#
# A library ripped by most tools keeps the cover in the tags, not beside the
# audio: an ID3v2 APIC frame in an MP3, a PICTURE metadata block in a FLAC.
# Nothing in the serving path can read those. nginx serves files and the
# picture is not a file; MPD will hand it over through albumart and
# readpicture, but both answer with raw binary, and the page's connection to
# MPD is websocat in text mode, which is UTF-8 lines. Binary on that
# connection is mangled or drops the client.
#
# So the pictures are extracted once, on the player, into a cache that
# mirrors the library's directory layout, and nginx serves that cache. One
# cover per album directory, always called cover.jpg, so the page asks for
# exactly one URL and needs no knowledge of what the library is named or how
# it stores art. An album whose art is already a file beside the audio goes
# through the same path, so there is one place the page looks either way.
#
# This is the shape moOde arrived at as well. The differences are that the
# cache here is a directory tree rather than rows in a database, and that
# nothing regenerates it on a web request: a request either finds a file or
# gets a 404, and the page shows no art until the next scan.
#
# ============================================================================
# WHAT IT COSTS
# ============================================================================
#
# The first scan reads one file per album directory over NFS and runs ffmpeg
# on it. On a library of tens of thousands of tracks that is thousands of
# reads and it can run for a long while, so the unit is niced and its IO is
# idle-class: it finishes when it finishes and the player stays responsive
# while it does. Afterwards each run only touches album directories whose
# mtime is newer than what the cache holds for them, so a weekly addition
# costs a directory walk and nothing else.
#
# Nothing here reaches the network. ffmpeg is the only addition and it runs
# on the player against the player's own mount.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.nixtune;

  enabled = cfg.enable && cfg.ui.enable && cfg.library.export != null && cfg.ui.albumArt;

  mount = "/srv/music";
  cache = "/var/lib/nixtune/art";

  scan = pkgs.writeShellApplication {
    name = "nixtune-art-scan";
    runtimeInputs = [
      pkgs.ffmpeg-headless
      pkgs.coreutils
      pkgs.findutils
    ];
    text = ''
      root=${lib.escapeShellArg mount}
      cache=${lib.escapeShellArg cache}
      size=${toString cfg.ui.albumArtSize}

      made=0
      none=0
      kept=0

      # Every directory under the library, with Synology's metadata trees
      # pruned: @eaDir holds thumbnails of its own and .checksums holds
      # nothing worth reading.
      while IFS= read -r -d "" dir; do
        rel=''${dir#"$root"}
        rel=''${rel#/}
        out=$cache/$rel

        # Already done, and the album has not changed since. A directory
        # touched after the attempt is tried again, so art added later is
        # picked up without clearing the cache by hand.
        if [ -e "$out/cover.jpg" ] && [ ! "$dir" -nt "$out/cover.jpg" ]; then
          kept=$((kept + 1))
          continue
        fi
        if [ -e "$out/.none" ] && [ ! "$dir" -nt "$out/.none" ]; then
          continue
        fi

        # A picture already beside the audio wins: it is the full-size one
        # the ripper saved, and reading it costs nothing.
        img=$(find "$dir" -maxdepth 1 -type f \
          \( -iname 'cover.*' -o -iname 'folder.*' -o -iname 'front.*' -o -iname 'album.*' \) \
          -print -quit)

        track=$(find "$dir" -maxdepth 1 -type f \
          \( -iname '*.flac' -o -iname '*.mp3' -o -iname '*.m4a' -o -iname '*.ogg' \
             -o -iname '*.opus' -o -iname '*.wv' -o -iname '*.ape' -o -iname '*.dsf' \
             -o -iname '*.aiff' -o -iname '*.aif' -o -iname '*.wav' \) \
          -print -quit)

        # A directory with neither is not an album, so it gets no marker and
        # costs nothing to walk again.
        if [ -z "$img" ] && [ -z "$track" ]; then
          continue
        fi

        src=$img
        if [ -z "$src" ]; then
          src=$track
        fi

        mkdir -p "$out"

        # One frame of the first video stream, which is what an attached
        # picture is in every container ffmpeg reads, scaled down only if it
        # is larger than the cap. -2 keeps the aspect and an even height,
        # which the JPEG encoder wants.
        if ffmpeg -nostdin -v error -y -i "$src" \
             -map 0:v:0 -frames:v 1 \
             -vf "scale='min($size,iw)':-2" -q:v 3 \
             "$out/cover.jpg" 2>/dev/null; then
          rm -f "$out/.none"
          made=$((made + 1))
        else
          # No picture in it, or one ffmpeg could not read. The marker stops
          # the next run paying for the same file again.
          rm -f "$out/cover.jpg"
          : > "$out/.none"
          none=$((none + 1))
        fi
      done < <(find "$root" \( -name '@eaDir' -o -name '.checksums' \) -prune -o -type d -print0)

      echo "nixtune-art: $made covers written, $kept already current, $none albums with no picture"
    '';
  };
in
{
  options.services.nixtune.art.path = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    readOnly = true;
    internal = true;
    default = if enabled then "/art" else null;
    description = ''
      Where the page asks for cover images, or null when there is no library
      or album art is off. Read by ui.nix for capabilities.json.
    '';
  };

  config = lib.mkIf enabled {
    users.users.nixtune-art = {
      isSystemUser = true;
      group = "nixtune-art";
      description = "nixtune cover art cache";
    };
    users.groups.nixtune-art = { };

    systemd.services.nixtune-art-scan = {
      description = "nixtune: extract cover art into the cache";
      after = [ "mpd.service" ];
      # The library is an automount, and a service runs in its own mount
      # namespace: a mount that happens after the unit starts never appears
      # inside it. This makes systemd trigger the mount and wait for it
      # before the namespace is taken.
      unitConfig.RequiresMountsFor = [ mount ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe scan;
        User = "nixtune-art";
        Group = "nixtune-art";
        # Owned by this user, readable by nginx, which is the whole point of
        # a fixed user here: a DynamicUser's state directory lives under
        # /var/lib/private, which nginx cannot traverse.
        StateDirectory = "nixtune/art";
        StateDirectoryMode = "0755";
        # The first run over a large library is thousands of NFS reads and
        # as many ffmpeg invocations. It yields to everything else.
        Nice = 19;
        IOSchedulingClass = "idle";
        CPUSchedulingPolicy = "idle";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateNetwork = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        ReadOnlyPaths = [ mount ];
      };
    };

    systemd.timers.nixtune-art-scan = {
      description = "nixtune: look for new cover art";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        # Long enough after boot that the NFS automount and MPD's own scan
        # are out of the way.
        OnBootSec = "10min";
        OnUnitActiveSec = "6h";
        Persistent = true;
      };
    };

    # The cache is expensive to rebuild, so it is state rather than cache as
    # far as an impermanence setup is concerned.
    services.nixtune.persistPaths = [ "/var/lib/nixtune" ];

    services.nginx.virtualHosts.nixtune.locations."~* ^/art/(.+\\.jpe?g)$" = {
      extraConfig = ''
        alias ${cache}/$1;
        expires 1h;
        add_header Cache-Control "public, max-age=3600";
        access_log off;
      '';
    };
  };
}
