# Plan: Split File Mutation And Upload Dispatch Paths From `Drive`

## Summary

After the `DriveMutations`, `DriveViews`, and `DriveDirectoryReads`
extractions, the highest-value unextracted write-side logic in `src/drive.ml`
actually falls into two different seams, not one:

- local file mutation:
  - `write`
  - `truncate`
- upload dispatch:
  - `start_uploading_if_dirty`
  - `queue_upload`
  - `upload_with_retry`
  - the `upload_if_dirty` logic reached by `flush`, `fsync`, and `release`

Those two areas are related, but they are not the same responsibility.

`write` and `truncate` answer:

- how local content is materialized
- whether bytes go to memory buffers or the local cache file
- how cached size changes
- when a resource becomes `ToUpload`

Upload dispatch answers:

- whether a callback should launch upload work at all
- how repeated triggers are suppressed
- when `ToUpload` flips to `Uploading`
- whether to hand off to the async queue or upload directly

That split is a better match for the code that still remains in
`src/drive.ml`, and it is a better match for the tests we want to add.

The next refactor should therefore extract two dedicated modules, while keeping
`src/drive.ml` as the production adapter.

## Why This Should Be Two Modules, Not One

- file mutation and upload dispatch have different inputs and outputs:
  - file mutation starts from a path and a local write or size change
  - upload dispatch starts from dirty cached state and decides whether to hand
    work off
- file mutation owns `Synchronized -> ToUpload`
- upload dispatch owns the decision to begin `ToUpload -> Uploading`
- the current dispatch helpers already have another caller besides `flush` /
  `fsync` / `release`:
  - `DriveMutations.replace_target_contents` currently calls `queue_upload`
- tests for the two concerns are different:
  - file mutation tests want fake local files, buffer writes, and size deltas
  - dispatch tests want fake cached rows, event traces, and sync-vs-async
    handoff behavior

Trying to keep them together would recreate the same coarse boundary problem
the earlier extraction plans intentionally avoided.

## Why This Still Should Not Be A Single `DriveContentIO.Make(DEPS)`

- `read` is still a separate abstraction shape:
  - streaming versus local-file policy
  - read-ahead dispatch
  - buffer-eviction thread startup
- `download_resource` is shared by read, write, truncate, and rename-replace
  flows. Pulling it wholesale into this first split would force the new seam to
  absorb too much shared behavior at once.
- the concrete upload request path also has a separate shape:
  - MIME selection
  - media-source creation
  - remote `FilesResource.update`
  - post-upload cache reconciliation

So the first step is not "extract all remaining content I/O". The first step is
"separate local file mutation from upload dispatch", and keep shared
materialization plus concrete upload execution behind narrow semantic ports
unless later work proves they deserve their own modules.

## Scope Of This Refactor

Initial in scope:

- a file-mutation module for:
  - `write`
  - `truncate`
  - shared dirty-size update helpers used only by those paths
- an upload-dispatch module for:
  - `start_uploading_if_dirty`
  - `queue_upload`
  - `upload_with_retry`
  - the shared logic behind `flush`, `fsync`, and `release`
- adapting the existing rename-replace flow so the `DriveMutations` port
  implementation uses the extracted upload-dispatch helper instead of calling a
  still-local `queue_upload`

Potentially in scope if the boundary stays small:

- `upload_resource_with_retry`

Out of scope:

- `read`
- streaming and read-ahead helpers
- generic extraction of `download_resource`
- `init_filesystem` thread-start logic
- `upload_resource_by_id` worker wiring
- metadata-only remote mutations such as `chmod`, `chown`, `utime`, and xattrs
- create/delete/rename policy already handled by `DriveMutations`
- the concrete `upload` request path unless it falls out naturally as a very
  small follow-up

## Target Structure

Add two new library module pairs:

- `src/driveFileMutations.ml`
- `src/driveFileMutations.mli`
- `src/driveUploadDispatch.ml`
- `src/driveUploadDispatch.mli`

Keep `src/drive.ml` public and production-facing, but reduce the relevant
entrypoints to thin wrappers that:

1. read the real runtime state from `Context`
2. build a small runtime record
3. call the extracted module
4. execute returned `SessionM` work through `do_request`

The intended wrapper split is:

- `write` and `truncate` delegate to `DriveFileMutations`
- `flush`, `fsync`, and `release` delegate to `DriveUploadDispatch`
- the `DriveMutations.replace_target_contents` port implementation delegates to
  `DriveUploadDispatch.queue_upload`

`src/drive.ml` should continue to own thread startup and worker callbacks that
are mainly orchestration rather than path policy.

## Proposed `runtime` Shape

Start both modules with the same minimal runtime:

```ocaml
type runtime = {
  cache : CacheData.t;
  config : Config.t;
}
```

That should be enough if mutable process state continues to flow through
semantic ports rather than through direct `Context` reads inside the extracted
cores.

If implementation shows that one extra derived value is always needed, add it
explicitly. Do not pass the full `Context.t` through either boundary.

## Proposed `PORTS` Boundary For `DriveFileMutations`

Keep this interface focused on local file mutation only.

Path and resource resolution:

- `get_path_in_cache`
- `get_resource`

Local content preparation:

- `ensure_local_content`
- `flush_memory_buffers`

Local write sinks:

- `write_to_memory_buffers`
- `write_to_file`
- `truncate_local_file`
- `file_exists`

Cache updates and accounting:

- `update_cached_resource`
- `update_cached_resource_state`
- `shrink_cache`

Representative signature sketches:

```ocaml
val ensure_local_content :
  CacheData.Resource.t -> string GapiMonad.SessionM.m

val write_to_memory_buffers :
  CacheData.Resource.t ->
  string ->
  (char, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t ->
  int64 ->
  int

val write_to_file :
  string ->
  (char, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t ->
  int64 ->
  int

val truncate_local_file : string -> int64 -> unit
```

This module should not decide whether upload work starts. Its job ends once the
resource is locally mutated and marked `ToUpload`.

## Proposed `PORTS` Boundary For `DriveUploadDispatch`

Keep this interface focused on dirty-state gating and work handoff.

Cheap local gate:

- `get_path_in_cache`
- `lookup_resource`
- `update_cached_resource_state`

Request-side re-resolution:

- `get_resource`

Dispatch handoff:

- `flush_memory_buffers`
- `enqueue_async_upload`
- `upload_now_with_retry`

Representative signature sketches:

```ocaml
val lookup_resource :
  string -> bool -> CacheData.Resource.t option

val enqueue_async_upload :
  CacheData.t -> Config.t -> CacheData.Resource.t -> unit

val upload_now_with_retry :
  CacheData.Resource.t -> unit GapiMonad.SessionM.m
```

This module should own:

- repeated-callback suppression
- `ToUpload -> Uploading`
- sync-versus-async handoff

It should not own the local write or truncate logic that produces `ToUpload`.

## Implementation Changes

### 1. Extract `DriveUploadDispatch` First

Start with the dispatch seam because it already has two clients:

- file callbacks through `flush`, `fsync`, and `release`
- the rename-replace path through `DriveMutations.replace_target_contents`

Move the following policy into `DriveUploadDispatch.Make(P)`:

- `start_uploading_if_dirty`
- `queue_upload`
- `upload_with_retry`
- the shared `upload_if_dirty` behavior

Keep concrete upload execution behind a semantic port at first.

### 2. Wire Existing Clients To The Dispatch Module

After extraction:

- `Drive.flush`, `Drive.fsync`, and `Drive.release` should become thin wrappers
- the `replace_target_contents` port implementation used by `DriveMutations`
  should call the new dispatch helper instead of the old local `queue_upload`

That keeps the dispatch policy in one place instead of leaving a second hidden
caller behind in `src/drive.ml`.

### 3. Extract `DriveFileMutations`

Move the local-mutation logic for `write` and `truncate` into
`DriveFileMutations.Make(P)`.

The first pass should move behavior, not redesign it:

- resolve path and resource
- ensure a usable local content path exists
- choose the write sink
- update size and cache accounting
- mark the resource `ToUpload`

The module should stop there. It should not call into upload dispatch directly.

### 4. Keep Shared Materialization And Concrete Upload Behind Ports First

Do not force `download_resource` or the concrete `upload` implementation into
either extracted module unless the dependency surface remains clearly small.

Instead, prefer semantic ports such as:

- `ensure_local_content`
- `upload_now_with_retry`

This keeps the first split narrow while still allowing tests to fake:

- successful local materialization
- missing local files
- direct upload completion
- async queue handoff
- upload failures

### 5. Split Internal State Transitions Into Named Helpers

Inside the extracted modules, do not keep the current long top-level functions
as single blocks.

Inside `DriveFileMutations`, split helpers such as:

- perform local write
- update cached size after a growing write
- mark overwrite-in-place writes dirty without changing size
- compute signed truncate delta
- flush buffers before truncate

Inside `DriveUploadDispatch`, split helpers such as:

- check whether upload should start
- switch `ToUpload -> Uploading`
- resolve the current resource for dispatch
- choose async queue versus direct upload

This split matters because correctness here depends heavily on effect ordering.

## Behavioral Constraints

- Preserve all current public `Drive` signatures.
- Preserve current FUSE-visible behavior and exception mapping.
- Preserve the existing access model where write-capable opens are validated in
  `fopen`; do not add a new independent permission policy to `write`.
- Preserve the `write_buffers` branch behavior:
  - buffered writes go to `Buffering.MemoryBuffers`
  - direct writes go to the cache file
- Preserve the file-mutation boundary:
  - `write` and `truncate` stop after local mutation and `ToUpload`
  - they do not schedule upload themselves
- Preserve the dispatch boundary:
  - `flush`, `fsync`, and `release` remain equivalent trigger callbacks
  - repeated triggers do not all launch uploads
- Preserve the current dirty-state progression:
  - `Synchronized -> ToUpload -> Uploading -> Synchronized`
- Preserve current cache-size accounting rules:
  - `write` only grows tracked size when the write extends the file
  - `truncate` uses a signed delta and can grow or shrink usage
- Preserve the current ordering where `truncate` flushes memory buffers before
  local size mutation.
- Preserve the defensive missing-file branch after materialization in
  `truncate`.
- Do not change async upload queue startup or background worker behavior as
  part of this plan.

## Test Strategy

Add two new test modules:

- `test/testDriveFileMutations.ml`
- `test/testDriveUploadDispatch.ml`

Register both from `test/testSuite.ml`.

Build tests around `DriveFileMutations.Make(FakePorts)` and
`DriveUploadDispatch.Make(FakePorts)`.

`DriveFileMutations` tests should use fakes that:

- store synthetic `CacheData.Resource.t` values in memory
- record an ordered event trace
- model a small local file map without touching the real filesystem
- fake memory-buffer writes and flushes

`DriveUploadDispatch` tests should use fakes that:

- expose both `lookup_resource` and `get_resource`
- record cached state transitions
- fake async queue insertion and direct upload handoff
- avoid real `Context`, network, and background threads

Prefer using real `CacheData.Resource.t` values instead of mocking the record
shape.

## First Test Cases

`DriveFileMutations.write`:

- direct-file mode uses the file sink when `write_buffers = false`
- buffered mode uses the memory-buffer sink when `write_buffers = true`
- a write that extends the file:
  - updates `size`
  - marks the resource `ToUpload`
  - reports a positive cache delta
- an overwrite within the existing size only updates state to `ToUpload`

`DriveFileMutations.truncate`:

- flushes memory buffers before local truncation
- growing truncate updates cached size and reports a positive cache delta
- shrinking truncate updates cached size and reports a negative cache delta
- missing local file after materialization skips the local truncate call but
  still leaves the resource dirty

`DriveUploadDispatch`:

- `start_uploading_if_dirty` flips `ToUpload -> Uploading` exactly once
- already `Uploading` or `Synchronized` resources do not start a new upload
- `upload_if_dirty` uses the cheap lookup gate before request-side work
- `upload_with_retry` re-resolves the current resource before dispatch
- `queue_upload` in async mode hands work to the queue path
- `queue_upload` in direct mode calls the direct upload port

If `upload_resource_with_retry` lands inside `DriveUploadDispatch`, also cover:

- buffer flush happens before the direct upload attempt
- temporary upload failures are retried through the injected retry boundary

## Implementation Order

1. Add `driveUploadDispatch.ml` / `.mli` with a minimal `runtime` and `PORTS`.
2. Move dispatch helpers first:
   - `start_uploading_if_dirty`
   - `queue_upload`
   - `upload_with_retry`
   - shared `upload_if_dirty`
3. Update `flush`, `fsync`, `release`, and the `DriveMutations`
   `replace_target_contents` port implementation to use the new dispatch module.
4. Add `driveFileMutations.ml` / `.mli` and move `write` and `truncate`.
5. Add `test/testDriveUploadDispatch.ml` and
   `test/testDriveFileMutations.ml`.
6. Reassess after landing whether `download_resource` or the concrete upload
   request path should move into a separate follow-up module or stay as shared
   ports.

## Follow-Up Work, But Not In This Plan

- evaluate whether the concrete `upload` implementation deserves its own small
  extraction after the dispatch seam proves useful
- decide whether `download_resource` should later move into a shared
  materialization module used by read, write, truncate, and rename-replace
  flows
- reassess read-side streaming and read-ahead testability independently of this
  write-side split
- update `docs/agent-docs/architecture.md` and the write/upload-specific agent
  docs after implementation lands

## Assumptions

- OUnit remains the unit-test framework.
- The initial goal is unit-testability of write-side policy and ordering, not
  full integration testing of the real filesystem, FUSE, or Google Drive.
- Small functors around the extracted file-mutation and upload-dispatch cores
  are acceptable.
- A coarse functor around the whole remaining `Drive` module is not.
