// Five-node C ABI test with a mock shared RLN backend.
// Exercises callback transport, Sphinx routing, coordination,
// and SURB replies. The mock does not verify cryptography; the Logos module's
// shared_delivery_mix fixture covers real proofs and registry memberships.

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
static const char* kReplyPayload = "hello back";

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
    uint8_t         reply_bytes[4096];
    size_t          reply_bytes_len;
    char            reply_string[512];
    int64_t         reply_index;
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
    w->reply_bytes_len = 0;
    w->reply_string[0] = '\0';
    w->reply_index = -1;
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
    if (r)
        snprintf(w->reply_string, sizeof(w->reply_string), "%.*s",
                 (int)r->messageId.len, r->messageId.data);
    if (em) snprintf(w->err_msg, sizeof(w->err_msg), "%s", em);
    waiter_signal(w);
}

// Deep-copies the reply into the waiter — the reply memory is owned by the

static void on_peers(int ec, const MixPeersResponse* r, const char* em, void* ud) {
    Waiter* w = (Waiter*)ud;
    w->err_code = ec;
    w->reply_index = r ? (int64_t)r->peers.len : -1;
    if (em) snprintf(w->err_msg, sizeof(w->err_msg), "%s", em);
    waiter_signal(w);
}

static void on_node_info(int ec, const NodeInfoResponse* r,
                         const char* em, void* ud) {
    Waiter* w = (Waiter*)ud;
    w->err_code = ec;
    if (r)
        snprintf(w->reply_string, sizeof(w->reply_string), "%.*s",
                 (int)r->value.len, r->value.data);
    if (em) snprintf(w->err_msg, sizeof(w->err_msg), "%s", em);
    waiter_signal(w);
}

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
    uint8_t         surbs[4096];
    size_t          surbs_len;
} InboxSlot;

static void on_incoming(const IncomingMixMessageEvent* evt, void* ud) {
    InboxSlot* s = (InboxSlot*)ud;
    fprintf(stderr, "[smoke] incoming request reached destination; surb_len=%zu\n",
            evt->surbs.len);
    pthread_mutex_lock(&s->m);
    size_t plen = evt->payload.len < sizeof(s->payload) - 1
                  ? evt->payload.len : sizeof(s->payload) - 1;
    memcpy(s->payload, evt->payload.data, plen);
    s->payload_len = plen;
    size_t nlen = evt->proto.len < sizeof(s->proto) - 1
                  ? evt->proto.len : sizeof(s->proto) - 1;
    memcpy(s->proto, evt->proto.data, nlen);
    s->proto[nlen] = '\0';
    if (evt->surbs.len > sizeof(s->surbs)) abort();
    s->surbs_len = evt->surbs.len;
    if (s->surbs_len) memcpy(s->surbs, evt->surbs.data, s->surbs_len);
    atomic_store(&s->fired, 1);
    pthread_cond_signal(&s->c);
    pthread_mutex_unlock(&s->m);
}

typedef struct {
    pthread_mutex_t m;
    pthread_cond_t c;
    int count;
    char ids[8][64];
    int invalid_payload;
} ReplySlot;

static void on_reply_received(const MixReplyReceivedEvent* evt, void* ud) {
    ReplySlot* replies = ud;
    pthread_mutex_lock(&replies->m);
    if (replies->count >= 8) abort();
    snprintf(replies->ids[replies->count], sizeof(replies->ids[0]), "%.*s",
             (int)evt->messageId.len, evt->messageId.data);
    replies->count++;
    if (evt->payload.len != strlen(kReplyPayload) ||
        memcmp(evt->payload.data, kReplyPayload, evt->payload.len))
        replies->invalid_payload = 1;
    pthread_cond_signal(&replies->c);
    pthread_mutex_unlock(&replies->m);
}

static int wait_replies(ReplySlot* replies, int expected) {
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += 15;
    pthread_mutex_lock(&replies->m);
    int rc = 0;
    while (replies->count < expected && !rc)
        rc = pthread_cond_timedwait(&replies->c, &replies->m, &deadline);
    int failed = rc || replies->invalid_payload;
    pthread_mutex_unlock(&replies->m);
    return failed;
}

static int wait_inbox(InboxSlot* inbox) {
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += 15;
    pthread_mutex_lock(&inbox->m);
    int rc = 0;
    while (!atomic_load(&inbox->fired) && !rc)
        rc = pthread_cond_timedwait(&inbox->c, &inbox->m, &deadline);
    pthread_mutex_unlock(&inbox->m);
    return rc;
}

// Nonblocking replies re-enter through the FFI queue, never wait on its event loop.
typedef struct {
    LibMixRlnCtx* ctx;
    int index;
    atomic_int membership_mode;
} MockBackend;

static atomic_int backend_errors;
static atomic_uint proof_serial;
static atomic_uint verified_proofs;

static void field_hex(char out[65], uint64_t value) {
    memset(out, '0', 64);
    for (int i = 0; i < 8; i++)
        snprintf(out + i * 2, 3, "%02x", (unsigned)((value >> (i * 8)) & 255));
    memset(out + 16, '0', 48);
    out[64] = '\0';
}

static void on_backend_response(int ec, const bool* reply, const char* em, void* ud) {
    (void)ud;
    if (ec || !reply || !*reply) {
        fprintf(stderr, "backend response failed: %s\n", em ? em : "false reply");
        atomic_fetch_add(&backend_errors, 1);
    }
}

static void on_backend_request(const RlnModuleRequestEvent* evt, void* ud) {
    MockBackend* backend = ud;
    char method[64], body[1200];
    snprintf(method, sizeof(method), "%.*s", (int)evt->methodName.len, evt->methodName.data);
    if (strcmp(method, "get_registry_parameters") == 0) {
        snprintf(body, sizeof(body), "{\"epoch_size_sec\":10,\"max_epoch_gap\":3}");
    } else if (strcmp(method, "register_membership") == 0 ||
               strcmp(method, "get_membership_state") == 0) {
        int mode = atomic_load(&backend->membership_mode);
        const char* states[] = {"active", "pending", "expired"};
        if (mode == 3)
            snprintf(body, sizeof(body), "{\"error\":{\"class\":\"transient\",\"message\":\"unavailable\"}}");
        else
            snprintf(body, sizeof(body), "{\"state\":\"%s\",\"leaf_index\":%d}",
                     states[mode], backend->index);
    } else if (strcmp(method, "generate_proof") == 0) {
        // The final scoped argument is the timestamp requested by the adapter.
        char* args = strndup(evt->argsJson.data, evt->argsJson.len);
        char* timestamp = strrchr(args, ',');
        if (!timestamp) abort();
        do { timestamp++; } while (*timestamp == ' ' || *timestamp == '"');
        char epoch[65], serial[65], zero[65], proof[257];
        field_hex(epoch, strtoull(timestamp, NULL, 10) / 10);
        field_hex(serial, atomic_fetch_add(&proof_serial, 1) + 1);
        field_hex(zero, 0);
        memset(proof, '0', 256); proof[256] = '\0';
        snprintf(body, sizeof(body),
                 "{\"proof\":\"%s\",\"root\":\"%s\",\"epoch\":\"%s\","
                 "\"share_x\":\"%s\",\"share_y\":\"%s\",\"nullifier\":\"%s\"}",
                 proof, zero, epoch, serial, serial, serial);
        free(args);
    } else if (strcmp(method, "validate_proof") == 0) {
        char zero[65]; field_hex(zero, 0);
        snprintf(body, sizeof(body), "{\"verdict\":\"valid\",\"external_nullifier\":\"%s\"}", zero);
        atomic_fetch_add(&verified_proofs, 1);
    } else {
        fprintf(stderr, "unexpected backend method: %s\n", method);
        abort();
    }
    RlnModuleResponse response = {.requestId = evt->requestId, .responseJson = nimffi_str(body)};
    if (libp2p_mix_rln_ctx_rln_response(backend->ctx, &response, on_backend_response, NULL))
        atomic_fetch_add(&backend_errors, 1);
}

static void on_membership_event(const RlnMembershipEvent* evt, void* ud) {
    Waiter* w = ud;
    w->err_code = evt->error.len ? 1 : 0;
    NimFfiStr value = evt->error.len ? evt->error : evt->stateJson;
    snprintf(w->reply_string, sizeof(w->reply_string), "%.*s", (int)value.len, value.data);
    waiter_signal(w);
}

// -------- node builder ----------------------------------------------------

static int check_create_config(MixRlnConfig cfg) {
    MixRlnConfig missing_scope = cfg;
    missing_scope.rln.registryId = nimffi_str("");
    Waiter missing; waiter_init(&missing);
    (void)libp2p_mix_rln_ctx_create(&missing_scope, on_created, &missing);
    if (waiter_wait(&missing, 60) || !missing.err_code || missing.ctx) return -1;
    const char* bad_keys[] = {"not-hex", "01", "0000000000000000000000000000000000000000000000000000000000000000"};
    for (size_t i = 0; i < sizeof(bad_keys) / sizeof(bad_keys[0]); i++) {
        cfg.privKeyHex = nimffi_str(bad_keys[i]);
        Waiter w; waiter_init(&w);
        (void)libp2p_mix_rln_ctx_create(&cfg, on_created, &w);
        if (waiter_wait(&w, 60) || !w.err_code || w.ctx) return -1;
    }
    const char* keys[] = {
        "0000000000000000000000000000000000000000000000000000000000000001",
        "0x0000000000000000000000000000000000000000000000000000000000000001"
    };
    char peer_id[512] = {0};
    for (size_t i = 0; i < 2; i++) {
        cfg.privKeyHex = nimffi_str(keys[i]);
        Waiter w; waiter_init(&w);
        (void)libp2p_mix_rln_ctx_create(&cfg, on_created, &w);
        if (waiter_wait(&w, 60) || w.err_code || !w.ctx) return -1;
        NodeInfoRequest req = {.field = NODE_INFO_FIELD_NIF_PEER_ID};
        Waiter info; waiter_init(&info);
        (void)libp2p_mix_rln_ctx_get_node_info(w.ctx, &req, on_node_info, &info);
        if (waiter_wait(&info, 10) || info.err_code) return -1;
        libp2p_mix_rln_ctx_destroy(w.ctx);
        if (i == 0) snprintf(peer_id, sizeof(peer_id), "%s", info.reply_string);
        else if (strcmp(peer_id, info.reply_string)) return -1;
    }
    cfg.privKeyHex = nimffi_str("");
    NimFfiStr bad_addr = nimffi_str("/ip6/::1/tcp/0");
    cfg.addrs.data = &bad_addr;
    cfg.addrs.len = 1;
    Waiter w; waiter_init(&w);
    (void)libp2p_mix_rln_ctx_create(&cfg, on_created, &w);
    return waiter_wait(&w, 60) || !w.err_code || w.ctx ? -1 : 0;
}

static LibMixRlnCtx* make_node(const char* listen_multiaddr, const char* transport) {
    NimFfiStr addr = nimffi_str(listen_multiaddr);
    MixRlnConfig cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.addrs.data = &addr;
    cfg.addrs.len = 1;
    cfg.transport = nimffi_str(transport);
    cfg.maxConnections = 50;
    cfg.maxConnsPerPeer = 2;
    cfg.mix.coverRateFraction = 0.01;
    cfg.rln.registryId = nimffi_str("logos:local:ffi-test");
    cfg.rln.rlnIdentifierHex = nimffi_str("6d69782d726c6e2d7370616d2d70726f74656374696f6e2f7631000000000000");
    cfg.rln.epochDurationSeconds = 10;
    cfg.rln.maxEpochGap = 3;
    cfg.rln.userMessageLimit = 100;
    cfg.rln.proofMetadataContentTopic = nimffi_str("/mix/rln/metadata/v1");

    static bool config_checked = false;
    if (!config_checked) {
        if (check_create_config(cfg)) {
            fprintf(stderr, "configuration validation failed\n");
            return NULL;
        }
        config_checked = true;
    }
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
    int wait_rc = waiter_wait(&w, 30);
    if (wait_rc != 0 || w.err_code != 0) {
        fprintf(stderr, "start_node: wait=%d err_code=%d msg='%s'\n",
                wait_rc, w.err_code, w.err_msg);
        return -1;
    }
    return 0;
}

static int stop_node(LibMixRlnCtx* ctx) {
    Waiter w; waiter_init(&w);
    (void)libp2p_mix_rln_ctx_stop(ctx, on_bool, &w);
    if (waiter_wait(&w, 10) != 0 || w.err_code || !w.reply_bool) return -1;
    return 0;
}

// -------- RLN coord bus ---------------------------------------------------
//
// In production, an RLN publish_requested event goes out on RLN Relay and is
// re-delivered to every other node's plugin via the coord channel. For this
// in-process test we bridge synchronously: onRlnPublishRequested captures the
// frame, and after each origin op we drain the queue into every other node's
// `libp2pMixRlnDeliverCoordFrame`.

typedef struct {
    uint8_t*    data;
    size_t      len;
    char*       topic;
    LibMixRlnCtx* source;
} CoordFrame;

typedef struct {
    pthread_mutex_t m;
    CoordFrame*     frames;
    size_t          count;
    size_t          cap;
} CoordBus;

static CoordBus g_bus;

static void bus_init(void) {
    pthread_mutex_init(&g_bus.m, NULL);
    g_bus.frames = NULL; g_bus.count = 0; g_bus.cap = 0;
}

static void bus_push(const char* topic, size_t topic_len,
                     const uint8_t* data, size_t data_len, LibMixRlnCtx* source) {
    pthread_mutex_lock(&g_bus.m);
    if (g_bus.count == g_bus.cap) {
        g_bus.cap = g_bus.cap ? g_bus.cap * 2 : 8;
        g_bus.frames = realloc(g_bus.frames, g_bus.cap * sizeof(CoordFrame));
    }
    CoordFrame* f = &g_bus.frames[g_bus.count++];
    f->topic = strndup(topic, topic_len);
    f->data = malloc(data_len);
    memcpy(f->data, data, data_len);
    f->len = data_len;
    f->source = source;
    pthread_mutex_unlock(&g_bus.m);
}

static void on_rln_publish(const RlnPublishRequestedEvent* evt, void* ud) {
    (void)ud;
    if (!evt) return;
    bus_push(evt->contentTopic.data, evt->contentTopic.len,
             evt->payload.data, evt->payload.len, ud);
}

// Detach the queue before submitting FFI calls; callbacks can enqueue concurrently.
static int drain_bus_to_all(LibMixRlnCtx** nodes, int n) {
    pthread_mutex_lock(&g_bus.m);
    size_t count = g_bus.count;
    CoordFrame* frames = g_bus.frames;
    g_bus.frames = NULL; g_bus.count = 0; g_bus.cap = 0;
    pthread_mutex_unlock(&g_bus.m);
    for (size_t i = 0; i < count; i++) {
        RlnCoordFrame req;
        memset(&req, 0, sizeof(req));
        req.contentTopic = nimffi_str(frames[i].topic);
        req.data.data = frames[i].data;
        req.data.len  = frames[i].len;
        for (int k = 0; k < n; k++) {
            if (nodes[k] == frames[i].source) continue;
            Waiter w; waiter_init(&w);
            (void)libp2p_mix_rln_ctx_deliver_coord_frame(nodes[k], &req, on_bool, &w);
            if (waiter_wait(&w, 10) != 0 || w.err_code != 0) {
                fprintf(stderr, "deliver_coord_frame TIMEOUT on node %d\n", k);
                return -1;
            }

        }
        free(frames[i].topic);
        free(frames[i].data);
    }
    free(frames);
    return 0;
}

static void on_membership(int ec, const RlnMembershipStatus* r,
                          const char* em, void* ud) {
    Waiter* w = (Waiter*)ud;
    w->err_code = ec;
    if (r) {
        w->reply_bool = r->registered;
        w->reply_bool_valid = 1;
        w->reply_index = r->index;
    }
    if (em) snprintf(w->err_msg, sizeof(w->err_msg), "%s", em);
    waiter_signal(w);
}

static int64_t register_membership(LibMixRlnCtx* ctx, int idx) {
    Waiter w; waiter_init(&w);
    (void)libp2p_mix_rln_ctx_register_rln_membership(ctx, on_membership, &w);
    if (waiter_wait(&w, 30) != 0 || w.err_code != 0) {
        fprintf(stderr, "register_membership[%d]: err_code=%d msg='%s'\n",
                idx, w.err_code, w.err_msg);
        return -1;
    }
    return w.reply_index;
}

static int get_membership_index(LibMixRlnCtx* ctx, int64_t* out) {
    Waiter w; waiter_init(&w);
    NodeInfoRequest req;
    memset(&req, 0, sizeof(req));
    req.field = NODE_INFO_FIELD_NIF_RLN_MEMBERSHIP_INDEX;
    (void)libp2p_mix_rln_ctx_get_node_info(ctx, &req, on_node_info, &w);
    if (waiter_wait(&w, 10) != 0 || w.err_code != 0) return -1;
    char* end = NULL;
    long long value = strtoll(w.reply_string, &end, 10);
    if (!end || *end != '\0') return -1;
    *out = (int64_t)value;
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
    const char* transport = getenv("MIX_TEST_TRANSPORT");
    if (!transport || transport[0] == '\0') transport = "tcp";
    const char* listen_multiaddr = strcmp(transport, "quic") == 0
        ? "/ip4/127.0.0.1/udp/0/quic-v1" : "/ip4/127.0.0.1/tcp/0";
    fprintf(stderr, "[smoke] transport=%s\n", transport);
    LibMixRlnCtx* nodes[N];
    MockBackend backends[N];
    MixPeerRecord recs[N];
    for (int i = 0; i < N; i++) {
        nodes[i] = make_node(listen_multiaddr, transport);
        if (!nodes[i]) { fprintf(stderr, "node[%d] create failed\n", i); return 1; }
        backends[i] = (MockBackend){.ctx = nodes[i], .index = i};
        (void)libp2p_mix_rln_ctx_add_on_rln_module_request_listener(
            nodes[i], on_backend_request, &backends[i]);
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
    for (int i = 0; i < N; i++) {
        Waiter w; waiter_init(&w);
        (void)libp2p_mix_rln_ctx_list_mix_peers(nodes[i], on_peers, &w);
        if (waiter_wait(&w, 10) || w.err_code || w.reply_index != N - 1) {
            fprintf(stderr, "list_mix_peers[%d] did not return the routing pool\n", i);
            return 1;
        }
    }
    LibMixRlnCtx* A = nodes[0];      // sender
    LibMixRlnCtx* C = nodes[N - 1];  // exit / destination
    MixPeerRecord* recC = &recs[N - 1];

    bus_init();
    for (int i = 0; i < N; i++)
        (void)libp2p_mix_rln_ctx_add_on_rln_publish_requested_listener(
            nodes[i], on_rln_publish, nodes[i]);
    int64_t membership_indices[N];
    for (int i = 0; i < N; i++) {
        membership_indices[i] = register_membership(nodes[i], i);
        if (membership_indices[i] != i || drain_bus_to_all(nodes, N)) return 1;
    }
    for (int i = 0; i < N; i++) {
        int64_t looked_up = -1;
        if (get_membership_index(nodes[i], &looked_up) ||
            looked_up != membership_indices[i]) {
            fprintf(stderr, "membership index lookup mismatch on node %d\n", i);
            return 1;
        }
    }
    fprintf(stderr, "[smoke] all memberships registered through the mock shared backend\n");

    Waiter observed; waiter_init(&observed);
    (void)libp2p_mix_rln_ctx_add_on_rln_membership_listener(A, on_membership_event, &observed);
    const char* expected_states[] = {"active", "pending", "expired", "unavailable"};
    for (int mode = 0; mode < 4; mode++) {
        atomic_store(&backends[0].membership_mode, mode);
        pthread_mutex_lock(&observed.m);
        observed.done = 0;
        pthread_mutex_unlock(&observed.m);
        Waiter refreshed; waiter_init(&refreshed);
        (void)libp2p_mix_rln_ctx_refresh_membership(A, on_bool, &refreshed);
        if (waiter_wait(&refreshed, 10) || refreshed.err_code ||
            waiter_wait(&observed, 10) || observed.err_code != (mode == 3) ||
            !strstr(observed.reply_string, expected_states[mode])) return 1;
    }
    atomic_store(&backends[0].membership_mode, 0);
    fprintf(stderr, "[smoke] PASS: full membership states and refresh errors\n");

    // Default nodes can mount receivers, send requests, and reply with SURBs.
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

    // Invalid bundles must be rejected before any reply is sent.
    uint8_t invalid_bundles[][2] = {{0, 0}, {0, 0}, {1, 0}, {0, 42}};
    size_t invalid_lengths[] = {0, 1, 1, 2};
    for (size_t i = 0; i < 4; ++i) {
        MixSurbReplyRequest bad = {0};
        bad.surbs.data = invalid_bundles[i];
        bad.surbs.len = invalid_lengths[i];
        Waiter invalid; waiter_init(&invalid);
        (void)libp2p_mix_rln_ctx_send_mix_surb_reply(C, &bad, on_bool, &invalid);
        if (waiter_wait(&invalid, 10) || !invalid.err_code) {
            fprintf(stderr, "invalid SURB bundle was not rejected\n");
            return 1;
        }
    }

    // A sends to C via mix path.
    MixSendRequest sr;
    memset(&sr, 0, sizeof(sr));
    sr.destPeerId    = recC->peerId;
    sr.proto         = nimffi_str(kTestCodec);
    sr.payload.data  = (uint8_t*)kTestPayload;
    sr.payload.len   = strlen(kTestPayload);
    sr.numSurbs      = 2;
    sr.timeoutMs     = 15000;

    // A failed write must close its reply connection; the next send must work.
    uint8_t oversized[8192] = {0};
    MixSendRequest rejected = sr;
    rejected.payload.data = oversized;
    rejected.payload.len = sizeof(oversized);
    Waiter failed; waiter_init(&failed);
    (void)libp2p_mix_rln_ctx_send_mix_message(A, &rejected, on_mix_send, &failed);
    if (waiter_wait(&failed, 10) || !failed.err_code ||
        !strstr(failed.err_msg, "send failed:")) {
        fprintf(stderr, "oversized send was not rejected: %s\n", failed.err_msg);
        return 1;
    }

    ReplySlot replies = {0};
    pthread_mutex_init(&replies.m, NULL);
    pthread_cond_init(&replies.c, NULL);
    (void)libp2p_mix_rln_ctx_add_on_mix_reply_received_listener(A, on_reply_received, &replies);

    int64_t invalid_counts[] = {-1, 256};
    for (size_t i = 0; i < 2; i++) {
        MixSendRequest invalid = sr;
        invalid.numSurbs = invalid_counts[i];
        Waiter bad; waiter_init(&bad);
        (void)libp2p_mix_rln_ctx_send_mix_message(A, &invalid, on_mix_send, &bad);
        if (waiter_wait(&bad, 10) || !bad.err_code) return 1;
    }
    MixSendRequest invalid_timeout = sr;
    invalid_timeout.timeoutMs = 0;
    Waiter bad_timeout; waiter_init(&bad_timeout);
    (void)libp2p_mix_rln_ctx_send_mix_message(A, &invalid_timeout, on_mix_send, &bad_timeout);
    if (waiter_wait(&bad_timeout, 10) || !bad_timeout.err_code) return 1;

    Waiter sw; waiter_init(&sw);
    (void)libp2p_mix_rln_ctx_send_mix_message(A, &sr, on_mix_send, &sw);
    // The receiver has not replied: the send callback must not wait for replies.
    if (waiter_wait(&sw, 10) || sw.err_code || !sw.reply_string[0]) {
        fprintf(stderr, "asynchronous send failed: %s\n", sw.err_msg); return 1;
    }
    if (wait_inbox(&inbox) || inbox.surbs_len == 0 || inbox.surbs[0] != 2 ||
        inbox.payload_len != strlen(kTestPayload) ||
        memcmp(inbox.payload, kTestPayload, inbox.payload_len)) return 1;

    MixSurbReplyRequest reply = {0};
    reply.surbs.data = inbox.surbs;
    reply.surbs.len = inbox.surbs_len;
    reply.payload.data = (uint8_t*)kReplyPayload;
    reply.payload.len = strlen(kReplyPayload);
    Waiter sent; waiter_init(&sent);
    (void)libp2p_mix_rln_ctx_send_mix_surb_reply(C, &reply, on_bool, &sent);
    if (waiter_wait(&sent, 15) || sent.err_code || wait_replies(&replies, 2)) return 1;
    if (strcmp(replies.ids[0], sw.reply_string) || strcmp(replies.ids[1], sw.reply_string)) {
        fprintf(stderr, "reply correlation failed\n"); return 1;
    }
    fprintf(stderr, "[smoke] PASS: send returns before replies; two correlated reply events\n");

    atomic_store(&inbox.fired, 0);
    MixSendRequest no_reply = sr;
    no_reply.numSurbs = 0;
    no_reply.timeoutMs = 0;
    Waiter fire; waiter_init(&fire);
    (void)libp2p_mix_rln_ctx_send_mix_message(A, &no_reply, on_mix_send, &fire);
    if (waiter_wait(&fire, 10) || fire.err_code || wait_inbox(&inbox) ||
        inbox.surbs_len != 0 || !strcmp(fire.reply_string, sw.reply_string)) return 1;
    fprintf(stderr, "[smoke] PASS: explicit zero-SURB send\n");

    // A late reply must not emit an event after its reader has timed out.
    atomic_store(&inbox.fired, 0);
    MixSendRequest expires = sr;
    expires.numSurbs = 1;
    expires.timeoutMs = 1;
    Waiter expired; waiter_init(&expired);
    (void)libp2p_mix_rln_ctx_send_mix_message(A, &expires, on_mix_send, &expired);
    if (waiter_wait(&expired, 10) || expired.err_code || wait_inbox(&inbox)) return 1;
    struct timespec delay = {0, 100000000};
    nanosleep(&delay, NULL);
    reply.surbs.len = inbox.surbs_len;
    Waiter late; waiter_init(&late);
    (void)libp2p_mix_rln_ctx_send_mix_surb_reply(C, &reply, on_bool, &late);
    if (waiter_wait(&late, 10) || late.err_code) return 1;
    delay.tv_nsec = 500000000;
    nanosleep(&delay, NULL);
    pthread_mutex_lock(&replies.m);
    int extra_replies = replies.count != 2;
    pthread_mutex_unlock(&replies.m);
    if (extra_replies) return 1;
    fprintf(stderr, "[smoke] PASS: late reply ignored after timeout\n");

    // Shutdown cancels an outstanding reader instead of waiting for its deadline.
    MixSendRequest pending = sr;
    pending.timeoutMs = 60000;
    Waiter outstanding; waiter_init(&outstanding);
    (void)libp2p_mix_rln_ctx_send_mix_message(A, &pending, on_mix_send, &outstanding);
    if (waiter_wait(&outstanding, 10) || outstanding.err_code) return 1;

    // Cleanup.
    for (int i = 0; i < N; i++)
        if (stop_node(nodes[i])) return 1;
    for (int i = 0; i < N; i++) libp2p_mix_rln_ctx_destroy(nodes[i]);
    for (int i = 0; i < N; i++) free_record(&recs[i]);
    if (atomic_load(&backend_errors) || !atomic_load(&proof_serial) ||
        !atomic_load(&verified_proofs)) return 1;
    return 0;
}
