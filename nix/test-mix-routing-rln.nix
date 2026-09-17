{ pkgs, src, librln }:

## RLN-enabled variant of test-mix-routing.nix. Same build+run pattern; the
## only material differences are that this variant imports mix-rln plugin
## (so librln.a MUST be linked) and needs -lstdc++ (Rust's exception glue).

let
  cbindDeps = import ./cbind-deps.nix { inherit pkgs; };
  pathArgs =
    builtins.concatStringsSep " "
      (map (p: "--path:${p} --path:${p}/src")
           (builtins.attrValues cbindDeps));
in
pkgs.stdenv.mkDerivation {
  pname = "nim-libp2p-mix-rln-ffi-test-mix-routing-rln";
  version = "dev";

  inherit src;

  nativeBuildInputs = [ pkgs.nim-2_2 ];

  buildPhase = ''
    export HOME=$TMPDIR
    export NIMCACHE=$TMPDIR/nimcache
    mkdir -p $NIMCACHE

    nim c --noNimblePath ${pathArgs} \
      --threads:on --mm:refc -d:release \
      -d:chronicles_runtime_filtering=on -d:chronicles_log_level=INFO \
      -d:libp2p_mix_experimental_exit_is_dest \
      --passL:${librln} --passL:-lm --passL:-lstdc++ \
      --nimcache:$NIMCACHE -o:test_mix_routing_rln \
      tests/test_mix_routing_rln.nim
  '';

  installPhase = ''
    set -eo pipefail
    mkdir -p $out
    ./test_mix_routing_rln 2>&1 | tee $out/log
    cp test_mix_routing_rln $out/
    echo "== PASS ==" | tee -a $out/log
  '';
}
