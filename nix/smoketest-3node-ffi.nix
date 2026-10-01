{ pkgs, src, cbind }:

## Builds tests/smoketest_3node_ffi.c against the cbind output (headers + shared library
## + vendored tinycbor sources) and runs it as part of the derivation. Passing
## build = passing test.

let
  libExt = if pkgs.stdenv.hostPlatform.isDarwin then "dylib" else "so";
  cxxRuntime = if pkgs.stdenv.hostPlatform.isDarwin then "c++" else "stdc++";
in
pkgs.stdenv.mkDerivation {
  pname = "nim-libp2p-mix-ffi-smoketest-3node-ffi";
  version = "dev";

  inherit src;

  nativeBuildInputs = [ pkgs.stdenv.cc ];

  buildPhase = ''
    set -eu
    export HOME=$TMPDIR
    cc -std=c11 -O2 -g \
      -I${cbind}/include -I${cbind}/include/tinycbor \
      tests/smoketest_3node_ffi.c \
      ${cbind}/include/tinycbor/cborencoder.c \
      ${cbind}/include/tinycbor/cborencoder_close_container_checked.c \
      ${cbind}/include/tinycbor/cborparser.c \
      ${cbind}/include/tinycbor/cborparser_dup_string.c \
      ${cbind}/include/tinycbor/cborerrorstrings.c \
      ${cbind}/lib/liblibp2p_mix_rln.${libExt} \
      -lpthread -l${cxxRuntime} \
      -Wl,-rpath,${cbind}/lib \
      -o smoketest_3node_ffi
  '';

  installPhase = ''
    set -euo pipefail
    mkdir -p $out
    MIX_TEST_TRANSPORT=tcp ./smoketest_3node_ffi 2>&1 | tee $out/tcp.log
    MIX_TEST_TRANSPORT=quic ./smoketest_3node_ffi 2>&1 | tee $out/quic.log
    cp smoketest_3node_ffi $out/
    echo "== TCP + QUIC PASS =="
  '';
}
