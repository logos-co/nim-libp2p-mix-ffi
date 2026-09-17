{
  description = "C FFI facade for libp2p + Mix + Mix-RLN";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

    # Pins the richard-ramos fork branch that carries zerokit PR #436
    # (draft against `release-v2.0.1`; adds the `rln-stateless` output and
    # `--no-default-features` handling that this facade needs). Point back
    # at `github:vacp2p/zerokit` once the changes land upstream. Override
    # with `--override-input zerokit ...` if you want to try a different
    # revision locally.
    zerokit.url = "github:richard-ramos/zerokit/nix-rln-stateless";

    # Nixpkgs pin that carries the fetch-cargo-vendor-util fix (zerokit PR
    # #435) needed to vendor without hitting crates.io 403.
    zerokit-nixpkgs.url = "github:NixOS/nixpkgs?rev=cd648d6ea62bc0ffba91e61fcfe5e33c1e2004b1";
    zerokit.inputs.nixpkgs.follows = "zerokit-nixpkgs";
  };

  outputs = { self, nixpkgs, zerokit, ... }:
    let
      systems = [
        "x86_64-linux" "aarch64-linux"
        "x86_64-darwin" "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      pkgsFor = system: import nixpkgs { inherit system; };

      # mix-rln-spam-protection-plugin's Nim binding declares
      # `proc ffi_rln_new(): CResultRLNPtrVecU8` — the zero-arg form. Zerokit
      # exposes that variant only under `--features=stateless`; the default
      # build produces `ffi_rln_new(tree_depth, config_path)`. Same symbol,
      # different arity → calling the default build with 0 args segfaults
      # inside Rust. Consume the `rln-stateless` output rather than `rln`.
      # (Our zerokit input must expose one — see the local zerokit-v2 fork's
      # flake.nix, which adds `rln-stateless = buildRln.override { features =
      # "stateless"; }` next to `rln`.)
      librlnOf = system:
        "${zerokit.packages.${system}.rln-stateless}/lib/librln.a";
    in {
      packages = forAllSystems (system:
        let
          pkgs = pkgsFor system;
          cbindPkg = import ./nix/cbind.nix {
            inherit pkgs;
            src = ./.;
            librln = librlnOf system;
          };
        in {
          # `cbind`: the FFI artifact consumed by logos-libp2p-mix-rln's flake.
          cbind = cbindPkg;

          # `smoketest-3node-ffi`: builds AND runs tests/smoketest_3node_ffi.c
          # against the cbind output. Passing build = host
          # coordination and Mix-RLN routing through the C API work.
          smoketest-3node-ffi = import ./nix/smoketest-3node-ffi.nix {
            inherit pkgs;
            src = ./.;
            cbind = cbindPkg;
          };

          # `test-mix-routing`: builds AND runs tests/test_mix_routing.nim as
          # part of the derivation. A passing build = a passing test.
          test-mix-routing = import ./nix/test-mix-routing.nix {
            inherit pkgs;
            src = ./.;
            librln = librlnOf system;
          };

          # `test-mix-routing-rln`: same, but every mix node has an RLN
          # SpamProtection plugin wired in and per-hop proofs are generated
          # and verified along the whole Sphinx path. Uses an in-process
          # publish bus to cross-sync memberships between plugins.
          test-mix-routing-rln = import ./nix/test-mix-routing-rln.nix {
            inherit pkgs;
            src = ./.;
            librln = librlnOf system;
          };
        }
      );

      devShells = forAllSystems (system:
        let pkgs = pkgsFor system;
        in {
          default = pkgs.mkShell {
            nativeBuildInputs = [
              pkgs.nim-2_2
              pkgs.nimble
              pkgs.git
              zerokit.packages.${system}.rln-stateless
            ];
            shellHook = ''
              export LIBRLN_PATH=${librlnOf system}
            '';
          };
        }
      );
    };
}
