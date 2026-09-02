{ pkgs, src, cbind }:

## Builds tests/smoketest_3node_ffi.c against the cbind output (headers + .so
## + vendored tinycbor sources) and runs it as part of the derivation. Passing
## build = passing test.

pkgs.stdenv.mkDerivation {
  pname = "nim-libp2p-mix-rln-ffi-smoketest-3node-ffi";
  version = "dev";

  inherit src;

  nativeBuildInputs = [ pkgs.gcc ];

  buildPhase = ''
    set -eu
    export HOME=$TMPDIR
    gcc -std=c11 -O2 -g \
      -I${cbind}/include -I${cbind}/include/tinycbor \
      tests/smoketest_3node_ffi.c \
      ${cbind}/include/tinycbor/cborencoder.c \
      ${cbind}/include/tinycbor/cborencoder_close_container_checked.c \
      ${cbind}/include/tinycbor/cborparser.c \
      ${cbind}/include/tinycbor/cborparser_dup_string.c \
      ${cbind}/include/tinycbor/cborerrorstrings.c \
      ${cbind}/lib/liblibp2p_mix_rln.so \
      -lpthread -lstdc++ \
      -Wl,-rpath,${cbind}/lib \
      -o smoketest_3node_ffi
  '';

  installPhase = ''
    mkdir -p $out
    MIX_TEST_TRANSPORT=tcp ./smoketest_3node_ffi 2>&1 | tee $out/tcp.log
    MIX_TEST_TRANSPORT=quic ./smoketest_3node_ffi 2>&1 | tee $out/quic.log
    cp smoketest_3node_ffi $out/
    echo "== TCP + QUIC PASS =="
  '';
}
