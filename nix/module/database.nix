# What MPD indexes, and when its database has to be thrown away.
#
# ============================================================================
# AUDIO ONLY
# ============================================================================
#
# MPD recognises playlist files it finds in the library (.m3u, .pls, .xspf,
# .asx, .rss, .cue, and cuesheets embedded in FLAC files) and indexes them
# beside the directories and songs, so lsinfo returns them and the page
# offers them. A library that decades of other programs have written to is
# full of these, and they point at paths that were true when some other
# program wrote them. Every playlist plugin MPD carries is off here, so the
# database holds directories and audio files and nothing else.
#
# Two consequences, both deliberate:
#
#   An album ripped as one file plus a .cue is one long track, because the
#   cue that would split it is not read. Per-track files are unaffected.
#
#   MPD's own stored playlists cannot be LOADED. Writing one still works
#   (the save command writes the file itself), but loading goes through the
#   same plugin registry as a playlist found in the library, so it needs
#   the m3u plugin. When nixtune grows playlists of its own, m3u and extm3u
#   come back on and the page filters the library's playlist entries out of
#   its listing instead.
#
# ============================================================================
# THE DATABASE AND THE EXPORT MUST AGREE
# ============================================================================
#
# The database lives in MPD's state directory and survives a rebuild. Every
# URI in it is relative to music_directory, which is always /srv/music, so
# changing services.nixtune.library.export changes what each of those URIs
# means while MPD sees the same directory and keeps the database it has.
# The result is a library full of entries whose files are somewhere else:
# browsing works, playing gives "No such file or directory", and no scan
# repairs it quickly, because MPD prunes a directory's vanished children
# only once it has finished walking that directory, and for the root of a
# library this size that is days away.
#
# This happened on 2026-10-30. The export narrowed from /volume2/music to
# /volume2/music/Music, and the database kept the whole old tree under
# Music/ plus the siblings that were never music at all (RenameQueue,
# Ringtones, _Audio_Books). Everything queued from that tree failed to
# open.
#
# So the export in force is recorded beside the database and checked before
# every MPD start. A mismatch removes the database, and the next scan
# builds it from the directory that is actually mounted.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.nixtune;
  mpd = config.services.mpd;

  # Every playlist plugin in MPD 0.24, by the name its config block uses.
  # The NixOS mpd module validates the rendered mpd.conf by running mpd on
  # it at build time, so a name MPD does not know fails the build here
  # rather than the daemon on the player.
  playlistPlugins = [
    "extm3u"
    "m3u"
    "pls"
    "xspf"
    "asx"
    "rss"
    "flac"
    "cue"
    "embcue"
  ];

  # The string the stamp holds. A host with no library still gets a stamp,
  # so moving from an export to none and back is caught as well.
  export = if cfg.library.export == null then "(none)" else cfg.library.export;

  dropDatabase = lib.optionalString (mpd.settings.db_file != null) ''
    db=${lib.escapeShellArg mpd.settings.db_file}
    if [ -e "$db" ] && { [ ! -r "$stamp" ] || [ "$(cat "$stamp")" != "$want" ]; }; then
      echo "nixtune: the library export is now $want; removing $db so the next scan rebuilds it"
      rm -f "$db"
    fi
  '';
in
{
  config = lib.mkIf cfg.enable {
    services.mpd.settings.playlist_plugin = map (name: {
      inherit name;
      enabled = false;
    }) playlistPlugins;

    systemd.services.nixtune-database-stamp = {
      description = "nixtune: drop MPD's database when the library export changes";
      # Pulled in by MPD and ordered before it, and deliberately without
      # RemainAfterExit, so it runs on every start rather than once per
      # boot. wantedBy rather than requiredBy: if this unit fails, MPD
      # still starts.
      wantedBy = [ "mpd.service" ];
      before = [ "mpd.service" ];
      path = [ pkgs.coreutils ];
      serviceConfig.Type = "oneshot";
      script = ''
        state=${lib.escapeShellArg mpd.dataDir}
        stamp="$state/nixtune-export"
        want=${lib.escapeShellArg export}

        install -d -o ${mpd.user} -g ${mpd.group} -m 0755 "$state"
        ${dropDatabase}
        printf '%s\n' "$want" > "$stamp"
      '';
    };
  };
}
