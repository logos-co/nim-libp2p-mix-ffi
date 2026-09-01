// 5-node end-to-end smoke test driven entirely through the C FFI.
//
// Spins up five LibMixRln contexts in one process, cross-registers their
// mix peer records so each node's Sphinx path selector knows the others,
// mounts a `/logosmix/test/echo/1.0.0` receiver on node C, and calls
// `sendMixMessage(destPeerId=C, proto=/logosmix/test/echo/1.0.0,
// isExitDest=true)` on node A. A→B→C route is then picked by the mix
// protocol; C's mounted receiver fires the `onIncomingMixMessage` event
// with the payload, which this test verifies matches what A sent.

#define _POSIX_C_SOURCE 200809L

#include <libp2p_mix_rln.h>

#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

extern void liblibp2p_mix_rlnNimMain(void);

static const char* kTestCodec = "/logosmix/test/echo/1.0.0";
static const char* kTestPayload = "hello mix";

// -------- generic sync-over-async waiter ----------------------------------

typedef struct {
    pthread_mutex_t m;
    pthread_cond_t  c;
    int             done;
    int             err_code;
    char            err_msg[512];
    LibMixRlnCtx*   ctx;         // for ctx_create
    MixPeerRecord   rec;         // for get_local_mix_peer_record (owned copy)
    int             rec_valid;
    bool            reply_bool;
    int             reply_bool_valid;
} Waiter;

static void waiter_init(Waiter* w) {
    pthread_mutex_init(&w->m, NULL);
    pthread_cond_init(&w->c, NULL);
    w->done = 0;
    w->err_code = -999;
    w->err_msg[0] = '\0';
    w->ctx = NULL;
    w->rec_valid = 0;
    w->reply_bool = false;
    w->reply_bool_valid = 0;
}

static void waiter_signal(Waiter* w) {
    pthread_mutex_lock(&w->m);
    w->done = 1;
    pthread_cond_signal(&w->c);
    pthread_mutex_unlock(&w->m);
}

static int waiter_wait(Waiter* w, int timeout_s) {
    pthread_mutex_lock(&w->m);
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec += timeout_s;
    int rc = 0;
    while (!w->done && rc == 0) rc = pthread_cond_timedwait(&w->c, &w->m, &ts);
    pthread_mutex_unlock(&w->m);
    return rc;
}

// -------- typed callbacks -------------------------------------------------

static void on_created(int ec, LibMixRlnCtx* ctx, const char* em, void* ud) {
    Waiter* w = (Waiter*)ud;
    w->err_code = ec;
    w->ctx = ctx;
    if (em) snprintf(w->err_msg, sizeof(w->err_msg), "%s", em);
    waiter_signal(w);
}

static void on_bool(int ec, const bool* reply, const char* em, void* ud) {
    Waiter* w = (Waiter*)ud;
    w->err_code = ec;
    if (reply) { w->reply_bool = *reply; w->reply_bool_valid = 1; }
    if (em) snprintf(w->err_msg, sizeof(w->err_msg), "%s", em);
    waiter_signal(w);
}

static void on_mix_send(int ec, const MixSendResponse* r, const char* em, void* ud) {
    Waiter* w = (Waiter*)ud;
    w->err_code = ec;
    if (r) { w->reply_bool = r->ok; w->reply_bool_valid = 1; }
    if (em) snprintf(w->err_msg, sizeof(w->err_msg), "%s", em);
    waiter_signal(w);
}

// Deep-copies the reply into the waiter — the reply memory is owned by the
// binding and freed after this callback returns.
static void on_peer_record(int ec, const MixPeerRecord* r,
                           const char* em, void* ud) {
    Waiter* w = (Waiter*)ud;
    w->err_code = ec;
    if (r) {
        memset(&w->rec, 0, sizeof(w->rec));
        // peerId
        w->rec.peerId.data = strndup(r->peerId.data ? r->peerId.data : "",
                                     r->peerId.data ? r->peerId.len : 0);
        w->rec.peerId.len = r->peerId.data ? r->peerId.len : 0;
        // libp2pPubKeyHex
        w->rec.libp2pPubKeyHex.data = strndup(
            r->libp2pPubKeyHex.data ? r->libp2pPubKeyHex.data : "",
            r->libp2pPubKeyHex.data ? r->libp2pPubKeyHex.len : 0);
        w->rec.libp2pPubKeyHex.len = r->libp2pPubKeyHex.data ? r->libp2pPubKeyHex.len : 0;
        // mixPubKey
        w->rec.mixPubKey.len = r->mixPubKey.len;
        w->rec.mixPubKey.data = malloc(r->mixPubKey.len);
        memcpy(w->rec.mixPubKey.data, r->mixPubKey.data, r->mixPubKey.len);
        // multiaddrs — deep copy each string
        w->rec.multiaddrs.len = r->multiaddrs.len;
        w->rec.multiaddrs.data = calloc(r->multiaddrs.len, sizeof(NimFfiStr));
        for (size_t i = 0; i < r->multiaddrs.len; i++) {
            const NimFfiStr* s = &r->multiaddrs.data[i];
            w->rec.multiaddrs.data[i].data = strndup(s->data ? s->data : "",
                                                     s->data ? s->len : 0);
            w->rec.multiaddrs.data[i].len = s->data ? s->len : 0;
        }
        w->rec_valid = 1;
    }
    if (em) snprintf(w->err_msg, sizeof(w->err_msg), "%s", em);
    waiter_signal(w);
}

// -------- incoming-mix event listener on node C --------------------------

typedef struct {
    pthread_mutex_t m;
    pthread_cond_t  c;
    atomic_int      fired;
    uint8_t         payload[4096];
    size_t          payload_len;
    char            proto[128];
} InboxSlot;

static void on_incoming(const IncomingMixMessageEvent* evt, void* ud) {
    InboxSlot* s = (InboxSlot*)ud;
    pthread_mutex_lock(&s->m);
    size_t plen = evt->payload.len < sizeof(s->payload) - 1
                  ? evt->payload.len : sizeof(s->payload) - 1;
    memcpy(s->payload, evt->payload.data, plen);
    s->payload_len = plen;
    size_t nlen = evt->proto.len < sizeof(s->proto) - 1
                  ? evt->proto.len : sizeof(s->proto) - 1;
    memcpy(s->proto, evt->proto.data, nlen);
    s->proto[nlen] = '\0';
    atomic_store(&s->fired, 1);
    pthread_cond_signal(&s->c);
    pthread_mutex_unlock(&s->m);
}

// -------- node builder ----------------------------------------------------

static LibMixRlnCtx* make_node(const char* listen_multiaddr) {
    NimFfiStr addr = nimffi_str(listen_multiaddr);
    MixRlnConfig cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.addrs.data = &addr;
    cfg.addrs.len = 1;
    cfg.transport = nimffi_str("tcp");
    cfg.maxConnections = 50;
    cfg.maxInConnections = 25;
    cfg.maxOutConnections = 25;
    cfg.maxConnsPerPeer = 1;
    cfg.mix.coverRateFraction = 0.7;
    cfg.rln.epochDurationSeconds = 1;
    cfg.rln.period = 1;
    cfg.rln.messagingRate = 10;
    cfg.rln.maxEpochGap = 20;
    cfg.rln.userMessageLimit = 100;
    cfg.rln.acceptableRootWindowSize = 5;
    cfg.rln.membershipContentTopic = nimffi_str("/mix/rln/membership/v1");
    cfg.rln.proofMetadataContentTopic = nimffi_str("/mix/rln/metadata/v1");
    cfg.discovery.mountServiceDiscovery = false;
    cfg.discovery.serviceId = nimffi_str("logos.mixnet");

    Waiter w; waiter_init(&w);
    (void)libp2p_mix_rln_ctx_create(&cfg, on_created, &w);
    if (waiter_wait(&w, 60) != 0 || w.err_code != 0 || !w.ctx) {
        fprintf(stderr, "ctx_create failed on %s: %s\n",
                listen_multiaddr, w.err_msg);
        return NULL;
    }
    return w.ctx;
}

static int fetch_record(LibMixRlnCtx* ctx, MixPeerRecord* out) {
    Waiter w; waiter_init(&w);
    (void)libp2p_mix_rln_ctx_get_local_mix_peer_record(ctx, on_peer_record, &w);
    if (waiter_wait(&w, 10) != 0 || w.err_code != 0 || !w.rec_valid) return -1;
    *out = w.rec;
    return 0;
}

static void free_record(MixPeerRecord* rec) {
    free(rec->peerId.data);
    free(rec->libp2pPubKeyHex.data);
    free(rec->mixPubKey.data);
    for (size_t i = 0; i < rec->multiaddrs.len; i++)
        free(rec->multiaddrs.data[i].data);
    free(rec->multiaddrs.data);
    memset(rec, 0, sizeof(*rec));
}

static int add_peer(LibMixRlnCtx* ctx, const MixPeerRecord* rec, const char* label) {
    Waiter w; waiter_init(&w);
    (void)libp2p_mix_rln_ctx_add_mix_peer(ctx, rec, on_bool, &w);
    int wait_rc = waiter_wait(&w, 10);
    if (wait_rc != 0) {
        fprintf(stderr, "add_peer(%s): TIMEOUT\n", label);
        return -1;
    }
    if (w.err_code != 0) {
        fprintf(stderr, "add_peer(%s): err_code=%d msg='%s'\n",
                label, w.err_code, w.err_msg);
        return -1;
    }
    return 0;
}

static int start_node(LibMixRlnCtx* ctx) {
    Waiter w; waiter_init(&w);
    (void)libp2p_mix_rln_ctx_start(ctx, on_bool, &w);
    if (waiter_wait(&w, 30) != 0 || w.err_code != 0) return -1;
    return 0;
}

static int stop_node(LibMixRlnCtx* ctx) {
    Waiter w; waiter_init(&w);
    (void)libp2p_mix_rln_ctx_stop(ctx, on_bool, &w);
    if (waiter_wait(&w, 30) != 0) return -1;
    return 0;
}

static void on_membership(int ec, const RlnMembershipStatus* r,
                          const char* em, void* ud) {
    Waiter* w = (Waiter*)ud;
    w->err_code = ec;
    if (r) { w->reply_bool = r->registered; w->reply_bool_valid = 1; }
    if (em) snprintf(w->err_msg, sizeof(w->err_msg), "%s", em);
    waiter_signal(w);
}

static int register_membership(LibMixRlnCtx* ctx, int idx) {
    Waiter w; waiter_init(&w);
    (void)libp2p_mix_rln_ctx_register_rln_membership(ctx, on_membership, &w);
    if (waiter_wait(&w, 30) != 0 || w.err_code != 0) {
        fprintf(stderr, "register_membership[%d]: err_code=%d msg='%s'\n",
                idx, w.err_code, w.err_msg);
        return -1;
    }
    return 0;
}

int main(void) {
    liblibp2p_mix_rlnNimMain();
    fprintf(stderr, "[smoke] NimMain done\n");

    // LIP LOGOS-MIXNET fixes path length at 3, and nim-libp2p-mix's path
    // selector needs a pool of at least that many DISTINCT candidates
    // (excluding self + destination). 5 total nodes gives the selector real
    // choice per Sphinx path.
    enum { N = 5 };
    LibMixRlnCtx* nodes[N];
    MixPeerRecord recs[N];
    for (int i = 0; i < N; i++) {
        nodes[i] = make_node("/ip4/127.0.0.1/tcp/0");
        if (!nodes[i]) { fprintf(stderr, "node[%d] create failed\n", i); return 1; }
    }
    fprintf(stderr, "[smoke] %d nodes created\n", N);

    // Start FIRST — ephemeral TCP ports aren't populated in peerInfo.addrs
    // until the switch's listener binds, and add_mix_peer rejects an empty
    // multiaddrs list. Peer discovery doesn't need to happen pre-start, so
    // the order start → fetch → cross-register works fine.
    for (int i = 0; i < N; i++)
        if (start_node(nodes[i])) { fprintf(stderr, "start[%d] failed\n", i); return 1; }
    fprintf(stderr, "[smoke] all %d nodes started\n", N);

    // Fetch each node's public record so we can cross-register.
    for (int i = 0; i < N; i++)
        if (fetch_record(nodes[i], &recs[i])) {
            fprintf(stderr, "fetch_record[%d] failed\n", i); return 1;
        }
    fprintf(stderr, "[smoke] fetched records; exit(node %d).peerId=%.*s\n",
            N - 1, (int)recs[N - 1].peerId.len, recs[N - 1].peerId.data);

    // Cross-register: every node learns about every other node.
    for (int i = 0; i < N; i++)
        for (int j = 0; j < N; j++) {
            if (i == j) continue;
            char label[32];
            snprintf(label, sizeof(label), "n%d<-n%d", i, j);
            if (add_peer(nodes[i], &recs[j], label)) return 1;
        }
    fprintf(stderr, "[smoke] cross-registered all %dx%d peers\n", N, N - 1);
    LibMixRlnCtx* A = nodes[0];      // sender
    LibMixRlnCtx* C = nodes[N - 1];  // exit / destination
    MixPeerRecord* recC = &recs[N - 1];

    // Membership updates propagate over Delivery Relay. Registrations remain
    // sequential until distributed member-index allocation is implemented.
    for (int i = 0; i < N; i++)
        if (register_membership(nodes[i], i)) return 1;
    struct timespec relay_settle = { .tv_sec = 2, .tv_nsec = 0 };
    nanosleep(&relay_settle, NULL);
    fprintf(stderr, "[smoke] all RLN memberships registered over Delivery Relay\n");

    // Mount receiver on C.
    MountReceiverRequest mreq;
    memset(&mreq, 0, sizeof(mreq));
    mreq.codec = nimffi_str(kTestCodec);
    mreq.maxSize = 4096;
    Waiter mw; waiter_init(&mw);
    (void)libp2p_mix_rln_ctx_mount_receiver(C, &mreq, on_bool, &mw);
    if (waiter_wait(&mw, 10) != 0 || mw.err_code != 0) {
        fprintf(stderr, "mount_receiver failed: %s\n", mw.err_msg); return 1;
    }

    // Register incoming-mix listener on C.
    InboxSlot inbox;
    memset(&inbox, 0, sizeof(inbox));
    pthread_mutex_init(&inbox.m, NULL);
    pthread_cond_init(&inbox.c, NULL);
    atomic_store(&inbox.fired, 0);
    (void)libp2p_mix_rln_ctx_add_on_incoming_mix_message_listener(
        C, on_incoming, &inbox);
    fprintf(stderr, "[smoke] mounted receiver + event listener on C\n");

    // A sends to C via mix path.
    MixSendRequest sr;
    memset(&sr, 0, sizeof(sr));
    sr.destPeerId    = recC->peerId;
    sr.destMultiaddr = nimffi_str("");
    sr.proto         = nimffi_str(kTestCodec);
    sr.payload.data  = (uint8_t*)kTestPayload;
    sr.payload.len   = strlen(kTestPayload);
    sr.expectReply   = false;
    sr.numSurbs      = 0;
    sr.timeoutMs     = 15000;
    sr.isExitDest    = true;

    Waiter sw; waiter_init(&sw);
    fprintf(stderr, "[smoke] sending mix message from A to C\n");
    (void)libp2p_mix_rln_ctx_send_mix_message(A, &sr, on_mix_send, &sw);
    if (waiter_wait(&sw, 30) != 0 || sw.err_code != 0) {
        fprintf(stderr, "send_mix_message failed: %s\n", sw.err_msg); return 1;
    }
    fprintf(stderr, "[smoke] send returned OK; waiting for delivery event on C...\n");

    // Wait for C's inbox to fire.
    pthread_mutex_lock(&inbox.m);
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec += 30;
    while (!atomic_load(&inbox.fired)) {
        int rc = pthread_cond_timedwait(&inbox.c, &inbox.m, &ts);
        if (rc != 0) {
            fprintf(stderr, "TIMEOUT waiting for inbox\n");
            pthread_mutex_unlock(&inbox.m); return 2;
        }
    }
    pthread_mutex_unlock(&inbox.m);

    fprintf(stderr, "[smoke] inbox fired: proto='%s' payload_len=%zu payload='%.*s'\n",
            inbox.proto, inbox.payload_len,
            (int)inbox.payload_len, inbox.payload);

    // Verify contents.
    int ok = (inbox.payload_len == strlen(kTestPayload)) &&
             (memcmp(inbox.payload, kTestPayload, inbox.payload_len) == 0) &&
             (strcmp(inbox.proto, kTestCodec) == 0);
    if (!ok) { fprintf(stderr, "PAYLOAD MISMATCH\n"); return 3; }
    fprintf(stderr, "[smoke] PASS: payload delivered end-to-end\n");

    // Cleanup.
    for (int i = 0; i < N; i++) (void)stop_node(nodes[i]);
    for (int i = 0; i < N; i++) libp2p_mix_rln_ctx_destroy(nodes[i]);
    for (int i = 0; i < N; i++) free_record(&recs[i]);
    return 0;
}
