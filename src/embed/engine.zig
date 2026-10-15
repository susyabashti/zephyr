//! The llama.cpp embedding engine (spec/semantic.md sections 2-4): the
//! core-side Engine vtable implemented over the pinned C binding
//! (llama.zig). The model is loaded once per process, hash-pinned on load,
//! and kept for the engine's lifetime; texts are framed (section 4),
//! tokenized, and decoded in batches of at most 16 sequences / 2048
//! tokens; the pool is the mean of the per-token embeddings, L2-normalized.
//!
//! This module lives in the CLI layer: core sees only the vtable, and the
//! test suite never links this file (it supplies a deterministic fake).

const std = @import("std");
const Io = std.Io;
const File = Io.File;
const embed = @import("zephyr_core").embed;
const llama = @import("llama.zig");
const model = @import("model.zig");

const Allocator = std.mem.Allocator;

// ------------------------------------------------------------------ config

/// Frozen batch configuration (spec/semantic.md section 4): any change
/// invalidates stored artifacts through the engine identity.
const MaxSequences: usize = 16;
const MaxTokens: usize = 2048; // n_ctx = n_batch

/// The engine identity string (spec/semantic.md section 4), after the
/// model hash: `llama.cpp-b11609|<backend>|<pooling>|prompt-v1`.
const EngineId = "llama.cpp-b11609";
const PoolingName = "mean"; // frozen after the section-8 A/B
const PromptVersion = "prompt-v1";

/// The frozen embedding input (spec/semantic.md section 4): the exact
/// framing each text gets before tokenization.
const DocumentPrefix = "title: none | text: ";
const QueryPrefix = "task: search result | query: ";

pub const CreateError = embed.EmbedError || File.OpenError || File.StatError || File.ReadPositionalError;

/// The engine's owned state. Freed by the vtable's `deinit`.
pub const Data = struct {
    model: *llama.LlamaModel,
    ctx: *llama.LlamaContext,
    vocab: *const llama.LlamaVocab,
    n_embd: u32,
    model_hash: [32]u8,
    backend: []const u8, // "metal" | "cpu"
    allocator: Allocator,
};

// ------------------------------------------------------------------ create

/// Loads the pinned model at `model_path` (resolved with
/// `model.resolveModelPath`) and returns a ready engine. The size and
/// sha256 gate runs before the library ever sees the file. The caller
/// owns the result and deinits it.
pub fn create(allocator: Allocator, io: Io, model_path: []const u8) CreateError!embed.Engine {
    const file = Io.Dir.openFileAbsolute(io, model_path, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => return error.ModelNotFound,
        else => return err,
    };
    defer File.close(file, io);
    const st = try file.stat(io);
    if (st.size != model.ModelBytes) return error.ModelMismatch;
    const hash = try hashFile(io, file);
    if (!std.mem.eql(u8, &hash, &model.ModelSha256)) return error.ModelMismatch;

    // The library's default logger dumps every INFO/DEBUG line to stderr
    // (several thousand per model load: tensor loads, Metal pipeline
    // compiles). Replace it: the CLI's output is the interface; only
    // WARN/ERROR/CONT pass through, and on stderr. The logger state is
    // global in the pinned build, so re-setting it is harmless.
    llama.llama_log_set(&llama.logCallback, null);

    // The pinned library guards this call internally (std::call_once); it
    // is safe to run on every engine creation.
    llama.llama_backend_init();

    // The C loader wants a NUL-terminated path.
    const cpath = try allocator.alloc(u8, model_path.len + 1);
    errdefer allocator.free(cpath);
    // The buffer is one byte longer than the path (for the NUL): copy the
    // exact prefix, then terminate.
    @memcpy(cpath[0..model_path.len], model_path);
    cpath[model_path.len] = 0;

    // The NUL is at cpath[len] (set above); the sentinel cast is where
    // that guarantee enters the C boundary.
    const cpath_c: [*:0]const u8 = @ptrCast(@constCast(cpath.ptr));
    var mp = llama.llama_model_default_params();
    // The library's built-in progress display (a line of dots per load)
    // is replaced with a silent no-op; the CLI reports its own progress.
    mp.progress_callback = &llama.progressContinue;
    const m = llama.llama_model_load_from_file(cpath_c, mp) orelse return error.ModelLoadFailed;
    errdefer llama.llama_model_free(m);

    var cp = llama.llama_context_default_params();
    cp.n_ctx = MaxTokens;
    cp.n_batch = MaxTokens;
    cp.n_seq_max = MaxSequences;
    cp.kv_unified = true;
    cp.embeddings = true;
    cp.pooling_type = llama.PoolingNone; // per-token embeddings; we pool
    const ctx = llama.llama_init_from_model(m, cp) orelse return error.ContextInitFailed;
    errdefer llama.llama_free(ctx);

    const n_embd: i32 = llama.llama_model_n_embd(m);
    if (n_embd <= 0) return error.ModelLoadFailed;

    const backend = try allocator.dupe(u8, if (llama.llama_supports_gpu_offload()) "metal" else "cpu");
    errdefer allocator.free(backend);

    const data = try allocator.create(Data);
    errdefer {
        llama.llama_free(ctx);
        llama.llama_model_free(m);
    }
    data.* = .{
        .model = m,
        .ctx = ctx,
        .vocab = llama.llama_model_get_vocab(m),
        .n_embd = @intCast(n_embd),
        .model_hash = hash,
        .backend = backend,
        .allocator = allocator,
    };
    return embed.Engine{ .vtable = &vtable, .data = data };
}

/// sha256 of the whole file in 1 MiB chunks (the pinned model is 313 MiB;
/// it is streamed, never slurped).
fn hashFile(io: Io, file: File) CreateError![32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [1 << 20]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const n = try file.readPositionalAll(io, &buf, offset);
        if (n == 0) break;
        hasher.update(buf[0..n]);
        offset += n;
    }
    return hasher.finalResult();
}

// ------------------------------------------------------------------ vtable

const vtable = embed.Engine.VTable{
    .embed = embedImpl,
    .identity = identityImpl,
    .modelHash = modelHashImpl,
    .dim = dimImpl,
    .deinit = deinitImpl,
};

fn dataOf(data: ?*anyopaque) *Data {
    const unaligned: *align(1) Data = @ptrCast(data.?);
    return @alignCast(unaligned);
}

fn embedImpl(
    data: ?*anyopaque,
    allocator: Allocator,
    texts: []const []const u8,
    kind: embed.Engine.Kind,
) embed.EmbedError![][]f32 {
    const d = dataOf(data);
    const prefix = if (kind == .document) DocumentPrefix else QueryPrefix;

    // Frame and tokenize everything up front: a text past the context is
    // refused before the engine is touched (the batch below then only ever
    // holds short sequences). `token_lists` holds the full allocations
    // (freeable); `lens` the actual token counts.
    var framed = std.ArrayList([]u8).empty;
    var token_lists = std.ArrayList([]llama.Token).empty;
    var lens = std.ArrayList(usize).empty;
    errdefer {
        for (framed.items) |f| allocator.free(f);
        allocator.free(framed.items);
        for (token_lists.items) |t| allocator.free(t);
        allocator.free(token_lists.items);
        allocator.free(lens.items);
    }
    for (texts) |text| {
        const len = text.len + prefix.len;
        // Worst case: one token per byte plus the leading special token;
        // both caps must fit the i32 C parameters.
        const cap = len + 2;
        if (cap > std.math.maxInt(i32)) return error.SequenceTooLong;
        const fbuf = try allocator.alloc(u8, len + 1);
        errdefer allocator.free(fbuf);
        // The buffer is one byte longer than the framed text (for the NUL):
        // copy exact-length prefixes, then terminate.
        @memcpy(fbuf[0..prefix.len], prefix);
        @memcpy(fbuf[prefix.len..len], text);
        fbuf[len] = 0; // the C tokenizer takes (text, text_len); the NUL
        try framed.append(allocator, fbuf); // matches the pinned example
        const toks = try allocator.alloc(llama.Token, cap);
        errdefer allocator.free(toks);
        // fbuf[len] is the NUL (set above).
        const ctext: [*:0]const u8 = @ptrCast(@constCast(fbuf.ptr));
        const n = llama.llama_tokenize(d.vocab, ctext, @intCast(len), toks.ptr, @intCast(cap), true, true);
        if (n < 0 or @as(usize, @intCast(n)) > MaxTokens) return error.SequenceTooLong;
        try token_lists.append(allocator, toks);
        try lens.append(allocator, @intCast(n));
    }
    if (texts.len == 0) return try allocator.alloc([]f32, 0);

    // Chunk into engine batches (section 4): at most 16 sequences and
    // 2048 tokens; the output order is the input order.
    var out = std.ArrayList([]f32).empty;
    errdefer {
        for (out.items) |v| allocator.free(v);
        allocator.free(out.items);
    }
    var t: usize = 0;
    while (t < texts.len) {
        var end = t;
        var batch_tokens: usize = 0;
        while (end < texts.len and end - t < MaxSequences) : (end += 1) {
            if (batch_tokens + lens.items[end] > MaxTokens) break;
            batch_tokens += lens.items[end];
        }
        if (end == t) end = t + 1; // a single text is at most MaxTokens
        try decodeBatch(d, allocator, &out, token_lists.items[t..end], lens.items[t..end]);
        t = end;
    }
    return out.toOwnedSlice(allocator);
}

/// Decodes one batch and appends one L2-normalized mean-pooled vector per
/// sequence to `out`.
fn decodeBatch(
    d: *const Data,
    allocator: Allocator,
    out: *std.ArrayList([]f32),
    seqs: []const []const llama.Token,
    lens: []const usize,
) embed.EmbedError!void {
    var total: usize = 0;
    for (lens) |l| total += l;
    // llama_batch_init only allocates the arrays and leaves n_tokens at
    // zero; the count is set here, once the arrays are filled.
    var batch = llama.llama_batch_init(@intCast(total), 0, 1);
    defer llama.llama_batch_free(batch);
    var i: usize = 0;
    for (seqs, lens, 0..) |buf, len, sid| {
        const s = buf[0..len];
        for (s, 0..) |tok, pos| {
            batch.token[i] = tok;
            batch.pos[i] = @intCast(pos);
            batch.n_seq_id[i] = 1;
            // Each text gets its own sequence id (the chunking above caps
            // a batch at MaxSequences, the context's n_seq_max): positions
            // restart at zero per sequence, so sharing one id would be a
            // decreasing-position error. llama_batch_init allocated a
            // one-element row per token; the row's only element is the
            // pointee.
            batch.seq_id[i].?.* = @intCast(sid);
            batch.logits[i] = 1; // every token yields an embedding
            i += 1;
        }
    }
    batch.n_tokens = @intCast(total);
    // Embeddings are per-input: clear the cache before each batch (the
    // pinned example's pattern).
    llama.llama_memory_clear(llama.llama_get_memory(d.ctx), true);
    if (llama.llama_decode(d.ctx, batch) != 0) return error.DecodeFailed;

    i = 0;
    for (seqs, lens) |buf, len| {
        const s = buf[0..len];
        var sum = try allocator.alloc(f64, d.n_embd);
        errdefer allocator.free(sum);
        @memset(sum, 0);
        for (s) |_| {
            const e = llama.llama_get_embeddings_ith(d.ctx, @intCast(i)) orelse {
                allocator.free(sum);
                return error.DecodeFailed;
            };
            var j: usize = 0;
            while (j < d.n_embd) : (j += 1) sum[j] += @as(f64, @floatCast(e[j]));
            i += 1;
        }
        const vec = try allocator.alloc(f32, d.n_embd);
        errdefer allocator.free(vec);
        var norm: f64 = 0;
        const inv: f64 = 1 / @as(f64, @floatFromInt(s.len));
        for (vec, sum) |*v, s2| {
            v.* = @as(f32, @floatCast(s2 * inv));
            norm += @as(f64, @floatCast(v.*)) * @as(f64, @floatCast(v.*));
        }
        const n = @sqrt(norm);
        if (std.math.isFinite(n) and n > 0) {
            const scale: f64 = 1 / n;
            for (vec) |*v| v.* = @as(f32, @floatCast(@as(f64, @floatCast(v.*)) * scale));
        }
        try out.append(allocator, vec);
        allocator.free(sum);
    }
}

/// sha256 of "<model sha256, lowercase hex> | <engine id string>"
/// (the core's identity contract).
fn identityImpl(data: ?*anyopaque) [32]u8 {
    const d = dataOf(data);
    const digits = "0123456789abcdef";
    var msg: [128]u8 = undefined;
    var o: usize = 0;
    for (d.model_hash) |b| {
        msg[o] = digits[b >> 4];
        msg[o + 1] = digits[b & 0x0F];
        o += 2;
    }
    o += copyStr(msg[o..], "|");
    o += copyStr(msg[o..], EngineId);
    o += copyStr(msg[o..], "|");
    o += copyStr(msg[o..], d.backend);
    o += copyStr(msg[o..], "|");
    o += copyStr(msg[o..], PoolingName);
    o += copyStr(msg[o..], "|");
    o += copyStr(msg[o..], PromptVersion);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(msg[0..o], &digest, .{});
    return digest;
}

fn copyStr(dst: []u8, s: []const u8) usize {
    const n = @min(dst.len, s.len);
    @memcpy(dst[0..n], s[0..n]);
    return n;
}

fn modelHashImpl(data: ?*anyopaque) [32]u8 {
    return dataOf(data).model_hash;
}

fn dimImpl(data: ?*anyopaque) u32 {
    return dataOf(data).n_embd;
}

fn deinitImpl(data: ?*anyopaque) void {
    const d = dataOf(data);
    llama.llama_free(d.ctx);
    llama.llama_model_free(d.model);
    d.allocator.free(d.backend);
    d.allocator.destroy(d);
}
