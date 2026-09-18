# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Logos

## C FFI facade composing libp2p + nim-libp2p-mix + Mix-RLN.
##
## Modelled on vacp2p/nim-libp2p `cbind/libp2p.nim`: `{.ffi.}` types become
## CBOR-encoded request/response objects, `{.ffi.}` procs become C-exported
## async entry points, `genBindings()` at the bottom emits the C header.
##
## Consumed by [logos-libp2p-mix-rln](https://github.com/logos-co/logos-libp2p-mix-rln)
## via its `metadata.json` `nix.external_libraries` entry.
##
## Mix owns its libp2p switch. The host transports RLN coordination frames
## through a separate module, such as Relay-capable Logos Delivery.

import ffi

import std/[strutils, tables, json]
import chronos
import chronicles
import results

import libp2p/[multiaddress, peerid, switch, varint, builders]
import libp2p/crypto/[crypto, secp]
import libp2p/crypto/curve25519 as lp_curve25519
import libp2p/stream/[connection, lpstream]

# nim-libp2p-mix — Sphinx routing + mix protocol.
import libp2p_mix
import
  libp2p_mix/[
    mix_protocol, mix_node, curve25519, pool, cover_traffic, exit_connection,
    serialization, delay_strategy, spam_protection,
  ]

# Receiver-side helpers: mounting a plain LPProtocol on the exit switch so
# `exit_is_dest` mode can dispatch the payload into a host-visible handler.
import libp2p/protocols/protocol as lp_protocol
import stew/byteutils

# mix-rln-spam-protection-plugin — per-hop RLN proof gen/verify.
import mix_rln_spam_protection
import mix_rln_spam_protection/spam_protection as mix_rln
import mix_rln_spam_protection/[module_api, module_transport]

# LibMixRln ------------------------------------------------------------------

type LibMixRln* = ref object
  ## Owned per FFI context. Every `{.ffi.}` proc receives one as its `lib`
  ## receiver and mutates through it. Lifetime is bounded by `libp2pMixRlnCreate`
  ## / `libp2pMixRlnDestroy`.
  switch: Switch
  mixProto: MixProtocol
  coverTraffic: ConstantRateCoverTraffic
  rlnPlugin: MixRlnSpamProtection
  moduleRln: ModuleRlnProtection
  rlnRequests: RlnRequests
  registrationOptions: string
  transport: string
  allowSend: bool
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
  exitEnabled: bool
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

type RlnModuleRequestEvent {.ffi.} = object
  requestId: int64
  methodName: string
  argsJson: string

type RlnModuleResponse {.ffi.} = object
  requestId: int64
  responseJson: string

type RlnMembershipRegisteredEvent {.ffi.} = object
  index: int64
  root: seq[byte]

type RlnPublishRequestedEvent {.ffi.} = object
  ## The host must publish these bytes on the configured coordination channel.
  contentTopic: string
  payload: seq[byte]

proc onRlnModuleRequest*(event: RlnModuleRequestEvent) {.ffiEvent.} =
  ## Host invokes the shared RLN module and submits the response asynchronously.

proc onIncomingMixMessage*(event: IncomingMixMessageEvent) {.ffiEvent.} =
  ## Fired when a mounted mix-destination protocol receives a message. Pass a
  ## non-empty `event.surb` to `libp2pMixRlnSendMixSurbReply` to reply.

proc onRlnMembershipRegistered*(event: RlnMembershipRegisteredEvent) {.ffiEvent.} =
  ## Fired after `libp2pMixRlnRegisterRlnMembership` succeeds.

proc onRlnPublishRequested*(event: RlnPublishRequestedEvent) {.ffiEvent.} =
  ## Forward asynchronously; do not call back into this context from the event.
  # ----------------------------------------------------------------------------
  # Config helpers
  # ----------------------------------------------------------------------------

proc decodeHexPrivKey(hex: string, rng: Rng): Result[SkPrivateKey, string] =
  if hex.len == 0:
    return ok(SkKeyPair.random(rng).seckey)
  try:
    let key = SkPrivateKey.init(hexToSeqByte(hex)).valueOr:
      return err("invalid privKeyHex: " & $error)
    ok(key)
  except ValueError as exc:
    err("invalid privKeyHex: " & exc.msg)

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

  rlnCfg

proc buildSwitch(cfg: MixRlnConfig, rng: Rng): Result[Switch, string] =
  let transport = if cfg.transport.len == 0: "tcp" else: cfg.transport
  if transport notin ["tcp", "quic"]:
    return err("transport must be tcp or quic")
  let addresses =
    if cfg.addrs.len > 0:
      cfg.addrs
    elif transport == "quic":
      @["/ip4/0.0.0.0/udp/0/quic-v1"]
    else:
      @["/ip4/0.0.0.0/tcp/0"]
  var listenAddrs: seq[MultiAddress]
  for raw in addresses:
    let address = MultiAddress.init(raw).valueOr:
      return err("invalid listen multiaddr: " & error)
    if (transport == "tcp" and not TCP_IP4.match(address)) or
        (transport == "quic" and not QUIC_V1_IP4.match(address)):
      return err("listen multiaddr must use IPv4 and the configured transport: " & raw)
    listenAddrs.add(address)
  let key = decodeHexPrivKey(cfg.privKeyHex, rng).valueOr:
    return err(error)
  let privateKey = PrivateKey(scheme: Secp256k1, skkey: key)
  try:
    let builder = SwitchBuilder
      .new()
      .withRng(rng)
      .withPrivateKey(privateKey)
      .withAddresses(listenAddrs)
      .withMplex()
      .withNoise()
    if cfg.maxConnections > 0:
      discard builder.withMaxConnections(int(cfg.maxConnections))
    if cfg.maxConnsPerPeer > 0:
      discard builder.withMaxConnsPerPeer(int(cfg.maxConnsPerPeer))
    if transport == "quic":
      discard builder.withQuicTransport()
    else:
      discard builder.withTcpTransport()
    ok(builder.build())
  except CatchableError as exc:
    err("SwitchBuilder failed: " & exc.msg)

proc libp2pMixRlnCreate*(
    cfg: MixRlnConfig
): Future[Result[LibMixRln, string]] {.ffiCtor.} =
  ## Builds a standalone libp2p switch with Mix and per-hop RLN protection.
  ## Does not start the node — call `libp2pMixRlnStart` for that.
  ##
  ## `{.ffiCtor.}` is nim-ffi's constructor pragma: no library receiver, returns
  ## the freshly-built LibMixRln. Nim-ffi transfers ownership to the C side,
  ## which releases it via the `{.ffiDtor.}` below.
  let rng = newRng()
  let transport = if cfg.transport.len == 0: "tcp" else: cfg.transport
  if not (cfg.mix.coverRateFraction > 0.0 and cfg.mix.coverRateFraction <= 1.0):
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

  let switch = buildSwitch(cfg, rng).valueOr:
    return err(error)
  var (mixPrivKey, mixPubKey) = generateKeyPair().valueOr:
    return err(error)
  if cfg.mix.mixPrivKeyHex.len > 0:
    try:
      mixPrivKey = bytesToFieldElement(hexToSeqByte(cfg.mix.mixPrivKeyHex)).valueOr:
        return err("invalid mix private key: " & error)
      mixPubKey = lp_curve25519.public(mixPrivKey)
    except ValueError as exc:
      return err("invalid mix private key: " & exc.msg)
  let publish = proc(
      topic: string, data: seq[byte]
  ): Future[Result[void, string]] {.async.} =
    onRlnPublishRequested(RlnPublishRequestedEvent(contentTopic: topic, payload: data))
    return ok()
  var plugin: MixRlnSpamProtection
  var moduleRln: ModuleRlnProtection
  var requests: RlnRequests
  var protection: SpamProtection
  if cfg.rln.provider == "module":
    if cfg.rln.maxEpochGap < 0:
      return err("maxEpochGap must be non-negative")
    requests = RlnRequests.new(
      proc(id: int64, methodName, argsJson: string) {.gcsafe, raises: [].} =
        onRlnModuleRequest(
          RlnModuleRequestEvent(
            requestId: id, methodName: methodName, argsJson: argsJson
          )
        )
    )
    let transport = requests
    moduleRln = ModuleRlnProtection.new(
      ModuleRlnConfig(
        registryId: cfg.rln.registryId,
        rlnIdentifierHex: cfg.rln.rlnIdentifierHex,
        epochSeconds: uint64(cfg.rln.epochDurationSeconds),
        maxEpochGap: uint64(cfg.rln.maxEpochGap),
        messageLimit: cfg.rln.userMessageLimit,
        metadataTopic: cfg.rln.proofMetadataContentTopic,
      ),
      proc(
          methodName: string, args: JsonNode
      ): Future[Result[JsonNode, string]] {.async: (raises: [CancelledError]).} =
        return await transport.request(methodName, args),
    ).valueOr:
      return err(error)
    moduleRln.setPublishCallback(publish)
    protection = moduleRln
  elif cfg.rln.provider in ["", "embedded"]:
    plugin = MixRlnSpamProtection.new(buildRlnConfig(cfg)).valueOr:
      return err(error)
    (await plugin.init()).isOkOr:
      return err(error)
    plugin.setPublishCallback(publish)
    protection = plugin
  else:
    return err("Unknown RLN provider")
  let nodeInfo = initMixNodeInfo(
    switch.peerInfo.peerId,
    switch.peerInfo.listenAddrs[0],
    mixPubKey,
    mixPrivKey,
    switch.peerInfo.publicKey.skkey,
    switch.peerInfo.privateKey.skkey,
  )
  let proto = MixProtocol.new(
    nodeInfo,
    switch,
    spamProtection = Opt.some(protection),
    delayStrategy = Opt.some(DelayStrategy(SpamProtectionDelayStrategy.new(rng = rng))),
    coverTraffic = Opt.some(CoverTraffic(coverTraffic)),
    allowExit = cfg.mix.allowExit,
  )
  switch.mount(proto)
  ok(
    LibMixRln(
      allowSend: cfg.mix.allowSend,
      switch: switch,
      mixProto: proto,
      coverTraffic: coverTraffic,
      rlnPlugin: plugin,
      moduleRln: moduleRln,
      rlnRequests: requests,
      registrationOptions: cfg.rln.registrationOptionsJson,
      transport: transport,
    )
  )

proc stopRln(lib: LibMixRln) {.async.} =
  if not lib.rlnRequests.isNil:
    lib.rlnRequests.cancel()
  if not lib.moduleRln.isNil:
    await lib.moduleRln.stop()
  elif not lib.rlnPlugin.isNil:
    await lib.rlnPlugin.stop()

proc libp2pMixRlnRlnResponse*(
    lib: LibMixRln, response: RlnModuleResponse
): Future[Result[bool, string]] {.ffi.} =
  if lib.rlnRequests.isNil:
    return err("External RLN provider is not configured")
  lib.rlnRequests.respond(response.requestId, response.responseJson).isOkOr:
    return err(error)
  return ok(true)

proc libp2pMixRlnDestroy*(lib: LibMixRln): Future[void] {.ffiDtor.} =
  ## Stops the Mix switch (idempotent) and drops references. The FFI runtime
  ## reclaims the LibMixRln object itself.
  if not lib.stopped:
    try:
      await lib.stopRln()
      await lib.switch.stop()
    except CatchableError as e:
      warn "Mix switch stop failed", err = e.msg
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
  let started =
    if not lib.moduleRln.isNil:
      await lib.moduleRln.start()
    else:
      await lib.rlnPlugin.start()
  started.isOkOr:
    return err("RLN start failed: " & error)
  try:
    await lib.switch.start()
  except CatchableError as e:
    await lib.stopRln()
    return err("Mix switch start failed: " & e.msg)
  var boundAddrs: seq[string]
  for addr in lib.switch.peerInfo.addrs:
    boundAddrs.add($addr)
  let localAddr = selectMixAddr(boundAddrs, lib.transport).valueOr:
    await lib.stopRln()
    await lib.switch.stop()
    return err(error)
  lib.mixProto.setLocalMultiAddr(localAddr).isOkOr:
    await lib.stopRln()
    await lib.switch.stop()
    return err("failed to set local Mix address: " & error)

  lib.stopped = false
  lib.running = true
  ok(true)

proc libp2pMixRlnStop*(lib: LibMixRln): Future[Result[bool, string]] {.ffi.} =
  if not lib.running:
    return ok(true)
  try:
    await lib.stopRln()
    await lib.switch.stop()
  except CatchableError as e:
    return err("Mix switch stop failed: " & e.msg)
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
    ok(NodeInfoResponse(value: $lib.switch.peerInfo.peerId))
  of NIF_Multiaddrs:
    var parts: seq[string]
    for a in lib.switch.peerInfo.addrs:
      parts.add($a)
    ok(NodeInfoResponse(value: parts.join(",")))
  of NIF_MixPublicKey:
    # Curve25519 pub, 32 bytes, hex-encoded.
    ok(
      NodeInfoResponse(
        value:
          byteutils.toHex(fieldElementToBytes(lib.mixProto.localMixPubInfo.mixPubKey))
      )
    )
  of NIF_RlnMembershipIndex:
    if not lib.moduleRln.isNil:
      let state = (await lib.moduleRln.scopedCall("get_membership_state")).valueOr:
        return err(error)
      return
        ok(NodeInfoResponse(value: $state.getOrDefault("leaf_index").getBiggestInt(-1)))
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
  ## Registers this node and requests host publication of its membership frame.
  if not lib.moduleRln.isNil:
    let options =
      if lib.registrationOptions.len == 0: "[]" else: lib.registrationOptions
    let state = (await lib.moduleRln.scopedCall("register_membership", %*[options])).valueOr:
      return err(error)
    return ok(
      RlnMembershipStatus(
        registered: state.getOrDefault("state").getStr() in ["active", "grace_period"],
        index: state.getOrDefault("leaf_index").getBiggestInt(-1),
      )
    )
  let idx = (await lib.rlnPlugin.registerSelf()).valueOr:
    return err("registerSelf failed: " & error)
  # The Merkle root is available via the group manager; wire it into the
  # event body once that accessor's name is confirmed.
  onRlnMembershipRegistered(RlnMembershipRegisteredEvent(index: int64(idx), root: @[]))
  ok(RlnMembershipStatus(registered: true, index: int64(idx)))

proc libp2pMixRlnHasRlnMembership*(
    lib: LibMixRln
): Future[Result[RlnMembershipStatus, string]] {.ffi.} =
  if not lib.moduleRln.isNil:
    let state = (await lib.moduleRln.scopedCall("get_membership_state")).valueOr:
      return err(error)
    return ok(
      RlnMembershipStatus(
        registered: state.getOrDefault("state").getStr() in ["active", "grace_period"],
        index: state.getOrDefault("leaf_index").getBiggestInt(-1),
      )
    )
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
  if not lib.allowSend:
    return err("Application sending disabled; set mix.allowSend=true")
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
  if not lib.allowSend:
    return err("Application sending disabled; set mix.allowSend=true")
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
  var peers: seq[MixPeerEntry]
  for peerId in lib.mixProto.nodePool.peerIds:
    lib.mixProto.nodePool.get(peerId).withValue(info):
      peers.add(
        MixPeerEntry(
          peerId: $peerId,
          multiaddrs: @[$info.multiAddr],
          mixPubKey: fieldElementToBytes(info.mixPubKey),
        )
      )
  ok(MixPeersResponse(peers: peers))

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
  for a in lib.switch.peerInfo.addrs:
    addrs.add($a)
  # The libp2p pub key in MixNodeInfo is an SkPublicKey (raw secp256k1 pub).
  # `toRaw` gives 33 compressed bytes.
  let libp2pPubKeyBytes = lib.switch.peerInfo.publicKey.skkey.getBytes()
  ok(
    MixPeerRecord(
      exitEnabled: lib.mixProto.localMixPubInfo.exitEnabled,
      peerId: $lib.switch.peerInfo.peerId,
      multiaddrs: addrs,
      mixPubKey: fieldElementToBytes(lib.mixProto.localMixPubInfo.mixPubKey),
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
  lib.mixProto.nodePool.add(
    MixPubInfo.init(peerId, ma, mixPub, libp2pPub, rec.exitEnabled)
  )
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
  ## Applies a coordination frame received through the host transport.
  if not lib.moduleRln.isNil:
    if frame.contentTopic != lib.moduleRln.config.metadataTopic:
      return err("Unknown coordination topic")
    lib.moduleRln.handleProofMetadata(frame.data).isOkOr:
      return err(error)
    return ok(true)
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
  if not lib.mixProto.localMixPubInfo.exitEnabled:
    return err("Application exit delivery disabled; set mix.allowExit=true")
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
  lib.switch.mount(p)
  lib.mixProto.registerDestReadBehavior(codec, readLp(maxSize))
  ok(true)

proc libp2pMixRlnGetCoverTrafficRate*(
    lib: LibMixRln
): Future[Result[CoverRateResponse, string]] {.ffi.} =
  ok(CoverRateResponse(rate: lib.coverTraffic.coverRateFraction()))

proc libp2pMixRlnSetCoverTrafficRate*(
    lib: LibMixRln, req: SetCoverRateRequest
): Future[Result[bool, string]] {.ffi.} =
  (await lib.coverTraffic.setCoverRateFraction(req.rate)).isOkOr:
    return err(error)
  ok(true)

# ----------------------------------------------------------------------------
# Emit the C header.
# ----------------------------------------------------------------------------

genBindings()
