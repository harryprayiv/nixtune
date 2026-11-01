# MultiroomRehearsal, first cut: two rooms in VMs, kitchen and lab, each
# with the module as a real room has it, MPD on a null output and the
# player on snd-aloop in place of a DAC. The lab plays a tone; the kitchen
# follows the lab, then goes back to its own queue.
#
# What it proves: the module brings up both services on both rooms; the
# coordinators talk through nginx at /room; the lab's server holds the
# kitchen's player and its own, with credentials provisioned from the
# secret files; PCM reaches both players; and leaving puts both rooms back
# on the direct path. What it cannot prove: sync between the two outputs,
# which needs the real rooms and a microphone (calibration).
#
# Run: nix build .#checks.x86_64-linux.multiroom (needs KVM).
{
  self,
  pkgs,
}:
let
  keys = import ./multiroom-keys.nix;
  rooms = [
    "kitchen"
    "lab"
  ];

  # Ten minutes of a quiet 440 Hz tone, 44.1 kHz, 16 bits, stereo.
  tone = pkgs.runCommand "tone.flac" { nativeBuildInputs = [ pkgs.sox ]; } ''
    sox -n -r 44100 -b 16 -c 2 -t flac $out synth 600 sine 440 gain -20
  '';

  secret = owner: value: {
    text = value;
    user = owner;
    mode = "0400";
  };

  room =
    name:
    { ... }:
    {
      imports = [ self.nixosModules.default ];
      boot.kernelModules = [ "snd-aloop" ];
      virtualisation.memorySize = 1536;

      environment.etc =
        {
          "nixtune-test/server-key" = secret "nixtune-room" keys.${name}.serverSecret;
          "nixtune-test/player-key" = secret "nixtune-player" keys.${name}.playerSecret;
        }
        // builtins.listToAttrs (
          map (r: {
            name = "nixtune-test/server-psk-${r}";
            value = secret "nixtune-room" keys.${name}.serverPsks.${r};
          }) rooms
          ++ map (r: {
            name = "nixtune-test/player-psk-${r}";
            value = secret "nixtune-player" keys.${name}.playerPsks.${r};
          }) rooms
        );

      services.nixtune = {
        enable = true;
        hardware.profile = "none";
        multiroom = {
          enable = true;
          room = name;
          playerCard = "Loopback";
          peers = lib.genAttrs rooms (r: {
            host = r;
            inherit (keys.${r}) serverKey playerKey;
          });
          secrets = {
            serverKeyFile = "/etc/nixtune-test/server-key";
            playerKeyFile = "/etc/nixtune-test/player-key";
            serverPskFiles = lib.genAttrs rooms (r: "/etc/nixtune-test/server-psk-${r}");
            playerPskFiles = lib.genAttrs rooms (r: "/etc/nixtune-test/player-psk-${r}");
          };
        };
      };
    };

  inherit (pkgs) lib;
in
pkgs.testers.runNixOSTest {
  name = "nixtune-multiroom";

  nodes = lib.genAttrs rooms room;

  testScript = ''
    def status(machine):
        return machine.succeed("nixtune-room ctl status")

    def played_pcm(machine):
        machine.wait_until_succeeds(
            "journalctl -u nixtune-player.service | grep -q 'Audio format: pcm 44100Hz/24-bit/2ch'",
            timeout=60,
        )

    start_all()
    for machine in (kitchen, lab):
        machine.wait_for_unit("nixtune-room.service")
        machine.wait_for_unit("nixtune-player.service")
        machine.wait_for_open_port(8928)
        machine.wait_for_open_port(80)

    with subtest("both rooms start alone, on the direct path"):
        for machine in (kitchen, lab):
            machine.wait_until_succeeds("nixtune-room ctl status | grep -q 'path=direct'")

    with subtest("the lab plays"):
        lab.succeed("install -m 0644 ${tone} /var/lib/mpd/music/tone.flac")
        lab.succeed("mpc update --wait && mpc add tone.flac && mpc play")

    with subtest("the kitchen follows the lab"):
        kitchen.succeed("nixtune-room ctl follow lab")
        kitchen.wait_until_succeeds("nixtune-room ctl status | grep -q 'path=peer-server'")
        lab.wait_until_succeeds("nixtune-room ctl status | grep -q 'audience=kitchen'")
        lab.wait_until_succeeds("nixtune-room ctl status | grep -q 'path=own-server'")
        print(status(kitchen))
        print(status(lab))

    with subtest("PCM reaches both players"):
        played_pcm(kitchen)
        played_pcm(lab)
        lab.succeed("mpc status | grep -q '^\\[playing\\]'")

    with subtest("the kitchen goes back to its own queue, and both rooms to the direct path"):
        kitchen.succeed("nixtune-room ctl own")
        kitchen.wait_until_succeeds("nixtune-room ctl status | grep -q 'path=direct'")
        # The lab keeps its server path for the audience grace period.
        lab.wait_until_succeeds("nixtune-room ctl status | grep -q 'path=direct'", timeout=30)
        lab.succeed("mpc status | grep -q '^\\[playing\\]'")
  '';
}