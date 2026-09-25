# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Logos

## `{.ffi.}` config types that mirror the schema declared in
## logos-libp2p-mix-rln/metadata.json. Included by `libp2p_mix_rln.nim`;
## consumers construct a `MixRlnConfig` from CBOR-marshalled fields.
##
## LIP LOGOS-MIXNET parameters that the spec fixes (path length 3, Sphinx
## packet plus proof 4909 bytes, `CONSTANT_RATE` cover strategy) are NOT exposed here —
## they are compile-time constants inside the mix protocol.
##
## Parameters marked `TBD` in LIP LOGOS-MIXNET carry placeholder defaults —
## pin them to real values before mainnet use.

type MixConfig* {.ffi.} = object
  ## X25519 keypair advertised for Sphinx path selection is embedded here.
  ## `mixPrivKeyHex = ""` → generate on create.
  mixPrivKeyHex: string
  coverRateFraction: float64 ## LIP LOGOS-MIXNET default: 0.7.

type RlnConfig* {.ffi.} = object
  registryId: string
  rlnIdentifierHex: string
  registrationOptionsJson: string
  epochDurationSeconds: int64 ## Must match the backend; Logos profile: 10.
  maxEpochGap: int ## Logos profile: 3.
  userMessageLimit: int ## Logos profile: 100.
  proofMetadataContentTopic: string ## Placeholder "/mix/rln/metadata/v1".

type MixRlnConfig* {.ffi.} = object ## Top-level config passed to `libp2pMixRlnCreate`.
  addrs: seq[string] ## libp2p listen multiaddrs.
  privKeyHex: string ## Hex-encoded libp2p host private key ("" → fresh).
  transport: string ## "tcp" or "quic"; QUIC addrs end in `/udp/.../quic-v1`.
  maxConnections: int
  maxConnsPerPeer: int
  mix: MixConfig
  rln: RlnConfig
