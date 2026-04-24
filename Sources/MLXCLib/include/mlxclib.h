// Sources/MLXCLib/include/mlxclib.h
// Stable C ABI contract between the Zig TUI host and the Swift (MLX) inference engine.
//
// Ownership rules
//   • Zig NEVER frees Swift-allocated memory.
//   • Swift NEVER retains Zig-allocated memory.
//   • Strings passed INTO Swift (model_path, prompt, …) are copied by Swift before
//     the call returns, so callers may free them immediately after.
//   • Strings passed OUT to callbacks (error_msg, token bytes) are valid only for
//     the duration of the callback invocation — do not store the pointer.
//
// Threading
//   • mlxclib_session_create / mlxclib_session_destroy must be called from the same
//     thread, and no other operation on the session may be in flight during destroy.
//   • All other functions are safe to call from any thread.
//   • Callbacks may be invoked from a Swift background thread; callers must be
//     thread-safe (e.g. push tokens into a lock-protected queue).

#ifndef MLXCLIB_H
#define MLXCLIB_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------
// Opaque session handle
// ---------------------------------------------------------------------------

/// Opaque handle to one inference session.  Treat as a black box.
typedef void *MLXCSession;

// ---------------------------------------------------------------------------
// Callback types
// ---------------------------------------------------------------------------

/// Invoked once per decoded token fragment during streaming generation.
///
/// @param token     Pointer to the UTF-8 bytes of this fragment.
///                  NOT null-terminated — use `len` for the byte count.
/// @param len       Number of bytes in `token`.
/// @param user_data Opaque pointer forwarded unchanged from mlxclib_generate().
typedef void (*MLXCTokenCallback)(
    const char *token,
    size_t      len,
    void       *user_data
);

/// Invoked exactly once when a generation request finishes (success, cancel, or error).
///
/// @param error_msg NULL on success/cancellation; otherwise a null-terminated
///                  UTF-8 error description (valid only during this callback).
/// @param user_data Opaque pointer forwarded unchanged from mlxclib_generate().
typedef void (*MLXCDoneCallback)(
    const char *error_msg,
    void       *user_data
);

/// Invoked once when an asynchronous model-load request finishes.
///
/// @param success   true on success.
/// @param error_msg NULL on success; otherwise a null-terminated UTF-8 error
///                  description (valid only during this callback).
/// @param user_data Opaque pointer forwarded unchanged from mlxclib_load_model().
typedef void (*MLXCLoadCallback)(
    bool        success,
    const char *error_msg,
    void       *user_data
);

/// Invoked when the inference engine requires interactive tool approval.
///
/// The Zig TUI must display the approval modal and call mlxclib_approval_respond()
/// exactly once in response; the inference task blocks until it does.
///
/// @param tool_name  Null-terminated UTF-8 tool name.
/// @param args_json  Null-terminated UTF-8 JSON arguments, or NULL if not available.
/// @param user_data  Opaque pointer set via mlxclib_set_approval_handler().
typedef void (*MLXCApprovalCallback)(
    const char *tool_name,
    const char *args_json,
    void       *user_data
);

// ---------------------------------------------------------------------------
// Observability snapshot
// ---------------------------------------------------------------------------

/// Point-in-time performance snapshot.  All fields are best-effort estimates;
/// they are 0 / false until at least one generation has completed.
typedef struct {
    double   token_latency_ms;  ///< Average per-token latency (ms) over the last run.
    double   tokens_per_sec;    ///< Throughput (tokens/s) of the last run.
    uint64_t tokens_generated;  ///< Cumulative token count since session creation.
    int32_t  model_loaded;      ///< 1 if a model is currently loaded, 0 otherwise.
    int32_t  _pad;              ///< Reserved; always 0.
} MLXCStats;

// ---------------------------------------------------------------------------
// Session lifecycle
// ---------------------------------------------------------------------------

/// Allocate and return a new, empty inference session.
/// Returns NULL only on allocation failure (extremely unlikely).
MLXCSession mlxclib_session_create(void);

/// Release all resources associated with `session`.
/// No other operation on this session may be in flight when this is called.
void mlxclib_session_destroy(MLXCSession session);

// ---------------------------------------------------------------------------
// Model management
// ---------------------------------------------------------------------------

/// Begin loading a model from `model_path` on a background thread.
///
/// `model_path` may be:
///   • An absolute or ~/…-relative filesystem path to a model directory.
///   • A Hugging Face Hub ID (e.g. "Qwen/Qwen3-4B-4bit").
///
/// `callback` is invoked exactly once when loading completes (or fails).
/// The session is ready for generation as soon as callback reports success.
void mlxclib_load_model(
    MLXCSession      session,
    const char      *model_path,
    MLXCLoadCallback callback,
    void            *user_data
);

// ---------------------------------------------------------------------------
// Token generation
// ---------------------------------------------------------------------------

/// Begin a streaming generation request on a background thread.
///
/// `token_cb` is called once per decoded text fragment (may be NULL if the
/// caller only cares about the done signal).
/// `done_cb`  is called exactly once when generation ends.
///
/// Both callbacks are invoked from a Swift-managed background thread.
/// Zig must push incoming data into a thread-safe queue (see queue.zig).
void mlxclib_generate(
    MLXCSession       session,
    const char       *prompt,
    MLXCTokenCallback token_cb,
    MLXCDoneCallback  done_cb,
    void             *user_data
);

/// Request cancellation of the in-progress generation.
/// Returns immediately; `done_cb` is still fired (with error_msg == NULL).
void mlxclib_cancel(MLXCSession session);

// ---------------------------------------------------------------------------
// Tool-approval flow
// ---------------------------------------------------------------------------

/// Register a callback that the engine calls when it wants to execute a tool.
///
/// Pass NULL for `callback` to clear the handler.
/// The handler MUST eventually call mlxclib_approval_respond(); the generation
/// task blocks until it does, so deadlocks arise if the response is never sent.
void mlxclib_set_approval_handler(
    MLXCSession          session,
    MLXCApprovalCallback callback,
    void                *user_data
);

/// Respond to a pending tool-approval request.
///
/// @param approved    true to permit tool execution; false to deny.
/// @param suggestion  Optional null-terminated UTF-8 feedback string (may be NULL).
void mlxclib_approval_respond(
    MLXCSession  session,
    bool         approved,
    const char  *suggestion
);

// ---------------------------------------------------------------------------
// Observability
// ---------------------------------------------------------------------------

/// Fill `*out_stats` with the current performance snapshot for `session`.
/// `out_stats` must not be NULL.
void mlxclib_get_stats(
    MLXCSession session,
    MLXCStats  *out_stats
);

#ifdef __cplusplus
}
#endif

#endif /* MLXCLIB_H */
