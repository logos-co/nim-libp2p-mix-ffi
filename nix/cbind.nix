{ pkgs, src, librln ? null }:

## Hermetic build of the FFI shared library + generated C header.
##
## Uses the exact dependency graph from the pinned Delivery revision plus the
## Delivery source itself and a mandatory `librln.a` input.
##
## `librln`: path to the librln.a static archive from vacp2p/zerokit. Passed in
## from the flake so packaging zerokit stays out of scope here.

let
  rawCbindDeps = import ./cbind-deps.nix { inherit pkgs; };

  # nim-nat-traversal ships C sources under `vendor/{miniupnp,libnatpmp-upstream}`
  # and expects `nimble install` to run its `before install` hook, which compiles
  # them into `libminiupnpc.a` / `libnatpmp.a` at hardcoded relative paths that
  # nim-libp2p's `{.link.}` pragmas depend on. `fetchgit` skips that hook, so we
  # wrap the source tree with a derivation that runs the makefiles.
  natTraversalBuilt = pkgs.stdenv.mkDerivation {
    name = "nim-nat-traversal-with-libs";
    src = rawCbindDeps.nat_traversal;
    nativeBuildInputs = [ pkgs.gnumake pkgs.gcc ];
    dontConfigure = true;
    buildPhase = ''
      (cd vendor/miniupnp/miniupnpc && \
        make CFLAGS="-Os -fPIC" build/libminiupnpc.a)
      (cd vendor/libnatpmp-upstream && \
        make CFLAGS="-Wall -Os -fPIC -DENABLE_STRNATPMPERR -DNATPMP_MAX_RETRIES=4" \
          libnatpmp.a)
    '';
    installPhase = ''
      mkdir -p $out
      cp -r . $out
    '';
  };

  cbindDeps = rawCbindDeps // { nat_traversal = natTraversalBuilt; };

  # Some deps put nim sources at repo root (nim-libp2p), others under `src/`
  # (mix-rln-spam-protection-plugin sets `srcDir = "src"` in its .nimble). We
  # can't distinguish at eval time cheaply, so include both flavors — Nim's
  # importer ignores paths that don't hold matches.
  cbindPathArgs =
    builtins.concatStringsSep " "
      (map (p: "--path:${p} --path:${p}/src")
           (builtins.attrValues cbindDeps));

  libExt =
    if pkgs.stdenv.hostPlatform.isWindows then "dll"
    else if pkgs.stdenv.hostPlatform.isDarwin then "dylib"
    else "so";

  tinycborVendor = "${cbindDeps.ffi}/ffi/codegen/templates/cpp/vendor/tinycbor";

  librlnLinkArgs =
    if librln == null then
      throw "nim-libp2p-mix-rln-ffi/nix/cbind.nix: librln input is required (path to librln.a)"
    else
      "--passL:${librln} --passL:-lm";
in
pkgs.stdenv.mkDerivation {
  pname = "nim-libp2p-mix-rln-ffi-cbind";
  version = "dev";

  inherit src;

  nativeBuildInputs = [
    pkgs.nim-2_2
    pkgs.git
    pkgs.nimble
  ];

  buildPhase = ''
    export HOME=$TMPDIR
    export XDG_CACHE_HOME=$TMPDIR/.cache
    export NIMBLE_DIR=$TMPDIR/.nimble
    export NIMCACHE=$TMPDIR/nimcache

    mkdir -p build $NIMCACHE

    commonArgs="--noNimblePath ${cbindPathArgs} \
      --threads:on --opt:size --noMain --mm:refc -d:metrics \
      -d:chronicles_runtime_filtering=on \
      -d:ffiThreadExitTimeoutMs=5000 \
      -d:libp2p_mix_experimental_exit_is_dest \
      --nimMainPrefix:liblibp2p_mix_rln --nimcache:$NIMCACHE \
      ${librlnLinkArgs}"

    echo "== Building FFI library (dynamic/shared) =="
    nim c $commonArgs --app:lib --out:build/liblibp2p_mix_rln.${libExt} libp2p_mix_rln.nim

    echo "== Building FFI library (static) =="
    nim c $commonArgs --app:staticlib --out:build/liblibp2p_mix_rln.a libp2p_mix_rln.nim

    echo "== Generating C bindings =="
    nim c $commonArgs --app:lib -d:ffiGenBindings -d:targetLang=c \
      -d:ffiOutputDir=c_bindings -d:ffiSrcPath=libp2p_mix_rln.nim \
      -o:/dev/null libp2p_mix_rln.nim
  '';

  installPhase = ''
    mkdir -p $out/lib $out/include
    cp build/liblibp2p_mix_rln.${libExt} $out/lib
    cp build/liblibp2p_mix_rln.a         $out/lib
    cp c_bindings/*.h                    $out/include/
    # libp2p_mix_rln.h includes <tinycbor/cbor.h>; ship the vendored runtime so
    # the installed header set compiles without an external TinyCBOR.
    mkdir -p $out/include/tinycbor
    cp ${tinycborVendor}/* $out/include/tinycbor/
  '';
}
