{
  description = "C FFI facade for libp2p + Mix + Mix-RLN";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
  };

  outputs = { self, nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux" "aarch64-linux"
        "x86_64-darwin" "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      pkgsFor = system: import nixpkgs { inherit system; };

    in {
      packages = forAllSystems (system:
        let
          pkgs = pkgsFor system;
          cbindPkg = import ./nix/cbind.nix {
            inherit pkgs;
            src = ./.;
          };
        in {
          # `cbind`: the FFI artifact consumed by logos-libp2p-mix-rln's flake.
          cbind = cbindPkg;

          # `smoketest-3node-ffi`: builds AND runs tests/smoketest_3node_ffi.c
          # against the cbind output. Passing build = host
          # coordination and Mix routing work with a mock shared backend.
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
            ];

          };
        }
      );
    };
}
