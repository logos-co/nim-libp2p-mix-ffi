# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Logos

## C FFI facade composing Logos Delivery + nim-libp2p-mix + Mix-RLN.
##
## Modelled on vacp2p/nim-libp2p `cbind/libp2p.nim`: `{.ffi.}` types become
## CBOR-encoded request/response objects, `{.ffi.}` procs become C-exported
## async entry points, `genBindings()` at the bottom emits the C header.
##
## Consumed by [logos-libp2p-mix-rln](https://github.com/logos-co/logos-libp2p-mix-rln)
## via its `metadata.json` `nix.external_libraries` entry.
##
## Delivery owns the node lifecycle, Relay coordination, and the switch used by
## Mix. `{.ffiEvent.}` bridges expose incoming mix messages and registration.
## Service-discovery-backed peer listing remains a placeholder.

import ffi

import std/[net, strutils, tables]
import chronos
import chronicles
import results

# Delivery owns the only libp2p switch used by this facade.
import libp2p/[multiaddress, peerid, switch, varint]
import libp2p/crypto/[crypto, secp]
import libp2p/crypto/curve25519 as lp_curve25519
import libp2p/protocols/connectivity/relay/relay as circuit_relay
import libp2p/stream/[connection, lpstream]

# nim-libp2p-mix — Sphinx routing + mix protocol.
import libp2p_mix
import
  libp2p_mix/[
    mix_protocol, mix_node, curve25519, pool, cover_traffic, exit_connection,
    serialization,
  ]

# Receiver-side helpers: mounting a plain LPProtocol on the exit switch so
# `exit_is_dest` mode can dispatch the payload into a host-visible handler.
import libp2p/protocols/protocol as lp_protocol
import stew/byteutils

# mix-rln-spam-protection-plugin — per-hop RLN proof gen/verify.
import mix_rln_spam_protection
import mix_rln_spam_protection/spam_protection as mix_rln

import
  logos_delivery/waku/[waku_core, waku_node],
  logos_delivery/waku/factory/[networks_config, node_factory, waku_conf],
  logos_delivery/waku/factory/conf_builder/conf_builder

# LibMixRln ------------------------------------------------------------------

type LibMixRln* = ref object
  ## Owned per FFI context. Every `{.ffi.}` proc receives one as its `lib`
  ## receiver and mutates through it. Lifetime is bounded by `libp2pMixRlnCreate`
  ## / `libp2pMixRlnDestroy`.
  node: WakuNode
  mixProto: MixProtocol
  coverTraffic: ConstantRateCoverTraffic
  rlnPlugin: MixRlnSpamProtection
  mixPubKey: seq[byte]
  transport: string
  running: bool
  stopped: bool

declareLibrary("libp2p_mix_rln", LibMixRln)

# ----------------------------------------------------------------------------
# Config include — mirrors LIP LOGOS-MIXNET config surface as `{.ffi.}` types.
# ----------------------------------------------------------------------------

include "libp2p_mix_rln/config"

# Request / response types --------------------------------------------------

type NodeInfoField {.ffi.} = enum
  ## Field selector for `libp2pMixRlnGetNodeInfo`. Kept as a string enum so the
  ## wire vocabulary is stable across languages. Prefixed to avoid collisions
  ## with libp2p types (`PeerId`) referenced elsewhere in this file.
  NIF_Version = "version"
  NIF_PeerId = "peer_id"
  NIF_Multiaddrs = "multiaddrs"
  NIF_MixPublicKey = "mix_public_key"
  NIF_RlnMembershipIndex = "rln_membership_index"

type NodeInfoRequest {.ffi.} = object
  field: NodeInfoField

type NodeInfoResponse {.ffi.} = object
  value: string ## For Multiaddrs, a comma-joined list (parse on the host side).

type MixSendRequest {.ffi.} = object
  destPeerId: string ## Multibase-encoded libp2p peer id of the exit destination.
  destMultiaddr: string
    ## One routable multiaddr of the destination. Ignored when isExitDest=true.
  proto: string ## The libp2p protocol id the destination will accept the payload on.
  payload: seq[byte]
  expectReply: bool ## If true, includes a single-use SURB for a reply.
  numSurbs: int64 ## Non-zero only when expectReply=true; LIP LOGOS-MIXNET expects 1.
  timeoutMs: int64
  isExitDest: bool
    ## If true, address the exit as the destination (uses
    ## `MixDestination.exitNode(peerId)`, which needs a `--d:libp2p_mix_experimental_exit_is_dest`
    ## build — the flag is on for this library). The exit's mounted
    ## protocol handler receives the payload directly. Use for
    ## intra-mixnet messaging where the receiver is also a mix node.
    ## If false, uses `MixDestination.forwardToAddr(peerId, multiaddr)`
    ## to dial an external destination.

type MixPeerRecord {.ffi.} = object
  ## Everything needed to install a peer in another node's `nodePool` so it
  ## can be picked as a Sphinx hop. Fetch via `libp2pMixRlnGetLocalMixPeerRecord`
  ## and hand to `libp2pMixRlnAddMixPeer` on other nodes.
  peerId: string
  multiaddrs: seq[string]
  mixPubKey: seq[byte] ## 32 bytes (Curve25519 pub).
  libp2pPubKeyHex: string ## Hex-encoded raw Secp256k1 pub bytes (33 bytes).

type MountReceiverRequest {.ffi.} = object
  ## Mounts a plain LPProtocol on the local switch under `codec`. Bytes arriving
  ## on that codec are read length-prefixed (readLp with `maxSize`) and fanned
  ## out via `onIncomingMixMessage` — so this pairs with the exit-is-dest
  ## flavor of `sendMixMessage`.
  codec: string
  maxSize: int64

type MixSendResponse {.ffi.} = object
  ok: bool

  reply: seq[byte] ## Empty unless expectReply=true and a reply was received.

type MixSurbReplyRequest {.ffi.} = object
  surb: seq[byte] ## Raw SURB bytes from IncomingMixMessageEvent.surb.
  payload: seq[byte]

type CoverRateResponse {.ffi.} = object
  rate: float64

type SetCoverRateRequest {.ffi.} = object
  rate: float64

type MixPeerEntry {.ffi.} = object
  peerId: string
  multiaddrs: seq[string]
  mixPubKey: seq[byte]

type MixPeersResponse {.ffi.} = object
  peers: seq[MixPeerEntry]

type RlnMembershipStatus {.ffi.} = object
  registered: bool
  index: int64 ## -1 when not registered.

# Events emitted from the FFI back to the host ------------------------------

type IncomingMixMessageEvent {.ffi.} = object
  proto: string
  payload: seq[byte]
  surb: seq[byte] ## Raw SURB bytes; empty when the sender did not include one.

type RlnMembershipRegisteredEvent {.ffi.} = object
  index: int64
  root: seq[byte]

type RlnPublishRequestedEvent {.ffi.} = object
  ## Legacy host-publish event retained for C ABI compatibility.
  contentTopic: string
  payload: seq[byte]

proc onIncomingMixMessage*(event: IncomingMixMessageEvent) {.ffiEvent.} =
  ## Fired when a mounted mix-destination protocol receives a message. Pass a
  ## non-empty `event.surb` to `libp2pMixRlnSendMixSurbReply` to reply.

proc onRlnMembershipRegistered*(event: RlnMembershipRegisteredEvent) {.ffiEvent.} =
  ## Fired after `libp2pMixRlnRegisterRlnMembership` succeeds.

proc onRlnPublishRequested*(event: RlnPublishRequestedEvent) {.ffiEvent.} =
  ## Retained for C ABI compatibility. Delivery now publishes coordination
  ## frames directly through Relay, so new hosts should not subscribe to it.
  # ----------------------------------------------------------------------------
  # Config helpers
  # ----------------------------------------------------------------------------

proc listenEndpoint(ma: string, transport: string): Result[(IpAddress, Port), string] =
  let expectedProtocol = if transport == "quic": "udp" else: "tcp"
  if transport == "quic" and not ma.endsWith("/quic-v1"):
    return err("QUIC listen multiaddr must end with /quic-v1: " & ma)

  let parts = ma.split('/')
  var address = static parseIpAddress("0.0.0.0")
  var port = Port(0)
  var foundAddress = false
  var foundTransport = false
  var i = 1
  while i + 1 < parts.len:
    case parts[i]
    of "ip4", "ip6":
      try:
        address = parseIpAddress(parts[i + 1])
        foundAddress = true
      except ValueError:
        return err("invalid listen IP address: " & parts[i + 1])
    of "tcp", "udp":
      try:
        if parts[i] == expectedProtocol:
          let value = parseInt(parts[i + 1])
          if value < 0 or value > high(uint16).int:
            return err("listen port is out of range: " & parts[i + 1])
          port = Port(value)
          foundTransport = true
      except ValueError:
        return err("invalid listen port: " & parts[i + 1])
    else:
      discard
    i += 2
  if not foundAddress or not foundTransport:
    return err(
      "listen multiaddr must contain an IP address and " & expectedProtocol & " port: " &
        ma
    )
  ok((address, port))

proc decodeHexPrivKey(hex: string, rng: Rng): SkPrivateKey {.raises: [].} =
  ## Decodes a hex-encoded raw Secp256k1 private key. Falls back to a fresh
  ## key when the input is empty; a *malformed* hex is logged and also falls
  ## back so a bad config knob can't take the node down at construction.
  if hex.len == 0:
    return SkKeyPair.random(rng).seckey
  try:
    var raw = newSeq[byte](hex.len div 2)
    let start = if hex.startsWith("0x") or hex.startsWith("0X"): 2 else: 0
    for i in 0 ..< (hex.len - start) div 2:
      raw[i] = byte(parseHexInt(hex[start + 2 * i .. start + 2 * i + 1]))
    let sk = SkPrivateKey.init(raw)
    if sk.isOk:
      return sk.value
  except CatchableError as e:
    warn "invalid privKeyHex — generating fresh key", err = e.msg
  SkKeyPair.random(rng).seckey

# ----------------------------------------------------------------------------
# Constructor / destructor
# ----------------------------------------------------------------------------

proc buildRlnConfig(cfg: MixRlnConfig): mix_rln.MixRlnConfig =
  var rlnCfg = defaultConfig()
  rlnCfg.keystorePath = cfg.rln.keystorePath
  rlnCfg.keystorePassword = cfg.rln.keystorePassword
  rlnCfg.treePath = cfg.rln.treePath
  rlnCfg.rlnResourcesPath = cfg.rln.rlnResourcesPath
  rlnCfg.epochDurationSeconds = float(cfg.rln.epochDurationSeconds)
  rlnCfg.maxEpochGap = cfg.rln.maxEpochGap
  rlnCfg.userMessageLimit = cfg.rln.userMessageLimit
  rlnCfg.membershipContentTopic = cfg.rln.membershipContentTopic
  rlnCfg.proofMetadataContentTopic = cfg.rln.proofMetadataContentTopic
  # rlnIdentifier: the C side passes hex; decode when the RlnIdentifier
  # hex-parse helper is added. Falling back to the plugin's default keeps
  # dev/testnet flows working.

  rlnCfg

proc buildDeliveryConf(
    cfg: MixRlnConfig, rng: Rng, coverTraffic: ConstantRateCoverTraffic
): Result[WakuConf, string] {.raises: [].} =
  let transport = if cfg.transport.len == 0: "tcp" else: cfg.transport
  if transport != "tcp" and transport != "quic":
    return err("transport must be tcp or quic")

  let listen =
    if cfg.addrs.len > 0:
      cfg.addrs[0]
    elif transport == "quic":
      "/ip4/0.0.0.0/udp/0/quic-v1"
    else:
      "/ip4/0.0.0.0/tcp/0"
  let (listenAddress, listenPort) = listenEndpoint(listen, transport).valueOr:
    return err(error)
  if cfg.rln.coordCluster < 0 or cfg.rln.coordCluster > high(uint16).int64:
    return err("RLN coordination cluster is out of range")

  let skkey = decodeHexPrivKey(cfg.privKeyHex, rng)
  let privateKey = PrivateKey(scheme: Secp256k1, skkey: skkey)

  var builder = WakuConfBuilder.init()
  builder.withNodeKey(privateKey)
  builder.withClusterId(uint16(cfg.rln.coordCluster))
  builder.withRelay(true)
  builder.withShardingConf(AutoSharding)
  builder.withNumShardsInCluster(1)
  builder.withP2pListenAddress(listenAddress)
  if transport == "quic":
    builder.withP2pTcpPort(Port(0))
    builder.quicConf.withEnabled(true)
    builder.quicConf.withQuicPort(listenPort)
  else:
    builder.withP2pTcpPort(listenPort)
  builder.withMix(true)
  if cfg.maxConnections > 0:
    builder.withMaxConnections(cfg.maxConnections)

  builder.mixConf.withEnabled(true)
  if cfg.mix.mixPrivKeyHex.len > 0:
    builder.mixConf.withMixKey(cfg.mix.mixPrivKeyHex)
  builder.mixConf.withMixRln(buildRlnConfig(cfg))
  builder.mixConf.withCoverTraffic(CoverTraffic(coverTraffic))
  builder.build(rng)

proc libp2pMixRlnCreate*(
    cfg: MixRlnConfig
): Future[Result[LibMixRln, string]] {.ffiCtor.} =
  ## Builds one Delivery node and mounts Relay, Mix, and Mix-RLN on its switch.
  ## Does not start the node — call `libp2pMixRlnStart` for that.
  ##
  ## `{.ffiCtor.}` is nim-ffi's constructor pragma: no library receiver, returns
  ## the freshly-built LibMixRln. Nim-ffi transfers ownership to the C side,
  ## which releases it via the `{.ffiDtor.}` below.
  let rng = newRng()
  let transport = if cfg.transport.len == 0: "tcp" else: cfg.transport
  if cfg.mix.coverRateFraction <= 0.0 or cfg.mix.coverRateFraction > 1.0:
    return err("coverRateFraction must be in (0.0, 1.0]")
  if cfg.rln.userMessageLimit <= 0:
    return err("userMessageLimit must be positive")
  if cfg.rln.epochDurationSeconds <= 0:
    return err("epochDurationSeconds must be positive")

  let coverTraffic = ConstantRateCoverTraffic.new(
    totalSlots = cfg.rln.userMessageLimit,
    epochDuration = cfg.rln.epochDurationSeconds.seconds,
    coverRateFraction = cfg.mix.coverRateFraction,
    useInternalEpochTimer = false,
  )

  let conf = buildDeliveryConf(cfg, rng, coverTraffic).valueOr:
    return err(error)
  let node = (await setupNode(conf, rng, circuit_relay.Relay.new())).valueOr:
    return err(error)
  if node.wakuMix.isNil() or node.wakuMixRln.isNil():
    await node.stop()
    return err("Delivery did not mount Mix-RLN")
  if node.wakuMix.switch != node.switch:
    await node.stop()
    return err("Delivery Mix mounted on a different libp2p switch")

  ok(
    LibMixRln(
      node: node,
      mixProto: node.wakuMix,
      coverTraffic: coverTraffic,
      rlnPlugin: node.wakuMixRln,
      mixPubKey: node.wakuMix.pubKey.getBytes(),
      transport: transport,
      running: false,
      stopped: false,
    )
  )

proc libp2pMixRlnDestroy*(lib: LibMixRln): Future[void] {.ffiDtor.} =
  ## Stops the Delivery node (idempotent) and drops references. The FFI runtime
  ## reclaims the LibMixRln object itself.
  if not lib.stopped:
    try:
      await lib.node.stop()
    except CatchableError as e:
      warn "Delivery node stop failed", err = e.msg
    lib.stopped = true
  lib.running = false

# ----------------------------------------------------------------------------
# Lifecycle
# ----------------------------------------------------------------------------
proc isTransportAddr(raw, transport: string): bool =
  if transport == "quic":
    raw.contains("/udp/") and raw.endsWith("/quic-v1")
  else:
    raw.contains("/tcp/")

proc selectMixAddr(
    addrs: openArray[string], transport: string
): Result[MultiAddress, string] {.raises: [].} =
  for raw in addrs:
    if isTransportAddr(raw, transport):
      let ma = MultiAddress.init(raw).valueOr:
        return err("invalid " & transport & " multiaddr: " & error)
      return ok(ma)
  err("no bound " & transport & " multiaddr found")

proc libp2pMixRlnStart*(lib: LibMixRln): Future[Result[bool, string]] {.ffi.} =
  if lib.running:
    return ok(true)
  try:
    await lib.node.start()
  except CatchableError as e:
    return err("Delivery node start failed: " & e.msg)
  var boundAddrs: seq[string]
  for addr in lib.node.switch.peerInfo.addrs:
    boundAddrs.add($addr)
  let localAddr = selectMixAddr(boundAddrs, lib.transport).valueOr:
    await lib.node.stop()
    return err(error)
  lib.mixProto.setLocalMultiAddr(localAddr).isOkOr:
    await lib.node.stop()
    return err("failed to set local Mix address: " & error)

  lib.stopped = false
  lib.running = true
  ok(true)

proc libp2pMixRlnStop*(lib: LibMixRln): Future[Result[bool, string]] {.ffi.} =
  if not lib.running:
    return ok(true)
  try:
    await lib.node.stop()
  except CatchableError as e:
    return err("Delivery node stop failed: " & e.msg)
  lib.running = false
  lib.stopped = true
  ok(true)

# ----------------------------------------------------------------------------
# Node introspection
# ----------------------------------------------------------------------------

proc libp2pMixRlnGetNodeInfo*(
    lib: LibMixRln, req: NodeInfoRequest
): Future[Result[NodeInfoResponse, string]] {.ffi.} =
  case req.field
  of NIF_Version:
    ok(NodeInfoResponse(value: "0.1.0"))
  of NIF_PeerId:
    ok(NodeInfoResponse(value: $lib.node.switch.peerInfo.peerId))
  of NIF_Multiaddrs:
    var parts: seq[string]
    for a in lib.node.switch.peerInfo.addrs:
      parts.add($a)
    ok(NodeInfoResponse(value: parts.join(",")))
  of NIF_MixPublicKey:
    # Curve25519 pub, 32 bytes, hex-encoded.
    ok(NodeInfoResponse(value: byteutils.toHex(lib.mixPubKey)))
  of NIF_RlnMembershipIndex:
    let index = lib.rlnPlugin.getMembershipIndex()
    if index.isNone:
      return err("RLN membership is not registered")
    ok(NodeInfoResponse(value: $index.get()))

# ----------------------------------------------------------------------------
# RLN membership
# ----------------------------------------------------------------------------

proc libp2pMixRlnRegisterRlnMembership*(
    lib: LibMixRln
): Future[Result[RlnMembershipStatus, string]] {.ffi.} =
  ## Registers this node in the RLN group. Delivery publishes the membership
  ## frame over Relay and applies updates received from other nodes.
  let idx = (await lib.rlnPlugin.registerSelf()).valueOr:
    return err("registerSelf failed: " & error)
  # The Merkle root is available via the group manager; wire it into the
  # event body once that accessor's name is confirmed.
  onRlnMembershipRegistered(RlnMembershipRegisteredEvent(index: int64(idx), root: @[]))
  ok(RlnMembershipStatus(registered: true, index: int64(idx)))

proc libp2pMixRlnHasRlnMembership*(
    lib: LibMixRln
): Future[Result[RlnMembershipStatus, string]] {.ffi.} =
  let opt = lib.rlnPlugin.getMembershipIndex()
  if opt.isSome:
    ok(RlnMembershipStatus(registered: true, index: int64(opt.get())))
  else:
    ok(RlnMembershipStatus(registered: false, index: -1))

# ----------------------------------------------------------------------------
# Mixnet send
# ----------------------------------------------------------------------------

proc libp2pMixRlnSendMixMessage*(
    lib: LibMixRln, req: MixSendRequest
): Future[Result[MixSendResponse, string]] {.ffi.} =
  ## Sends `req.payload` through a Sphinx circuit to the exit destination,
  ## which will unwrap and hand it to `req.proto` on the destination node.
  ## When `req.isExitDest` is set, addresses the exit as the destination
  ## (uses `MixDestination.exitNode`); otherwise routes to an external
  ## destination via `MixDestination.forwardToAddr`.
  let destPid = PeerId.init(req.destPeerId).valueOr:
    return err("invalid destPeerId: " & $error)

  let dest =
    if req.isExitDest:
      when defined(libp2p_mix_experimental_exit_is_dest):
        MixDestination.exitNode(destPid)
      else:
        return err(
          "isExitDest set but library built without " &
            "-d:libp2p_mix_experimental_exit_is_dest"
        )
    else:
      let addr0 = MultiAddress.init(req.destMultiaddr).valueOr:
        return err("invalid destMultiaddr: " & error)
      MixDestination.forwardToAddr(destPid, addr0)

  var params = MixParameters()
  if req.expectReply:
    params.expectReply = Opt.some(true)
    let n =
      if req.numSurbs > 0:
        byte(req.numSurbs)
      else:
        byte(1)
    params.numSurbs = Opt.some(n)
    if req.timeoutMs > 0:
      params.replyTimeout = Opt.some(req.timeoutMs.milliseconds)

  if req.expectReply and not lib.mixProto.hasDestReadBehavior(req.proto):
    lib.mixProto.registerDestReadBehavior(req.proto, readLp(MessageSize))

  let conn = lib.mixProto.toConnection(dest, req.proto, params).valueOr:
    return err("toConnection failed: " & error)

  try:
    await conn.writeLp(req.payload)
  except LPStreamError as e:
    try:
      await conn.close()
    except CatchableError:
      discard
    return err("writeLp failed: " & e.msg)

  var reply: seq[byte]
  if req.expectReply:
    try:
      reply = await conn.readLp(MessageSize)
    except LPStreamError as e:
      try:
        await conn.close()
      except CatchableError:
        discard
      return err("reply read failed: " & e.msg)

  try:
    await conn.close()
  except CatchableError as e:
    warn "conn.close failed after send", err = e.msg

  ok(MixSendResponse(ok: true, reply: reply))

proc serializeSurb(surb: SURB): seq[byte] =
  surb.hop.serialize() & surb.header.serialize() & surb.key

proc libp2pMixRlnSendMixSurbReply*(
    lib: LibMixRln, req: MixSurbReplyRequest
): Future[Result[bool, string]] {.ffi.} =
  let decoded = extractSURBs(@[1.byte] & req.surb).valueOr:
    return err("invalid SURB: " & error)
  let (surbs, trailing) = decoded
  if surbs.len != 1 or trailing.len != 0:
    return err("SURB must contain exactly one reply block")

  let prefix = PB.toBytes(req.payload.len.uint64)
  var framed = newSeq[byte](prefix.len + req.payload.len)
  framed[0 ..< prefix.len] = prefix.toOpenArray()
  framed[prefix.len ..< framed.len] = req.payload
  (await lib.mixProto.sendSurbReply(surbs[0], move(framed))).isOkOr:
    return err(error)
  ok(true)

# ----------------------------------------------------------------------------
# Discovery / cover traffic
# ----------------------------------------------------------------------------

proc libp2pMixRlnListMixPeers*(
    lib: LibMixRln
): Future[Result[MixPeersResponse, string]] {.ffi.} =
  ## Sourced from Logos Service Discovery + Extensible Peer Records once the
  ## discovery module is mounted. Placeholder returns an empty list.
  ok(MixPeersResponse(peers: @[]))

# ----------------------------------------------------------------------------
# Multi-node topology helpers
# ----------------------------------------------------------------------------
#
# LIP LOGOS-MIXNET expects Service Discovery to populate each node's peer
# knowledge. Until we mount SD, the host has to feed peers in manually. These
# three procs are the seam for that:
#   - GetLocalMixPeerRecord: this node's public info (peer id, addrs, mix pub
#     key, libp2p pub key hex) — pass to other nodes' AddMixPeer.
#   - AddMixPeer: install a peer record into the local `nodePool` so it can
#     be picked as a Sphinx hop.
#   - MountReceiver: mount a plain LPProtocol on the local switch under
#     `codec`; incoming lp-framed bytes fan out via `onIncomingMixMessage`.
#     Pairs with the exit-is-dest flavor of `sendMixMessage`.

proc libp2pMixRlnGetLocalMixPeerRecord*(
    lib: LibMixRln
): Future[Result[MixPeerRecord, string]] {.ffi.} =
  var addrs: seq[string]
  for a in lib.node.switch.peerInfo.addrs:
    addrs.add($a)
  # The libp2p pub key in MixNodeInfo is an SkPublicKey (raw secp256k1 pub).
  # `toRaw` gives 33 compressed bytes.
  let libp2pPubKeyBytes = lib.node.switch.peerInfo.publicKey.skkey.getBytes()
  ok(
    MixPeerRecord(
      peerId: $lib.node.switch.peerInfo.peerId,
      multiaddrs: addrs,
      mixPubKey: lib.mixPubKey,
      libp2pPubKeyHex: byteutils.toHex(libp2pPubKeyBytes),
    )
  )

proc libp2pMixRlnAddMixPeer*(
    lib: LibMixRln, rec: MixPeerRecord
): Future[Result[bool, string]] {.ffi.} =
  let peerId = PeerId.init(rec.peerId).valueOr:
    return err("invalid peerId: " & $error)
  let ma = selectMixAddr(rec.multiaddrs, lib.transport).valueOr:
    return err(error)
  let mixPub = bytesToFieldElement(rec.mixPubKey).valueOr:
    return err("invalid mixPubKey: " & error)
  var libp2pPubBytes: seq[byte]
  try:
    libp2pPubBytes = hexToSeqByte(rec.libp2pPubKeyHex)
  except ValueError as e:
    return err("invalid libp2pPubKeyHex: " & e.msg)
  let libp2pPub = SkPublicKey.init(libp2pPubBytes).valueOr:
    return err("SkPublicKey.init failed: " & $error)
  lib.mixProto.nodePool.add(MixPubInfo.init(peerId, ma, mixPub, libp2pPub))
  let remote = RemotePeerInfo.init(
    peerId, @[ma], mixPubKey = Opt.some(lp_curve25519.intoCurve25519Key(rec.mixPubKey))
  )
  try:
    await lib.node.connectToNodes(@[remote], "mix FFI")
  except CatchableError as exc:
    return err("failed to connect Delivery peer: " & exc.msg)
  ok(true)

type RlnCoordFrame {.ffi.} = object
  ## A coordination frame delivered to the plugin. `contentTopic` selects
  ## which handler runs (`handleMembershipUpdate` or `handleProofMetadata`);
  ## the plugin decodes `data` per topic.
  contentTopic: string
  data: seq[byte]

proc libp2pMixRlnDeliverCoordFrame*(
    lib: LibMixRln, frame: RlnCoordFrame
): Future[Result[bool, string]] {.ffi.} =
  ## Legacy injection path retained for C ABI compatibility. Delivery normally
  ## routes coordination frames from Relay into the local plugin.
  let plugin = lib.rlnPlugin
  if frame.contentTopic == plugin.getMembershipContentTopic():
    let r = await plugin.handleMembershipUpdate(frame.data)
    if r.isErr:
      return err("handleMembershipUpdate failed: " & r.error)
  elif frame.contentTopic == plugin.getProofMetadataContentTopic():
    let r = plugin.handleProofMetadata(frame.data)
    if r.isErr:
      return err("handleProofMetadata failed: " & r.error)
  else:
    return err("unknown contentTopic: " & frame.contentTopic)
  ok(true)

proc libp2pMixRlnMountReceiver*(
    lib: LibMixRln, req: MountReceiverRequest
): Future[Result[bool, string]] {.ffi.} =
  ## Mounts a plain LPProtocol on `codec`. On stream open the handler reads
  ## one length-prefixed frame (up to `maxSize`), fires an `onIncomingMixMessage`
  ## event with the payload, and closes. Also registers a
  ## `readLp(maxSize)` DestReadBehavior on the mix protocol so exit-is-dest
  ## replies frame correctly.
  let maxSize =
    if req.maxSize > 0:
      int(req.maxSize)
    else:
      1 shl 20 # 1MiB
  let codec = req.codec

  let handler = proc(
      conn: Connection, proto: string
  ) {.async: (raises: [CancelledError]).} =
    try:
      let bytes = await conn.readLp(maxSize)
      var surb: seq[byte]
      if conn of MixExitConnection:
        let surbs = MixExitConnection(conn).takeSURBs()
        if surbs.len > 0:
          surb = serializeSurb(surbs[0])
      onIncomingMixMessage(
        IncomingMixMessageEvent(proto: proto, payload: bytes, surb: surb)
      )
    except LPStreamError as e:
      warn "MountReceiver: readLp failed", codec = proto, err = e.msg
    finally:
      try:
        await conn.close()
      except CatchableError:
        discard

  let p = LPProtocol.new(codecs = @[codec], handler = handler)
  # When the Switch is already started (typical for post-start mounts triggered
  # from the host), Switch.mount(...) requires the protocol be started first.
  try:
    await p.start()
  except CatchableError as e:
    return err("receiver LPProtocol.start failed: " & e.msg)
  lib.node.switch.mount(p)
  lib.mixProto.registerDestReadBehavior(codec, readLp(maxSize))
  ok(true)

proc libp2pMixRlnGetCoverTrafficRate*(
    lib: LibMixRln
): Future[Result[CoverRateResponse, string]] {.ffi.} =
  ok(CoverRateResponse(rate: lib.coverTraffic.coverRateFraction()))

proc libp2pMixRlnSetCoverTrafficRate*(
    lib: LibMixRln, req: SetCoverRateRequest
): Future[Result[bool, string]] {.ffi.} =
  if req.rate <= 0.0 or req.rate > 1.0:
    return err("rate must be in (0.0, 1.0]")
  (await lib.coverTraffic.setCoverRateFraction(req.rate)).isOkOr:
    return err(error)
  ok(true)

# ----------------------------------------------------------------------------
# Emit the C header.
# ----------------------------------------------------------------------------

genBindings()
