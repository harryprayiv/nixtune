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

    # The Raspberry Pi layer behind nixosModules.raspberry-pi-*: the vendor
    # kernel, firmware, bootloader and config.txt (nix/raspberry-pi.nix).
    # Its nixpkgs is NOT made to follow ours. The kernel and firmware the
    # board modules install are built from this flake's own pinned nixpkgs,
    # which is what nixos-raspberrypi.cachix.org holds; following ours would
    # change every hash and compile the kernel again. A consumer that
    # imports only nixosModules.default never evaluates this input.
    nixos-raspberrypi.url = "github:nvmd/nixos-raspberrypi/main";

    # FOR CHECKS ONLY: the other Pi layer hardware.nix supports, evaluated
    # by checks.x86_64-linux.pi5-dac2hd-nixos-hardware so that path does not
    # rot. Nothing a consumer imports refers to it.
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
  };

  outputs =
    {
      self,
      nixpkgs,
      purescript-overlay,
      nixos-raspberrypi,
      nixos-hardware,
    }:
    let
      lib = nixpkgs.lib;

      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      raspberryPi = import ./nix/raspberry-pi.nix { inherit nixos-raspberrypi; };

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
                hardware = {
                  board = "other";
                  audio = "none";
                };
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

      # The same host with a USB DAC and AirPlay 2: shairport-sync's
      # AirPlay 2 build, NQPTP and the firewall that goes with them.
      rehearsalAirplay = rehearsalHost {
        services.nixtune = {
          hardware = {
            audio = lib.mkForce "usb";
            card.id = "DAC";
          };
          renderers.airplay.enable = true;
        };
      };

      # A Raspberry Pi on nixos-raspberrypi, as an adopter would declare
      # one, minus the secrets. Built on an aarch64 runner, where the kernel
      # and firmware come from nixos-raspberrypi.cachix.org. Each proves
      # that a board and an output evaluate to a system and build; none of
      # them proves the sound comes out.
      piHost =
        board: extra:
        lib.nixosSystem {
          modules = [
            self.nixosModules.default
            self.nixosModules.${board}
            {
              networking.hostName = "nixtune-${board}";
              nixpkgs.hostPlatform = "aarch64-linux";
              system.stateVersion = "26.11";
              fileSystems."/" = {
                device = "/dev/disk/by-label/NIXOS_SD";
                fsType = "ext4";
              };
              fileSystems."/boot/firmware" = {
                device = "/dev/disk/by-label/FIRMWARE";
                fsType = "vfat";
              };
              services.nixtune.enable = true;
            }
            extra
          ];
        };

      # The reference player on nixos-hardware instead, with the boot
      # settings the README's "With nixos-hardware instead" gives. Only
      # evaluated: nixos-hardware's kernel has no binary cache, and building
      # it on every kernel bump takes hours.
      nixosHardwareHost = lib.nixosSystem {
        modules = [
          self.nixosModules.default
          nixos-hardware.nixosModules.raspberry-pi-5
          (
            { lib, ... }:
            {
              networking.hostName = "nixtune-nixos-hardware";
              nixpkgs.hostPlatform = "aarch64-linux";
              system.stateVersion = "26.11";
              boot.initrd.availableKernelModules = lib.mkForce [
                "mmc_block"
                "usbhid"
                "hid_generic"
                "usb_storage"
                "xhci_pci"
                "pcie_brcmstb"
                "reset-raspberrypi"
              ];
              boot.loader.grub.enable = false;
              boot.loader.generic-extlinux-compatible.enable = true;
              fileSystems."/" = {
                device = "/dev/disk/by-label/NIXOS_SD";
                fsType = "ext4";
              };
              services.nixtune = {
                enable = true;
                hardware = {
                  board = "pi5";
                  audio = "dac2hd";
                };
                renderers.airplay.enable = true;
              };
            }
          )
        ];
      };

      # A check that evaluates a system and builds none of it: a text file
      # holding the system's derivation path. unsafeDiscardOutputDependency
      # makes the file depend on the .drv alone, which evaluation already
      # wrote to the store, not on what the .drv would produce, so building
      # the check compiles nothing. Evaluation failures and failed assertions
      # still fail it.
      evaluated =
        pkgs: name: system:
        pkgs.writeText "${name}.drv-path" (
          builtins.unsafeDiscardOutputDependency system.config.system.build.toplevel.drvPath
        );

      piChecks = {
        # The reference player: a Pi 5 with the DAC2 HD and AirPlay 2.
        pi5-dac2hd =
          (piHost "raspberry-pi-5" {
            services.nixtune = {
              hardware.audio = "dac2hd";
              renderers.airplay.enable = true;
            };
          }).config.system.build.toplevel;

        # A HiFiBerry card from the table, with an overlay parameter, and
        # classic AirPlay.
        pi4-amp100 =
          (piHost "raspberry-pi-4" {
            services.nixtune = {
              hardware = {
                audio = "hifiberry";
                hifiberry = "amp100";
              };
              renderers.airplay = {
                enable = true;
                version = 1;
              };
            };
          }).config.system.build.toplevel;

        # A Pi 400 into a receiver on its second HDMI port.
        pi400-hdmi =
          (piHost "raspberry-pi-4" {
            services.nixtune.hardware = {
              board = "pi400";
              audio = "hdmi";
              hdmiPort = 1;
            };
          }).config.system.build.toplevel;

        # A stock Pi 3 through its jack.
        pi3-headphones =
          (piHost "raspberry-pi-3" {
            services.nixtune.hardware.audio = "headphones";
          }).config.system.build.toplevel;

        # A Zero 2 W with a DAC+ Zero.
        zero2w-dacplus-zero =
          (piHost "raspberry-pi-02" {
            services.nixtune.hardware = {
              audio = "hifiberry";
              hifiberry = "dacplus-zero";
            };
          }).config.system.build.toplevel;
      };
    in
    {
      # The whole player: services.nixtune.*. Import it and set options; it
      # brings its own packages, built with the importing host's pkgs, so no
      # overlay is needed.
      #
      # On a Raspberry Pi, import one of raspberry-pi-02, -3, -4 or -5 beside
      # it for the kernel, firmware and boot path (nix/raspberry-pi.nix), and
      # sd-image to build a card. nixos-hardware's raspberry-pi modules still
      # work in their place; hardware.nix writes to whichever is there.
      nixosModules = {
        default = ./nix/module;
        nixtune = self.nixosModules.default;
      }
      // raspberryPi;

      packages = forAllSystems (pkgs: {
        nixtune-web = pkgs.callPackage ./packages/nixtune-web { };
        nixtune-room = pkgs.callPackage ./packages/nixtune-room { };
        sendspin = pkgs.callPackage ./packages/sendspin { };
        shairport-sync = pkgs.callPackage ./packages/shairport-sync { };
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
          inherit (own)
            nixtune-web
            nixtune-room
            sendspin
            shairport-sync
            ;
        }
      )) {
        x86_64-linux = {
          rehearsal = rehearsal.config.system.build.toplevel;
          rehearsal-multiroom = rehearsalMultiroom.config.system.build.toplevel;
          rehearsal-airplay = rehearsalAirplay.config.system.build.toplevel;
          pi5-dac2hd-nixos-hardware =
            evaluated nixpkgs.legacyPackages.x86_64-linux "pi5-dac2hd-nixos-hardware"
              nixosHardwareHost;
          # MultiroomRehearsal: two rooms in VMs. Needs KVM.
          multiroom = import ./nix/tests/multiroom.nix {
            inherit self;
            pkgs = nixpkgs.legacyPackages.x86_64-linux;
          };
        };
        aarch64-linux = piChecks;
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