//! Hand-written extern surface for the llama.cpp C API, verified against
//! the pinned submodule's `include/llama.h` (llama.cpp b11609, commit
//! fcac190). Only the functions and types the embedding engine needs are
//! bound; everything else is out of scope (spec/semantic.md section 2).
//!
//! C enums are i32 fields by layout; the named values are provided as
//! constants next to each struct. C string parameters are
//! NUL-terminated pointers; the caller owns the buffers.

const std = @import("std");

/// Opaque C structs.
pub const LlamaModel = extern struct {};
pub const LlamaContext = extern struct {};
pub const LlamaVocab = extern struct {};
pub const LlamaMemory = extern struct {};

// b11609 typedefs: all three are int32_t.
pub const Token = i32;
pub const Pos = i32;
pub const SeqId = i32;

/// The pinned build's `enum ggml_log_level` (ggml/include/ggml.h L652).
pub const LogLevel = struct {
    pub const NONE: u32 = 0;
    pub const DEBUG: u32 = 1;
    pub const INFO: u32 = 2;
    pub const WARN: u32 = 3;
    pub const ERROR: u32 = 4;
    pub const CONT: u32 = 5; // continuation of the previous log line
};

pub const PoolingNone: i32 = 0; // LLAMA_POOLING_TYPE_NONE
pub const AttentionCausal: i32 = 0; // LLAMA_ATTENTION_TYPE_CAUSAL
pub const FlashAttnAuto: i32 = -1; // LLAMA_FLASH_ATTN_TYPE_AUTO
pub const RopeScalingUnspecified: i32 = -1;
pub const LoadModeAuto: i32 = -1; // LLAMA_LOAD_MODE_AUTO

/// `struct llama_batch`: input for llama_decode. Each of the pointer
/// arrays has `n_tokens` elements; `seq_id[i]` points at an array of
/// `n_seq_id[i]` sequence ids (the engine uses exactly one per token).
/// `llama_batch_init` allocates every array (n_seq_max elements per
/// seq_id row); the caller fills the values. Many pointers mirror the
/// C array parameters (Zig refuses many-to-single casts).
pub const Batch = extern struct {
    n_tokens: i32,
    token: [*]Token,
    embd: [*]f32,
    pos: [*]Pos,
    n_seq_id: [*]i32,
    seq_id: [*]?*SeqId,
    logits: [*]i8,
};

/// `struct llama_model_params`. Only the fields the engine sets matter;
/// the rest come from `llama_model_default_params()`.
pub const ModelParams = extern struct {
    devices: ?*anyopaque, // ggml_backend_dev_t *
    tensor_buft_overrides: ?*const anyopaque,
    n_gpu_layers: i32,
    split_mode: i32,
    load_mode: i32,
    lazy_mode: i32,
    main_gpu: i32,
    tensor_split: ?*const f32,
    progress_callback: ?*const fn (f32, ?*anyopaque) callconv(.c) bool,
    progress_callback_user_data: ?*anyopaque,
    kv_overrides: ?*const anyopaque,
    vocab_only: bool,
    check_tensors: bool,
    use_extra_bufts: bool,
    no_host: bool,
    no_alloc: bool,
    load_mtp: bool,
};

/// `struct llama_context_params`.
pub const ContextParams = extern struct {
    n_ctx: u32,
    n_batch: u32,
    n_ubatch: u32,
    n_seq_max: u32,
    n_rs_seq: u32,
    n_outputs_max: u32,
    n_outputs_max_per_seq: u32,
    n_threads: i32,
    n_threads_batch: i32,
    ctx_type: i32,
    rope_scaling_type: i32,
    pooling_type: i32,
    attention_type: i32,
    flash_attn_type: i32,
    rope_freq_base: f32,
    rope_freq_scale: f32,
    yarn_ext_factor: f32,
    yarn_attn_factor: f32,
    yarn_beta_fast: f32,
    yarn_beta_slow: f32,
    yarn_orig_ctx: u32,
    defrag_thold: f32,
    cb_eval: ?*const fn (*const anyopaque, bool, ?*anyopaque) bool, // ggml_backend_sched_eval_callback
    cb_eval_user_data: ?*anyopaque,
    type_k: i32, // enum ggml_type
    type_v: i32, // enum ggml_type
    moe_cache_size: usize,
    abort_callback: ?*const fn (?*anyopaque) bool, // ggml_abort_callback
    abort_callback_data: ?*anyopaque,
    embeddings: bool,
    offload_kqv: bool,
    no_perf: bool,
    op_offload: bool,
    swa_full: bool,
    kv_unified: bool,
    samplers: ?*const anyopaque, // struct llama_sampler_seq_config *
    n_samplers: usize,
    ctx_other: ?*LlamaContext,
};

/// Emission policy: the CLI's own output is the interface, so the
/// library's INFO/DEBUG chatter (several thousand lines per model load)
/// is dropped; WARN and above go to stderr, where they cannot mix with a
/// command's stdout. CONT is a continuation of the previous message and
/// goes with it. Levels the pinned build does not define fail open.
pub fn logShouldEmit(level: u32) bool {
    return level >= LogLevel.WARN;
}

/// C callback installed with `llama_log_set` (mirrors b11609's
/// `ggml_log_callback`). It reads no state; the logger is global in the
/// pinned build, so re-installing it is harmless. `std.debug.print`
/// writes to stderr and swallows write failures, which is all the C ABI
/// allows a log callback to do.
pub fn logCallback(level: u32, text: [*:0]const u8, user_data: ?*anyopaque) callconv(.c) void {
    _ = user_data;
    if (logShouldEmit(level)) std.debug.print("{s}", .{text});
}

/// C callback for `ModelParams.progress_callback`. The library's built-in
/// default (installed when the field is NULL) prints a line of dots to
/// stderr while the model loads; this one says nothing and always
/// continues (returning false would cancel the load).
pub fn progressContinue(rate: f32, user_data: ?*anyopaque) callconv(.c) bool {
    _ = rate;
    _ = user_data;
    return true;
}

/// Replaces the library's default logger (everything on stderr).
pub extern fn llama_log_set(
    log_callback: *const fn (u32, [*:0]const u8, ?*anyopaque) callconv(.c) void,
    user_data: ?*anyopaque,
) void;
pub extern fn llama_backend_init() void;
pub extern fn llama_model_default_params() ModelParams;
pub extern fn llama_context_default_params() ContextParams;
/// NULL on failure (the file is missing, truncated, or not a valid model).
pub extern fn llama_model_load_from_file(path: [*:0]const u8, params: ModelParams) ?*LlamaModel;
pub extern fn llama_model_free(model: ?*LlamaModel) void;
pub extern fn llama_model_get_vocab(model: *const LlamaModel) *const LlamaVocab;
pub extern fn llama_model_n_embd(model: *const LlamaModel) i32;
/// NULL on failure.
pub extern fn llama_init_from_model(model: *LlamaModel, params: ContextParams) ?*LlamaContext;
pub extern fn llama_free(ctx: ?*LlamaContext) void;
pub extern fn llama_n_ctx(ctx: *const LlamaContext) u32;
pub extern fn llama_n_batch(ctx: *const LlamaContext) u32;
pub extern fn llama_supports_gpu_offload() bool;
pub extern fn llama_get_memory(ctx: *const LlamaContext) *LlamaMemory;
pub extern fn llama_memory_clear(mem: *LlamaMemory, data: bool) void;
/// Returns the token count on success, a negative count on failure, or
/// INT32_MIN on overflow.
pub extern fn llama_tokenize(
    vocab: *const LlamaVocab,
    text: [*:0]const u8,
    text_len: i32,
    tokens: [*]Token,
    n_tokens_max: i32,
    add_special: bool,
    parse_special: bool,
) i32;
/// The batch has to be released with llama_batch_free.
pub extern fn llama_batch_init(n_tokens: i32, embd: i32, n_seq_max: i32) Batch;
pub extern fn llama_batch_free(batch: Batch) void;
/// 0 on success; 1: no KV slot for the batch; -1: invalid input batch.
pub extern fn llama_decode(ctx: *LlamaContext, batch: Batch) i32;
/// The embeddings for the ith token of the last decode, or NULL.
/// The many pointer is a faithful binding of C's `float *` and is
/// indexable (single-pointer indexing does not exist in Zig 0.17).
pub extern fn llama_get_embeddings_ith(ctx: *const LlamaContext, i: i32) ?[*]f32;

test "binding: struct layouts match the C ABI" {
    // Cross-checked against the pinned header with a clang probe that
    // prints sizeof/offsetof of the C structs (spec/semantic.md section 2:
    // the surface is verified against the pinned header).
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(Batch));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(Batch, "logits"));
    try std.testing.expectEqual(@as(usize, 80), @sizeOf(ModelParams));
    try std.testing.expectEqual(@as(usize, 168), @sizeOf(ContextParams));
    try std.testing.expectEqual(@as(usize, 144), @offsetOf(ContextParams, "samplers"));
    try std.testing.expectEqual(@as(usize, 152), @offsetOf(ContextParams, "n_samplers"));
    try std.testing.expectEqual(@as(usize, 160), @offsetOf(ContextParams, "ctx_other"));
}

test "log policy: INFO and below are dropped, WARN and above pass" {
    try std.testing.expect(!logShouldEmit(LogLevel.NONE));
    try std.testing.expect(!logShouldEmit(LogLevel.DEBUG));
    try std.testing.expect(!logShouldEmit(LogLevel.INFO));
    try std.testing.expect(logShouldEmit(LogLevel.WARN));
    try std.testing.expect(logShouldEmit(LogLevel.ERROR));
    try std.testing.expect(logShouldEmit(LogLevel.CONT));
    try std.testing.expect(logShouldEmit(LogLevel.CONT + 1));
}

test "silent progress callback: always continues" {
    try std.testing.expect(progressContinue(0.0, null));
    try std.testing.expect(progressContinue(0.5, null));
    try std.testing.expect(progressContinue(1.0, null));
}
