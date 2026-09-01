# Upstream issues found while building `nim-libp2p-mix-rln-ffi`

Copy each section as-is into the corresponding upstream repo's issue tracker.
Reported by: [your GitHub handle], during work on
`logos-co/nim-libp2p-mix-rln-ffi` and `logos-co/logos-libp2p-mix-rln`.

---

## 1. `vacp2p/zerokit` — flake fails at cargo-vendor step: crates.io 403

**File in:** https://github.com/vacp2p/zerokit/issues

### Title
`nix build .#rln` fails: crates.io 403 on empty User-Agent from pinned nixpkgs' `fetch-cargo-vendor-util`

### Body
Any downstream flake that consumes `zerokit.packages.<system>.rln` fails at
the `zerokit-3.0.0-vendor-staging` derivation with:

```
Exception: Failed to fetch file from https://crates.io/api/v1/crates/colorchoice/1.0.5/download. Status code: 403
```

**Root cause:** `flake.nix` pins nixpkgs at rev
`23d72dabcb3b12469f57b37170fcbc1789bd7457` (release-25.11). At that revision,
`nixpkgs/pkgs/build-support/rust/fetch-cargo-vendor-util` makes HTTP requests
to crates.io without a `User-Agent` header, and crates.io now rejects
empty-UA requests with 403.

Reproduction with plain curl (bypasses nix entirely):

```
$ curl -so /dev/null -w '%{http_code}\n' https://crates.io/api/v1/crates/colorchoice/1.0.5/download
403
$ curl -so /dev/null -w '%{http_code}\n' -A 'any-ua' https://crates.io/api/v1/crates/colorchoice/1.0.5/download
302
```

**Impact:** Nobody can build `librln.a` through zerokit's flake at the moment.
(Local `cargo build --release --lib` in `zerokit/rln/` works fine — produces
a 42 MB `librln.a` in about 40 s. So the problem is exclusive to the nix
build path.)

**Suggested fix:** Bump the `nixpkgs` input to a post-2026-03 revision of
`nixpkgs-unstable` where `fetch-cargo-vendor-util` sets a `User-Agent`.

---

## 2. `vacp2p/nim-libp2p` — `cbind` nim-ffi SHA is unfetchable

**File in:** https://github.com/vacp2p/nim-libp2p/issues

### Title
`cbind/cbind.nimble` pins nim-ffi at an unmerged-branch SHA; `nimble setup` fails to fetch it

### Body
`cbind/cbind.nimble` pins `nim-ffi` at
`b95e2b04a63fbd417938bf3ec0ac14be7935e21b`. That SHA lives on the unmerged
feature branch `fix/cbor-non-canonical` and is **not** an ancestor of
`origin/master`. nimble's shallow-clone-of-default-branch strategy never
fetches it:

```
Error: Execution of 'git … checkout --force b95e2b04a63fbd417938bf3ec0ac14be7935e21b' failed with an exit code 128.
Details: fatal: reference is not a tree: b95e2b04a63fbd417938bf3ec0ac14be7935e21b
```

`cbind.nimble` already flags this in a comment:

```nim
# nim-ffi head of the unmerged `fix/cbor-non-canonical`; repin to a tag on merge
```

The same CBOR fix has since been merged as squashed commit `83f1aae` on
`master` (PR #141), and current `master` head is
`b6c17dc822960b626d76d814de90208c0a40a44e`.

**Impact:** Any downstream that copies `cbind`'s `nimble.lock` as a starting
point (as `nim-libp2p-mix-rln-ffi` does) inherits this and can't complete
`nimble -l setup` without manual work.

**Suggested fix:** Repin `nim-ffi` to a `master`-reachable SHA or to a tag
once one is cut on the 0.3 line.

---

## 3. `nim-lang/nimble` (0.24.0) — SAT solver hides the actual conflict; several flags don't do what they say

**File in:** https://github.com/nim-lang/nimble/issues

### Title
SAT solver emits `Unsatisfiable dependencies` without naming the conflicting pair; `--useSystemNim` and `--solver:legacy` don't help

### Body
Working on a Nim package that requires nim-ffi + cbor_serialization +
`libp2p == 2.1.4` + `nim-libp2p-mix` + `mix-rln-spam-protection-plugin`,
`nimble -l setup` fails with:

```
vnext.nim(275) resolveNim
Error: Couldnt find a solution for the packages. Unsatisfiable dependencies.
Check there is no contradictory dependencies.
```

Even with `--verbose`, the actual conflicting **pair** is never surfaced.
The output lists every dep and its first-level transitives, then says
`Tip: 174 messages have been suppressed, use --verbose to show them.` — and
those suppressed messages appear to be the ones that would explain the
conflict. Passing `--verbose` did not surface them either.

Repro environment: nim 2.2.10 (installed via choosenim), nimble 0.24.0,
Linux x86_64.

Additional issues found while trying to work around this:

1. `--useSystemNim` reports **"No system nim found"** even when nim is on
   `PATH` at `/home/r/.nimble/bin/nim` (installed by choosenim, i.e. by
   nimble itself). It seems nimble doesn't consider its own installed nim
   to be "system nim". Passing `--nim:/home/r/.nimble/bin/nim` explicitly
   still routes through the same failing `resolveNim` path.

2. `--solver:legacy` still enters `vnext.nim`'s solver and produces the
   same error, suggesting the flag has no effect.

3. `#master` fragments on git-URL requires are rejected outright:
   ```
   requires "https://github.com/logos-co/mix-rln-spam-protection-plugin.git#master"
   ```
   yields `The string 'master' does not represent a valid sha1 hash value.`
   This is a regression from older nimble which accepted branch names.

### Asks
1. When SAT fails, print the minimal conflicting pair (which two
   constraints can't both be true), not a repeat of the input.
2. Fix `--useSystemNim` to accept nim on `PATH` regardless of provenance.
3. Either restore branch-name fragment support or document its removal.

---

## 4. `logos-co/nim-libp2p-mix` — libp2p version drift creates a diamond dep

**File in:** https://github.com/logos-co/nim-libp2p-mix/issues

### Title
HEAD pins `libp2p == 2.0.0`; blocks composition with `mix-rln-spam-protection-plugin` (pins 2.1.4)

### Body
`libp2p_mix.nimble` at HEAD:

```nim
requires "nim >= 2.2.4",
  "libp2p == 2.0.0", ...
```

But `logos-co/mix-rln-spam-protection-plugin` at HEAD:

```nim
requires "libp2p == 2.1.4"
```

Any downstream that wants both plugins on their newest state has to pin
one to an older SHA to collapse the diamond. `mix-rln-spam-protection-plugin`
already works around this by pinning `nim-libp2p-mix` at
`c387ca67cf477dc53ec6228027c45d8eda067917` (an older commit that agrees on
`libp2p == 2.1.4`).

The same repo's own README acknowledges this pattern is fragile:

> Now that vacp2p/nim-libp2p publishes release tags, this is a version
> requirement rather than a SHA pin (see issue #8).

**Suggested fix:** Bump `nim-libp2p-mix` HEAD to require `libp2p >= 2.1.4`
(or whatever `mix-rln-spam-protection-plugin` currently targets) so both
plugins' HEADs can be consumed together without pinning gymnastics.

---

## 5a. `logos-co/nim-libp2p-mix` — missing public accessors and constructors

**File in:** https://github.com/logos-co/nim-libp2p-mix/issues

### Title
Missing public API: `MixNodeInfo.mixPubKey` bytes, cover-traffic runtime handle, `MixNodeInfo` builder from existing keypair, SURB reply-store lookup

### Body
Trying to build a full-featured FFI facade around `nim-libp2p-mix` (see
`logos-co/nim-libp2p-mix-rln-ffi`), I hit four API gaps that force downstream
authors to either fork the module or leave features stubbed:

1. **No public accessor to serialize `MixNodeInfo.mixPubKey` as bytes.**
   Needed for advertising the Curve25519 public key via Extensible Peer
   Records (LIP LOGOS-MIXNET's Service Discovery requirement). The field
   is exposed but `FieldElement → seq[byte]` isn't publicly available.

2. **`MixNodeInfo.generateRandom` requires a port up front.**
   Hosts that use a keystore and bind ports later have no way to build a
   `MixNodeInfo` from an existing libp2p keypair without also committing
   to a listen port. Consider a builder like:
   ```nim
   proc init(T: typedesc[MixNodeInfo],
             libp2pPrivKey: SkPrivateKey,
             multiAddr: MultiAddress,
             rng: Rng): T
   ```

3. **Cover-traffic scheduler is write-once.** `MixProtocol.new(...,
   coverTraffic = Opt.some(...))` accepts an initial `CoverTraffic`, but
   there is no public method to change the rate at runtime after
   construction. LIP LOGOS-MIXNET calls out cover-traffic tuning knobs
   (`cover_rate_fraction`) as configurable.

4. **No public SURB reply-store lookup.** `MixProtocol` builds SURBs and
   the reply path is exercised through `MixEntryConnection`'s internal
   loop, but there's no exposed "reply along this SURB by ID" surface.
   That blocks implementing `sendSurbReply` outside the module.

Happy to write PRs for any of these if you can confirm the shape you want.

---

## 5b. `logos-co/mix-rln-spam-protection-plugin` — no public Merkle root accessor

**File in:** https://github.com/logos-co/mix-rln-spam-protection-plugin/issues

### Title
`MixRlnSpamProtection.getMembershipIndex()` exists; matching Merkle-root accessor doesn't

### Body
`MixRlnSpamProtection` exposes `getMembershipIndex(): Option[MembershipIndex]`
(public), but there's no matching public accessor for the current Merkle
root. LIP LOGOS-MIXNET §… requires exposing the acceptable-root window
(default 5) so that hosts can, e.g., emit a
`RlnMembershipRegistered{ index, root }` event or verify inbound proofs
against a specific historical root.

Right now the root is reachable only via `groupManager` internals.

**Suggested fix:** Add a public method like:
```nim
proc getMembershipRoot(sp: MixRlnSpamProtection): Option[seq[byte]]
```
and, ideally, an iterator over the acceptable-root window.

---

## 6. `logos-co/logos-lips` PR #387 — LIP LOGOS-MIXNET blocks implementations with TBDs

**File in:** the PR/issue you're already tracking on `logos-co/logos-lips`

### Title
LIP LOGOS-MIXNET blockers: several parameters marked TBD prevent spec-compliant implementations

### Body
Working on a reference implementation
(`logos-co/nim-libp2p-mix-rln-ffi` + `logos-co/logos-libp2p-mix-rln`), it isn't
possible to ship anything spec-compliant until the following are pinned:

**Numeric parameters (all TBD in spec):**
- `period`
- `messaging_rate`
- `max_epoch_gap`
- `staked_fund`

**Coordination-layer identifiers (all TBD):**
- RLN Relay content topic for membership frames
- RLN Relay content topic for proof-metadata frames
- Coord cluster ID
- RLN identifier for the Logos deployment (32-byte hex)

**Undefined interfaces:**
- Service Discovery `serviceId` string that mix-capable nodes should
  advertise under. The spec requires SD + Extensible Peer Records but
  doesn't say what to advertise.
- Transport for RLN Relay coord frames. `mix-rln-spam-protection-plugin`
  exposes `setPublishCallback(topic, data)` and expects the host to route
  it, but the spec doesn't say what module/channel the host should use.

The transport wiring is resolved for this facade by logos-delivery PR #4182:
Delivery publishes and consumes these frames on Relay without a host-side
forwarding bus. The deployment identifiers above still need specification.

Our current scaffold carries placeholder defaults for every knob above
(with a README warning that these MUST be pinned before mainnet use), so we
can iterate on shape while the values are settled — but they need real
values before anything real ships.
