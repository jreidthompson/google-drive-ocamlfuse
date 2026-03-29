# Plan: Make `Drive` Mutation Paths Unit-Testable

## Summary

Refactor the high-risk mutating portion of `Drive` so it can be unit tested from
`test/` without invoking real Google Drive API calls, background threads, cache
DB writes, or local filesystem mutations.

Use the same dependency-injection idea that worked for `GdfuseFlow`, but do not
apply it as a coarse functor around the whole public `Drive` module. Instead,
extract a smaller mutation-focused core behind a narrow semantic boundary and
keep `src/drive.ml` as the production adapter.

The first extraction should cover:

- creation paths
- delete / trash paths
- rename / replace paths

These are the most policy-heavy parts of `Drive`, and they are where unit tests
would provide the highest value per line of refactoring.

## Why This Should Not Be A Whole-Module `Drive.Make(DEPS)`

- `GdfuseFlow` is mostly orchestration with a small external boundary; a coarse
  functor fits that shape well.
- `Drive` currently exposes a very large API and mixes several concerns in one
  module:
  - policy decisions
  - `Context` access
  - cache / database mutations
  - Google Drive API requests
  - local filesystem work
  - background-thread startup
- A whole-module `Drive.Make(DEPS)` would create a very large `DEPS` signature,
  force tests to fake too much at once, and make the first refactor more
  disruptive than necessary.
- A smaller seam around the mutation path keeps the blast radius manageable and
  lets the repository gain tests incrementally.

## Scope Of The First Refactor

In scope:

- shared mutation helper:
  - `update_remote_resource`
- create path:
  - `create_remote_resource`
  - `mknod`
  - `mkdir`
  - `symlink`
- delete path:
  - `check_if_empty`
  - `trash_resource`
  - `delete_resource`
  - `delete_remote_resource`
  - `unlink`
  - `rmdir`
- rename path:
  - `rename`

Out of scope:

- `read`, `write`, `truncate`, upload/download streaming
- `get_attr`, `read_dir`, `fopen`, `opendir`
- metadata refresh and change polling
- background services started by `init_filesystem`

## Target Structure

Add a new library module pair:

- `src/driveMutations.ml`
- `src/driveMutations.mli`

Keep `src/drive.ml` public and production-facing, but reduce its mutation
entrypoints to thin wrappers that:

1. read the real runtime state from `Context`
2. build a small runtime record
3. call the extracted mutation core
4. execute the returned `SessionM` request through `do_request`

`src/driveMutations.mli` should define:

- a small `runtime` record containing only the values the mutation path needs
  from the current process state
- a small `module type PORTS`
- `module Make (P : PORTS) : sig ... end`

The functor lives around the extracted mutation core only, not around the whole
`Drive` module.

## Proposed `runtime` Shape

The mutation core should not call `Context.get_ctx ()` directly. Instead, build
an explicit runtime record once in `Drive` and pass it to the core.

Start with a minimal shape such as:

```ocaml
type runtime = {
  cache : CacheData.t;
  config : Config.t;
  mountpoint_path : string;
  skip_trash : bool;
}
```

If the rename path still needs more data after extraction, add fields only when
they are truly runtime state and not better expressed as callbacks.

## Proposed `PORTS` Boundary

Keep the dependency boundary semantic and narrow. Organize it around a few
groups of operations rather than mirroring every concrete module.

`PORTS` should own only the unstable side effects used by the mutation path:

- resource lookup / path resolution
- remote Drive create / update / delete / child existence checks
- cache insert / update / delete / invalidate operations
- local file operations needed by rename-replace flows
- upload queue handoff and memory-buffer flushing
- read-only guards

Representative operations:

- `get_path_in_cache`
- `get_resource`
- `build_resource_keys_header_from_resource`
- `insert_resource_into_cache`
- `update_cached_resource`
- `update_cached_resource_state`
- `delete_cached_resource`
- `check_if_empty_remote`
- `remote_create`
- `remote_update`
- `remote_delete`
- `get_content_path`
- `file_exists`
- `copy_file`
- `queue_upload`
- `flush_memory_buffers`
- `is_filesystem_read_only`

The exact signature can change during implementation, but the goal is to keep
the interface semantic and substantially smaller than the current public
surface of `Drive`.

## Implementation Changes

### 1. Extract A Mutation Core

Move the policy and effect ordering for mutation paths out of `src/drive.ml`
into `DriveMutations.Make(P)`.

The first extraction should move these behaviors with minimal logic changes:

- create a file, folder, symlink, or shortcut
- decide between trash and permanent delete
- enforce empty-directory checks
- rename within a directory
- move across directories
- replace an existing target when duplicate policy allows it

Keep the new core monadic where that reduces churn. It is acceptable for the
core functions to return `GapiMonad.SessionM.m` values and let `Drive` remain
the place that calls `do_request`.

### 2. Keep `Drive` As A Thin Adapter

After extraction, `src/drive.ml` should still export the current public
functions, but the mutation-facing entrypoints should become small wrappers:

- `mknod`
- `mkdir`
- `symlink`
- `unlink`
- `rmdir`
- `rename`

Those wrappers should:

- build `runtime` from the real `Context`
- delegate to `DriveMutations`
- preserve current exceptions and outward behavior

`init_filesystem`, streaming logic, metadata refresh, and read paths should stay
where they are for now.

### 3. Reuse Existing Internal Seams

`update_remote_resource` is already close to the right abstraction shape. Use it
as the starting point for the extraction rather than inventing a second update
framework.

The likely path is:

1. move `update_remote_resource` into `DriveMutations`
2. update create/delete/rename helpers to use the moved version
3. keep `Drive` wrappers very small

### 4. Split `rename` Internals Into Named Helpers

`rename` is the hardest part of this slice. Do not move it as one large block
and stop there. Inside `DriveMutations`, split it into named helpers so tests
can target distinct branches:

- validate source/target domain constraints
- delete or trash target path when needed
- rename in place
- move across parents
- replace target contents when `mv_keep_target` is enabled
- persist the final cache state

This split is important because `rename` currently mixes policy and side
effects more heavily than the other mutation paths.

## Behavioral Constraints

- Preserve all current public `Drive` signatures.
- Preserve current FUSE-visible behavior and current exception mapping.
- Preserve the existing decisions around:
  - refusing writes in read-only mode
  - refusing create/delete operations in protected virtual locations
  - trash vs permanent delete
  - symlink vs Drive shortcut creation
  - duplicate-target handling during rename
- Preserve the current cache-state transitions, especially for rename-replace
  and queued uploads.
- Do not move background-thread startup or read-path behavior into this first
  refactor.

## Test Strategy

Add a new test module:

- `test/testDriveMutations.ml`

Register it from `test/testSuite.ml`.

Build tests around `DriveMutations.Make(FakePorts)`, where `FakePorts`:

- records an ordered event trace
- stores synthetic resources in memory
- returns fake `SessionM` values for remote operations
- avoids touching the real `Context`, cache DB, local files, or network

Prefer using real `CacheData.Resource.t` values in memory rather than mocking
the record shape.

## First Test Cases

Creation:

- creating a regular file under a normal parent creates the expected remote
  request and cache insert
- creating in trash is denied
- creating under `lost+found` is denied
- symlink creation chooses:
  - Drive shortcut for relative targets
  - Drive shortcut for absolute targets inside the mountpoint
  - stored symlink for targets outside the mountpoint
- oversized stored-link targets raise `Invalid_operation`

Delete:

- deleting a normal file chooses trash by default
- deleting from the trash folder can switch to permanent delete when configured
- `skip_trash` forces permanent delete
- deleting a non-empty folder raises `Directory_not_empty`
- deleting under protected virtual paths is denied

Rename:

- rename within the same parent updates only the name
- move across parents updates parent metadata
- moving across trash boundary is denied
- rename with duplicate target and `keep_duplicates = false` removes or trashes
  the target first
- rename with `mv_keep_target = true` uses replace-target flow
- folder rename clears stale cached descendants
- same-name move recomputes the visible path when filename disambiguation
  requires it

## Implementation Order

1. Add `driveMutations.ml` / `.mli` with a minimal `runtime`, `PORTS`, and
   `update_remote_resource`.
2. Move create and delete paths first. They have smaller state graphs and will
   stabilize the injected interface.
3. Move `rename` last within the same refactor, after the create/delete ports
   are proven out.
4. Add `test/testDriveMutations.ml` and cover the main policy branches before
   cleaning up the remaining wrappers in `Drive`.
5. After this lands, reassess whether a second extracted module is justified
   for read-path behavior (`get_attr`, `read_dir`, `read`, `write`) instead of
   forcing them through the same abstraction.

## Follow-Up Work, But Not In This Plan

- evaluate a separate read-path extraction if mutation tests prove the pattern
  out
- reduce direct `Context` usage in non-mutation paths
- decide whether `init_filesystem` should later receive its own thin runtime
  boundary for thread-start testing
- update `docs/agent-docs/architecture.md` and the mutation-specific agent docs
  after the implementation lands

## Assumptions

- OUnit remains the test framework.
- The initial goal is unit-testability of mutation policy, not full integration
  testing of Google Drive or FUSE.
- It is acceptable for the extracted core to stay close to current code shape
  in the first pass; the main objective is introducing a reliable seam and
  tests, not performing a broad rewrite.
- A small functor around the extracted mutation core is acceptable; a coarse
  functor around the whole `Drive` module is not.
