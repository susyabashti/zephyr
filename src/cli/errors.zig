//! The CLI layer's error set (re-exported by cli.zig as cli.RunError):
//! the union of every command's failures, so main.zig can map one returned
//! error to the documented exit codes (0 ok, 1 integrity or runtime fault,
//! 2 usage or configuration).

const std = @import("std");
const core = @import("zephyr_core");
const key = @import("zephyr_key");
const mcp = @import("zephyr_mcp");
const embed_mod = @import("zephyr_embed");

const File = std.Io.File;

pub const RunError = error{
    Usage,
    VerifyFailed,
    JournalNotFound,
    TargetNotFound,
    TargetNotEntry,
    BadKeyFile,
    // The encryption surface (spec/encryption.md): the key pinned by the
    // journal's meta file is gone, the keychain is locked or unavailable,
    // or the key bytes no longer look like a key.
    KeyNotFound,
    KeychainUnavailable,
    KeyCorrupt,
    // Segments without a meta file: a v1 journal — a discontinued, unencrypted
    // format (spec/encryption.md section 4). It is neither read nor migrated.
    UnsupportedJournal,
    BadOtsProof,
    SegmentNotSealed,
    // The embedding surface (spec/semantic.md sections 5, 7): the artifact
    // is missing or stale, or the model cannot be resolved.
    EmbeddingsUnavailable,
    // The editor surface (cli/editor.zig): the temp-file path does not fit
    // the buffer. The editor's exit status is not an error (it cancels).
    TmpPathTooLong,
} || core.anchor.SignError || core.journal.OpenError || core.journal.Journal.AppendError ||
    core.journal.Journal.VerifyError || core.journal.Journal.RedactError ||
    core.journal.Journal.CheckAnchorsError || core.journal.Journal.WriteAnchorError ||
    core.journal.Journal.CheckOtsAnchorsError || core.journal.Journal.OtsCheckFailure ||
    core.vault.MetaError ||
    key.resolve.CreateError || key.resolve.LoadError ||
    core.ots.VerifyError ||
    core.view.RenderError || core.dstore.PackError || core.dstore.StatusError ||
    core.dstore.RebuildError || core.dstore.LoadEmbedError || File.OpenError || File.Writer.Error ||
    std.Io.Reader.ShortError || std.crypto.errors.IdentityElementError || std.process.CurrentPathError ||
    mcp.server.RunError || embed_mod.CreateError || // Phase 8: the embedding surface (rank, ask hybrid, derived rebuild --embeddings)
    embed_mod.FetchError || // distribution: model fetch (download, verify, install)
    std.process.CurrentPathAllocError || // model fetch: a relative $ZEPHYR_EMBED_MODEL is resolved against the cwd
    std.process.SpawnError || // editor: $VISUAL/$EDITOR could not be spawned
    std.Io.Dir.DeleteFileError; // editor: a stale temp file from a crashed run cannot be removed
