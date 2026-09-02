# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Logos

## `{.ffi.}` config types that mirror the schema declared in
## logos-libp2p-mix-rln/metadata.json. Included by `libp2p_mix_rln.nim`;
## consumers construct a `MixRlnConfig` from CBOR-marshalled fields.
##
## LIP LOGOS-MIXNET parameters that the spec fixes (path length 3, Sphinx
## packet 4908 bytes, `CONSTANT_RATE` cover strategy) are NOT exposed here —
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
  keystorePath: string
  keystorePassword: string
  treePath: string
  rlnResourcesPath: string
  rlnIdentifierHex: string ## Hex-encoded RLN identifier.
  epochDurationSeconds: int64 ## TBD; placeholder default 1.
  period: int64 ## TBD; placeholder default 1.
  messagingRate: int64 ## TBD; placeholder default 10.
  maxEpochGap: int ## TBD; placeholder default 20.
  userMessageLimit: int ## TBD; placeholder default 100.
  acceptableRootWindowSize: int ## LIP LOGOS-MIXNET: 5.
  stakedFund: string ## TBD.
  membershipContentTopic: string ## Placeholder "/mix/rln/membership/v1".
  proofMetadataContentTopic: string ## Placeholder "/mix/rln/metadata/v1".
  coordCluster: int64 ## TBD; placeholder 0.

type DiscoveryConfig* {.ffi.} = object
  mountServiceDiscovery: bool
  serviceId: string ## Placeholder "logos.mixnet".

type MixRlnConfig* {.ffi.} = object ## Top-level config passed to `libp2pMixRlnCreate`.
  addrs: seq[string] ## libp2p listen multiaddrs.
  bootstrapPeerIds: seq[string]
  bootstrapMultiaddrs: seq[seq[string]] ## Parallel to `bootstrapPeerIds`.
  privKeyHex: string ## Hex-encoded libp2p host private key ("" → fresh).
  transport: string ## "tcp" or "quic"; QUIC addrs end in `/udp/.../quic-v1`.
  maxConnections: int
  maxInConnections: int
  maxOutConnections: int
  maxConnsPerPeer: int
  mix: MixConfig
  rln: RlnConfig
  discovery: DiscoveryConfig
