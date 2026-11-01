{
  description = "nixtune: a network music player, declared";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # FOR THE DEVELOPMENT SHELL ONLY: spago, the tool that edits
    # packages/nixtune-web/spago.lock. nixpkgs carries only spago-legacy
    # (0.21). The page's compiler is packages/nixtune-web/purs.nix, upstream's
    # static release at the URL and hash this overlay's manifest records, and
    # its bundler is nixpkgs' esbuild. The module and the packages never
    # touch this input; a consumer that imports nixosModules.default does not
    # evaluate it.
    purescript-overlay = {
      url = "github:thomashoneyman/purescript-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      purescript-overlay,
    }:
    let
      lib = nixpkgs.lib;

      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # The module on a QEMU-shaped host with no sound card: what
      # `nix flake check` evaluates, and the fastest proof that a change to
      # the module still produces a system.
      rehearsalHost =
        extra:
        lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            self.nixosModules.default
            {
              networking.hostName = "nixtune-rehearsal";
              services.nixtune = {
                enable = true;
                hardware.profile = "none";
                radio.stations = [
                  {
                    name = "GBH 89.7";
                    url = "https://wgbh-live.streamguys1.com/wgbh";
                  }
                ];
              };
              fileSystems."/" = {
                device = "/dev/disk/by-label/nixos";
                fsType = "ext4";
              };
              boot.loader.grub.enable = false;
              system.stateVersion = "26.11";
            }
            extra
          ];
        };

      rehearsal = rehearsalHost { };

      # The same host as one room of two, with the player on snd-aloop in
      # place of a DAC. The keys are the public halves of throwaway keys,
      # and the secret paths point nowhere: this proves the module
      # evaluates and the system builds, not that it plays. Playing is
      # checks.x86_64-linux.multiroom's job.
      rehearsalMultiroom = rehearsalHost {
        boot.kernelModules = [ "snd-aloop" ];
        services.nixtune.multiroom = {
          enable = true;
          room = "kitchen";
          playerCard = "Loopback";
          peers = {
            kitchen = {
              host = "kitchen.lan";
              serverKey = "9YUjVwCmeg8NExXJcztTEaXxmyqJgmVgpAPLWrv9x2w";
              playerKey = "ixON7xY4JKTOlSbgZ8X3SdhOMmadP4LIF8Hn8F9QMnk";
            };
            lab = {
              host = "lab.lan";
              serverKey = "jMXT3iiJvwqfy-_zA6nU2IBw3gipHjUMu_gAPDzjfy4";
              playerKey = "W0_isw8jmaRm9KZCzju4zAYm5qfBTdGFUFns4jrwwxY";
            };
          };
          secrets = {
            serverKeyFile = "/run/secrets/nixtune-room/server-key";
            playerKeyFile = "/run/secrets/nixtune-room/player-key";
            serverPskFiles = {
              kitchen = "/run/secrets/nixtune-room/server-psk/kitchen";
              lab = "/run/secrets/nixtune-room/server-psk/lab";
            };
            playerPskFiles = {
              kitchen = "/run/secrets/nixtune-room/player-psk/kitchen";
              lab = "/run/secrets/nixtune-room/player-psk/lab";
            };
          };
        };
      };
    in
    {
      # The whole player: services.nixtune.*. Import it and set options; it
      # brings its own packages, built with the importing host's pkgs, so no
      # overlay is needed.
      nixosModules.default = ./nix/module;
      nixosModules.nixtune = self.nixosModules.default;

      packages = forAllSystems (pkgs: {
        nixtune-web = pkgs.callPackage ./packages/nixtune-web { };
        nixtune-room = pkgs.callPackage ./packages/nixtune-room { };
        sendspin = pkgs.callPackage ./packages/sendspin { };
        upmpdcli = pkgs.callPackage ./packages/upmpdcli.nix { };
      });

      # The Sendspin Python packages at the releases nixtune tracks, in
      # every Python package set of a host that applies it. The module does
      # not need it: packages/sendspin builds the player from its own set.
      # It is for a machine that wants the same aiosendspin and sendspin
      # outside nixtune, such as a workstation running `sendspin` by hand
      # against a room.
      overlays.sendspin = final: prev: {
        pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
          (import ./packages/sendspin/python-overrides.nix { inherit (final) fetchFromGitHub; })
        ];
      };

      checks = lib.recursiveUpdate (forAllSystems (
        pkgs:
        let
          own = self.packages.${pkgs.stdenv.hostPlatform.system};
        in
        {
          inherit (own) nixtune-web nixtune-room sendspin;
        }
      )) {
        x86_64-linux = {
          rehearsal = rehearsal.config.system.build.toplevel;
          rehearsal-multiroom = rehearsalMultiroom.config.system.build.toplevel;
          # MultiroomRehearsal: two rooms in VMs. Needs KVM.
          multiroom = import ./nix/tests/multiroom.nix {
            inherit self;
            pkgs = nixpkgs.legacyPackages.x86_64-linux;
          };
        };
      };

      # default is what `direnv` (use flake .) and `nix develop` give: the
      # same purs and esbuild the build uses, spago for the lock, nixfmt for
      # the Nix. The overlay is applied to this pkgs as a function rather
      # than through pkgs.extend, which would evaluate nixpkgs a second time.
      # Evaluating spago from it prints the overlay's own deprecation warning
      # (stdenv.isDarwin); it is theirs, and it does not reach any consumer
      # of the module.
      #
      # room is for working on packages/nixtune-room with cabal: GHC and
      # cabal, plus the C libraries its Hackage dependencies link against.
      # websockets depends on the Haskell zlib package, which needs libz
      # and finds it through pkg-config; mkShell puts both where cabal
      # looks, which a bare `nix shell` does not.
      devShells = forAllSystems (
        pkgs:
        let
          ps = purescript-overlay.overlays.default pkgs pkgs;
        in
        {
          default = pkgs.mkShell {
            packages = [
              (pkgs.callPackage ./packages/nixtune-web/purs.nix { })
              pkgs.esbuild
              pkgs.nixfmt
              ps.spago-unstable
            ];
          };

          room = pkgs.mkShell {
            packages = [
              pkgs.ghc
              pkgs.cabal-install
              pkgs.pkg-config
            ];
            # buildInputs, not packages: pkg-config's setup hook adds the
            # .pc files of buildInputs to PKG_CONFIG_PATH, and the compiler
            # wrapper adds their library paths.
            buildInputs = [ pkgs.zlib ];
          };
        }
      );

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}