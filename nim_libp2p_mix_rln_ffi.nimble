mode = ScriptMode.Verbose

packageName = "nim_libp2p_mix_rln_ffi"
version     = "0.1.0"
author      = "Logos"
description = "C FFI facade composing libp2p, nim-libp2p-mix, and Mix-RLN. Produces liblibp2p_mix_rln.{so,dylib,dll} + libp2p_mix_rln.h for consumption by logos-libp2p-mix-rln."
license     = "MIT OR Apache-2.0"

# Direct deps ---------------------------------------------------------------
# nim-ffi at the pinned SHA requires nim >= 2.2.6.
requires "nim >= 2.2.6"
requires "chronos == 4.2.5"
requires "chronicles >= 0.11.0"
requires "results >= 0.4.0"
requires "stew >= 0.4.2"
requires "metrics"
requires "nimcrypto >= 0.6.0"
requires "taskpools >= 0.1.0"

# Pin the FFI/CBOR toolchain.
requires "https://github.com/logos-messaging/nim-ffi#07ee8e1d6500762bab290465457a8d23559de546"

requires "libp2p == 2.3.1"
requires "https://github.com/richard-ramos/nim-libp2p-mix#3c26b907cdd9de58d748939391bdf464b99be3d9"
requires "https://github.com/logos-co/mix-rln-spam-protection-plugin#4cb0b16f8a9f3d7e8b1e759e2179277fb6bbd519"

# Build tasks --------------------------------------------------------------
# Modelled on vacp2p/nim-libp2p `cbind/cbind.nimble`. Two products:
#   `nimble buildffi`      → build/liblibp2p_mix_rln.{so,dylib,dll}
#   `nimble genbindings_c` → c_bindings/libp2p_mix_rln.h
# The nix path (nix/cbind.nix) does the same in a hermetic derivation.
import os, strutils

proc findInstalledPkgDir(prefix: string): string =
  var bases = @[
    "nimbledeps/pkgs2", "nimbledeps/pkgs",
    "../nimbledeps/pkgs2", "../nimbledeps/pkgs",
  ]
  let home = getEnv("HOME")
  if home.len > 0:
    bases.add home & "/.nimble/pkgs2"
  for base in bases:
    if not dirExists(base): continue
    for entry in listDirs(base):
      if entry.extractFilename().startsWith(prefix):
        return entry
  raise newException(
    IOError,
    "could not locate installed package '" & prefix &
      "*'; run `nimble -l setup -y` first",
  )

proc ffiDepPaths(): string =
  " --path:" & findInstalledPkgDir("ffi-") &
  " --path:" & findInstalledPkgDir("cbor_serialization-")

proc libExt(): string =
  when defined(windows): "dll"
  elif defined(macosx): "dylib"
  else: "so"

proc buildFfiLib() =
  let buildDir = "build"
  if not dirExists(buildDir):
    mkDir(buildDir)
  exec "nim c --out:" & buildDir & "/liblibp2p_mix_rln." & libExt() &
    " --threads:on --app:lib --opt:size --noMain --mm:refc -d:metrics" &
    " -d:chronicles_runtime_filtering=on -d:ffiThreadExitTimeoutMs=5000" &
    " -d:libp2p_mix_experimental_exit_is_dest" &
    ffiDepPaths() &
    " --nimMainPrefix:liblibp2p_mix_rln --nimcache:nimcache libp2p_mix_rln.nim"

task buildffi, "Build the FFI shared library":
  buildFfiLib()

proc genBindingsFor(lang, outDir: string) =
  exec "nim c --threads:on --noMain --mm:refc -d:metrics --compileOnly" &
    " -d:chronicles_runtime_filtering=on --nimMainPrefix:liblibp2p_mix_rln" &
    " -d:ffiGenBindings -d:targetLang=" & lang & " -d:ffiOutputDir=" & outDir &
    " -d:ffiSrcPath=libp2p_mix_rln.nim" & ffiDepPaths() &
    " --nimcache:nimcache_" & lang & " libp2p_mix_rln.nim"

task genbindings_c, "Generate C bindings (c_bindings/libp2p_mix_rln.h)":
  genBindingsFor("c", "c_bindings")

task genbindings_cddl, "Generate CDDL schema":
  genBindingsFor("cddl", "cddl_bindings")

task test, "Run integration tests":
  for f in listFiles("tests"):
    let (_, name, ext) = f.splitFile
    if ext != ".nim" or not name.startsWith("test_"):
      continue
    exec "nim c -r --threads:on --mm:refc" &
      " -d:libp2p_mix_experimental_exit_is_dest" &
      ffiDepPaths() &
      " --nimcache:nimcache_" & name & " tests/" & name & ".nim"
    rmFile "tests/" & name.toExe
