# upmpdcli and its two libraries, which nixpkgs does not carry.
#
# UNBUILT AT THE TIME OF WRITING. The sandbox this was written in could not
# reach lesbonscomptes.com, so the versions below are the newest the author
# knew of and every hash is lib.fakeHash. The first `nix build` of each
# reports the real hash in its error; paste it in. If a version 404s, the
# download index at https://www.lesbonscomptes.com/upmpdcli/downloads/ lists
# what exists.
#
# Three derivations in one file because they move together: libupnpp pins a
# libnpupnp, upmpdcli pins a libupnpp.
{
  lib,
  stdenv,
  fetchurl,
  meson,
  ninja,
  pkg-config,
  curl,
  expat,
  libmicrohttpd,
  jsoncpp,
  libmpdclient,
  python3,
}:
let
  libnpupnp = stdenv.mkDerivation (finalAttrs: {
    pname = "libnpupnp";
    version = "6.2.1";

    src = fetchurl {
      url = "https://www.lesbonscomptes.com/upmpdcli/downloads/libnpupnp-${finalAttrs.version}.tar.gz";
      hash = lib.fakeHash;
    };

    nativeBuildInputs = [
      meson
      ninja
      pkg-config
    ];

    buildInputs = [
      curl
      expat
      libmicrohttpd
    ];

    meta = {
      description = "UPnP base library, a rewrite of libupnp without the threads and the exports";
      homepage = "https://www.lesbonscomptes.com/upmpdcli/";
      license = lib.licenses.bsd3;
      platforms = lib.platforms.linux;
    };
  });

  libupnpp = stdenv.mkDerivation (finalAttrs: {
    pname = "libupnpp";
    version = "1.0.2";

    src = fetchurl {
      url = "https://www.lesbonscomptes.com/upmpdcli/downloads/libupnpp-${finalAttrs.version}.tar.gz";
      hash = lib.fakeHash;
    };

    nativeBuildInputs = [
      meson
      ninja
      pkg-config
    ];

    buildInputs = [
      libnpupnp
      curl
      expat
    ];

    meta = {
      description = "C++ wrapper over libnpupnp for UPnP devices and control points";
      homepage = "https://www.lesbonscomptes.com/upmpdcli/";
      license = lib.licenses.lgpl21Plus;
      platforms = lib.platforms.linux;
    };
  });

  upmpdcli = stdenv.mkDerivation (finalAttrs: {
    pname = "upmpdcli";
    version = "1.9.4";

    src = fetchurl {
      url = "https://www.lesbonscomptes.com/upmpdcli/downloads/upmpdcli-${finalAttrs.version}.tar.gz";
      hash = lib.fakeHash;
    };

    nativeBuildInputs = [
      meson
      ninja
      pkg-config
    ];

    buildInputs = [
      libupnpp
      libnpupnp
      libmpdclient
      libmicrohttpd
      jsoncpp
      curl
      expat
      python3
    ];

    passthru = {
      inherit libnpupnp libupnpp;
    };

    meta = {
      description = "UPnP Media Renderer front end for MPD";
      homepage = "https://www.lesbonscomptes.com/upmpdcli/";
      license = lib.licenses.lgpl21Plus;
      platforms = lib.platforms.linux;
      mainProgram = "upmpdcli";
    };
  });
in
upmpdcli
