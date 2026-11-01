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
      rehearsal = lib.nixosSystem {
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
        ];
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
        upmpdcli = pkgs.callPackage ./packages/upmpdcli.nix { };
      });

      checks = lib.recursiveUpdate (forAllSystems (pkgs: {
        nixtune-web = self.packages.${pkgs.stdenv.hostPlatform.system}.nixtune-web;
      })) { x86_64-linux.rehearsal = rehearsal.config.system.build.toplevel; };

      # What `direnv` (use flake .) and `nix develop` give: the same purs and
      # esbuild the build uses, spago for the lock, nixfmt for the Nix. The
      # overlay is applied to this pkgs as a function rather than through
      # pkgs.extend, which would evaluate nixpkgs a second time. Evaluating
      # spago from it prints the overlay's own deprecation warning
      # (stdenv.isDarwin); it is theirs, and it does not reach any consumer
      # of the module.
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
        }
      );

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}