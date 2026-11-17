# nixpkgs' shairport-sync-airplay2 with airplay-2-port-range.patch applied.
#
# Upstream binds AirPlay 2's event, control and audio sockets to port 0, so
# the kernel picks any free port in 32768 to 60999 and a firewall has to open
# that whole range. The patch adds two settings to the general section,
# airplay_2_port_base and airplay_2_port_range. With a range set, those
# sockets are bound in it instead, TCP and UDP alike, walking from one place
# further on at every bind so ports are reused as late as possible, and
# setting SO_REUSEADDR on TCP sockets so a port whose earlier connections are
# still in TIME_WAIT can be bound again. With no range set it behaves exactly
# as upstream does. airplay.nix sets 6200 and 32.
#
# The patch is written against 5.6.2, the release nixpkgs builds (its source
# hash, sha256-JiiZLgeYFoZ+Xq6tn1+KqW6Ewo+j+5JmxJ0Wm3dXqoE=, is the NAR hash
# of tag 5.6.2), and also applies to upstream's development branch as of
# 2026-11-10. A nixpkgs update that moves shairport-sync on and breaks it
# fails this package's build, which CI builds on both architectures.
#
# Not cached: this derivation is compiled wherever the system is built. Its
# dependencies are nixpkgs' and come from the binary cache.
{ shairport-sync-airplay2 }:
shairport-sync-airplay2.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [ ./airplay-2-port-range.patch ];
})
