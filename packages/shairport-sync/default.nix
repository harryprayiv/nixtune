# nixpkgs' shairport-sync-airplay2 with airplay-2-port-range.patch applied.
#
# Upstream binds AirPlay 2's event, control and audio sockets to port 0, so
# the kernel picks any free port in 32768 to 60999 and a firewall has to open
# that whole range. The patch adds two settings to the general section,
# airplay_2_port_base and airplay_2_port_range. With a range set, those
# sockets are bound in it instead, TCP and UDP alike, walking from one place
# further on at every bind so ports are reused as late as possible, and
# setting SO_REUSEADDR on TCP sockets so a port whose earlier connections are
# still in TIME_WAIT can be bound again. With no range set, port choice is
# exactly upstream's. airplay.nix sets 6200 and 32.
#
# The patch also closes two listening sockets upstream never closes: each
# RTSP connection's event port and, when a remote-control stream is set up,
# its data port. Upstream leaves both listening until the process exits,
# which nobody notices among 28,000 ephemeral ports. In a range of 32 the
# leak fills the range after a dozen or so connections, and the next SETUP
# then fails to bind and shairport-sync exits (systemd restarts it). Seen on
# the kitchen player on 2026-11-18: 13 listeners in the range after a few
# switches between two senders with three connections alive. They are now
# closed when the connection is torn down, after its event thread has been
# joined.
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