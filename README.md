# nim-libp2p-mix-ffi

C FFI facade composing [libp2p][libp2p] + [nim-libp2p-mix][mix] +
[mix-rln-spam-protection-plugin][mix-rln]. Mix owns a standalone libp2p
switch for routing. The host carries RLN coordination through an external
transport, such as a separate Relay-capable Delivery module. Produces
`liblibp2p_mix_rln.{so,dylib,dll}`
and `libp2p_mix_rln.h` for consumption by [logos-libp2p-mix-rln][logos-mod]'s
C++/Qt Logos Core module.

Modelled on `vacp2p/nim-libp2p`'s `cbind` package. Uses [nim-ffi][nim-ffi]
for pragma-driven codegen of the C header.

Application endpoint capabilities are opt-in: `MixConfig.allowSend` and
`MixConfig.allowExit` both default to false. `allowSend` gates application
sends and explicit SURB replies; `allowExit` gates receiver mounting and
local/external exit delivery. Intermediate forwarding and cover loops
remain active. Set both flags for an endpoint that receives and explicitly
replies. `MixPeerRecord.exitEnabled` advertises exit eligibility; preserve
it when copying records. Senders select only advertised exits, while each
receiving node independently enforces its own exit policy.

## Status

The C smoke test runs five nodes over TCP and QUIC using a mock shared RLN
backend. It covers asynchronous callback transport, endpoint restrictions,
Sphinx routing, metadata coordination, and SURB replies. The mock does not
perform cryptography.

Real shared-backend proofs, funded memberships, Delivery interoperability, and
no-direct-fallback behavior are exercised by the seven-host
[Logos module fixture](https://github.com/logos-co/logos-libp2p-mix-rln/tree/feat/standalone-mix-intermediate/tests/integration_e2e/shared_delivery_mix).

## Build (nix, hermetic)

```sh
nix build .#cbind
# → result/lib/liblibp2p_mix_rln.{so,a}
# → result/include/libp2p_mix_rln.h + tinycbor/
```

The facade does not link a local RLN cryptography library. Its host must
provide `liblogos_rln_module` and service the asynchronous proof requests.

## Tests

```sh
nix build .#test-mix-routing         # 5-node Sphinx circuit (no RLN)
nix build .#smoketest-3node-ffi      # C routing test with a mock shared backend
```

## What's real vs. stubbed

Real, exercised at runtime:
- Full lifecycle (`create` / `start` / `stop` / `destroy`).
- `sendMixMessage` — Sphinx-routed writeLp, optional SURB reply.
- `sendMixMessageToExit` — exit-is-dest routing, no exit multiaddr needed.
- `registerRlnMembership` / `hasRlnMembership`.
- `getNodeInfo(Version | PeerId | Multiaddrs | MixPublicKey)`.
- Multi-node topology: `getLocalMixPeerRecord`, `addMixPeer`, and
  `mountReceiver`; intermediate hops require no application receiver.
- Events: `onIncomingMixMessage`, `onRlnModuleRequest`, and
  `onRlnPublishRequested`.
- SURB replies, membership-index lookup and live cover-rate updates.

The host must subscribe to `onRlnPublishRequested` before starting traffic,
publish the topic and bytes through its coordination transport,
and inject received frames with `deliverCoordFrame`. Dispatch transport calls
outside the FFI callback. `addMixPeer` only installs a routing record; it does
not connect the external coordination transport. TCP and QUIC both bind on
Mix's own switch. Proof generation always uses the shared backend.

Service discovery is not wired: `listMixPeers` reports the manually populated
pool. Shared-provider membership synchronization belongs to the registry backend.

## Shared RLN provider

Set `registryId` and `rlnIdentifierHex` in `RlnConfig`. Configure matching
epochs, accepted gap, and metadata topic on all participants. There is no
provider selector or embedded fallback.

Before starting the node, start the backend and arrange active scoped
memberships. Subscribe to `RlnModuleRequestEvent`, forward its `methodName`
and ordered `argsJson` arguments asynchronously, and return the backend JSON
with `libp2pMixRlnRlnResponse` using the original request ID. Never block the
Nim event loop waiting for a backend call. The generated C API exposes the
response operation as `rln_response`.

The adapter owns proof encoding and metadata exchange; the backend owns
credentials, cryptography, registry state, and durable proof quota. Shared
mode coordinates proof metadata only: it does not gossip legacy membership
announcements. `registerRlnMembership` submits registration options to the
backend; callers must observe activation before generating proofs. Shutdown
cancels pending backend requests; late responses are rejected.

The shared adapter is used by native Delivery Mix as well as this facade.
Consumers must rebuild against the generated C header: the provider selector,
local keystore/tree/resource settings, membership topic, and local membership
registration event have been removed. Observe membership activation through
the backend or the membership query API.

## Layout

```
nim-libp2p-mix-ffi/
├── nim_libp2p_mix_rln_ffi.nimble  # package + buildffi + genbindings_c
├── libp2p_mix_rln.nim             # FFI entry — declareLibrary(), types, procs
├── libp2p_mix_rln/config.nim      # {.ffi.} config schema
├── nix/
│   ├── cbind.nix                  # hermetic build derivation
│   ├── cbind-deps.nix             # pinned deps from nimble.lock
│   ├── smoketest-3node-ffi.nix    # C smoke test derivation
│   └── test-mix-routing.nix       # 5-node Sphinx test (no RLN)
├── tools/regen-cbind-deps.py      # regenerate cbind-deps.nix after bumping pins
├── flake.nix                      # outputs packages.<system>.{cbind,tests}
├── tests/                         # Nim + C integration tests
├── Makefile
├── UPSTREAM_ISSUES.md             # blockers/gaps found upstream during integration
├── config.nims
├── LICENSE-MIT
└── LICENSE-APACHEv2
```

## Local (non-nix) build

```sh
make setup
make buildffi
make genbindings
```

[libp2p]: https://github.com/vacp2p/nim-libp2p
[mix]: https://github.com/logos-co/nim-libp2p-mix
[mix-rln]: https://github.com/logos-co/mix-rln-spam-protection-plugin
[logos-mod]: https://github.com/logos-co/logos-libp2p-mix-rln
[nim-ffi]: https://github.com/logos-messaging/nim-ffi
