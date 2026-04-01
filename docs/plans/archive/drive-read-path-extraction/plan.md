# Archived Plan: Extract Testable Read-Side View Paths From `Drive`

Archived after implementation.

This plan was completed by extracting `DriveViews` for `get_attr`,
`read_link`, and `opendir`, then extracting `DriveDirectoryReads` for
`read_dir`, while keeping content read/write/upload paths in `Drive`.

## Summary

After the mutation-path refactor, the next useful seam is not "all remaining
read paths" behind one big functor. The read side has at least three different
shapes:

- view synthesis over cached metadata
- directory snapshot rebuilding
- content reads with streaming, local cache files, and async read-ahead

This follow-up should extract only the first shape in the initial slice:
`get_attr`, `read_link`, and optionally `opendir`.

Those functions are strongly related:

- they normalize visible paths
- they resolve resources without mutating user content
- they synthesize visible filesystem behavior from cached metadata
- they contain high-value policy that is currently hard to test in isolation

If that extraction proves useful, evaluate a second read-side module for
directory listing behavior. Do not force `read`, `write`, `truncate`, or the
upload/download pipeline into the same abstraction.

## Why This Should Not Be A Single `DriveReads.Make(DEPS)`

- `get_attr`, `read_link`, and `opendir` are mostly metadata/view logic.
- `read_dir` is a snapshot-rebuild path with cache-validity gates, remote
  pagination, synthetic roots, and duplicate-name reconciliation.
- `read` is an I/O policy layer over streaming, memory buffers, download
  fallback, and async read-ahead.
- `write` and `truncate` are really part of the local-mutation/upload side,
  even though they are often grouped with reads in FUSE callback tables.

A single coarse read-side functor would recreate the same problem the mutation
plan avoided:

- too many unrelated concerns in one `PORTS` surface
- tests forced to fake more than they need
- high refactor cost before any new coverage appears

So the right follow-up is a smaller extraction around view logic first, then a
separate decision about directory reads.

## Scope Of This Follow-Up

Initial in scope:

- shared view helpers needed by:
  - `get_attr`
  - `read_link`
  - `opendir` if it remains a trivial sibling wrapper
- shortcut target reconstruction used by:
  - `read_link`
  - `get_attr` size computation for shortcuts
- virtual-root stat behavior for:
  - `/`
  - `/.Trash`
  - `/.shared`
  - `/lost+found`

Potential second slice, but not required for the first landing:

- `read_dir`

Out of scope:

- `read`
- `write`
- `truncate`
- upload/download streaming
- metadata refresh and change polling
- background services started by `init_filesystem`
- `fopen`

## Target Structure

Add a new library module pair for the first slice:

- `src/driveViews.ml`
- `src/driveViews.mli`

Keep `src/drive.ml` public and production-facing, but reduce the relevant
entrypoints to thin wrappers that:

1. read the real runtime state from `Context`
2. build a small runtime record
3. call the extracted view core
4. execute any returned `SessionM` request through `do_request`

Do not add `read_dir` to this module in the first pass.

If the first slice proves valuable, evaluate a second module pair:

- `src/driveDirectoryReads.ml`
- `src/driveDirectoryReads.mli`

That second module should be considered independently rather than assumed.

## Proposed `runtime` Shape For `DriveViews`

The view core should not call `Context.get_ctx ()` directly. Instead, build an
explicit runtime record once in `Drive` and pass it down.

Start with a shape such as:

```ocaml
type runtime = {
  cache : CacheData.t;
  config : Config.t;
  mountpoint_path : string;
  mountpoint_stats : Unix.LargeFile.stats;
}
```

If later tests show that some derived value is always used together, prefer
adding it as a runtime field instead of repeatedly recomputing it in wrappers.

## Proposed `PORTS` Boundary For `DriveViews`

Keep the boundary semantic and narrow. The first slice should own only the
unstable effects needed for view synthesis:

- path normalization and resource lookup
- shortcut-target reconstruction support
- optional local materialization needed by document `getattr`
- local stat lookup for materialized content
- read-only/resource-read-only checks already reused by view logic
- cache updates needed when shortcut targets are reconstructed lazily

Representative operations:

- `get_path_in_cache`
- `get_resource`
- `get_resource_with_id`
- `update_cached_resource`
- `materialize_for_stat`
- `stat_file_if_present`
- `is_file_read_only`
- `is_lost_and_found_root`
- `is_shared_with_me_root`
- `is_shortcut`
- `is_symlink`
- `is_folder`

Do not mirror the whole public `Drive` surface. The extracted module should own
policy and view synthesis, not every helper in `drive.ml`.

## Implementation Changes

### 1. Extract `DriveViews`

Move the policy and synthesis logic for these paths out of `src/drive.ml`:

- `get_attr`
- `read_link`
- `opendir` if kept together
- the shared shortcut-target reconstruction helper currently reused by
  `get_attr` and `read_link`

Preserve the current behavior closely. The point of the first pass is not to
redesign stat semantics. It is to introduce a reliable seam and tests.

### 2. Keep `Drive` As A Thin Adapter

After extraction, `src/drive.ml` should still export the current public
functions, but these entrypoints should become small wrappers:

- `get_attr`
- `read_link`
- `opendir`

Those wrappers should:

- build `runtime` from the real `Context`
- delegate to `DriveViews`
- preserve current exceptions and outward behavior

`read_dir`, `read`, `write`, `truncate`, and startup/metadata-refresh code
should stay where they are for now.

### 3. Decide Separately On `DriveDirectoryReads`

Do not automatically continue from `DriveViews` into `read_dir`.

Instead, after the first slice lands, reassess whether `read_dir` deserves its
own extraction. That decision should depend on:

- whether the `DriveViews` seam materially improved tests and maintenance
- whether `read_dir` policy is still hard to change confidently
- whether the required `PORTS` surface stays smaller than a coarse read-side
  module would require

### 4. Keep `read` And Content I/O In `Drive`

`read` should stay in `src/drive.ml` for now.

Its current logic combines:

- stream-vs-local-file policy
- memory-buffer reads
- download fallback
- async read-ahead dispatch

That is a different abstraction boundary from view synthesis. If needed later,
extract only small pure helpers such as:

- read-strategy selection
- read-ahead eligibility

Do not make that part of this plan.

## Behavioral Constraints

- Preserve all current public `Drive` signatures.
- Preserve current FUSE-visible behavior and current exception mapping.
- Preserve the existing decisions around:
  - virtual-root stat behavior
  - permission masking with `umask` and read-only rules
  - symlink versus shortcut size handling
  - lazy shortcut target reconstruction
  - document materialization during `getattr`
- Do not move streaming/content-read behavior into this first refactor.
- Do not mix upload-path behavior into this read-side extraction.

## Test Strategy

Add a new test module for the first slice:

- `test/testDriveViews.ml`

Register it from `test/testSuite.ml`.

Build tests around `DriveViews.Make(FakePorts)`, where `FakePorts`:

- stores synthetic resources in memory
- records cache updates for lazy shortcut-target reconstruction
- returns fake `SessionM` values for lookup/materialization steps
- avoids touching the real `Context`, filesystem, or network

Prefer using real `CacheData.Resource.t` values in memory rather than mocking
the record shape.

## First Test Cases For `DriveViews`

`get_attr`:

- root returns `mountpoint_stats` unchanged
- `/.Trash` and `/.shared` return mountpoint-derived stats masked to read-only
- `/lost+found` returns mountpoint-derived stats unchanged
- regular files apply saved mode bits and `umask` correctly
- read-only files mask write bits correctly
- folders report directory kind and fallback size behavior
- shortcuts and symlinks report size from the resolved link target length
- document `getattr` can ignore `File_not_found` during materialization and
  still synthesize stats from metadata

`read_link`:

- stored symlinks return the stored target without extra lookup
- shortcuts with cached `link_target` return it directly
- shortcuts with only `target_id` reconstruct the mountpoint-prefixed target
  path
- reconstructed shortcut targets are written back into the cache row
- non-link-like resources raise `Invalid_operation`

`opendir`:

- existing resources resolve successfully
- missing resources propagate the same lookup failure as today

## Candidate Second Slice: `DriveDirectoryReads`

Only if the first slice proves worthwhile, consider a separate plan or a second
stage for:

- `read_dir`

That extraction would need its own `PORTS` boundary, likely centered on:

- cache-validity checks
- cached child selection
- paginated remote listing
- special-root listing strategies
- filename disambiguation and snapshot replacement

Representative first tests for that later slice would be:

- cache hit returns child names without remote listing
- `lost+found` only exposes parentless owned files
- `.shared` uses the shared-with-me query path
- trash-root listing includes explicitly trashed items
- duplicate sibling names are disambiguated stably by remote id

Do not implement that second slice until the first slice lands cleanly.

## Suggested Sequencing

1. Add `driveViews.ml` / `.mli` with a minimal `runtime`, `PORTS`, and the
   shared shortcut-target reconstruction helper.
2. Move `read_link` first. It has a small state graph and exercises the lazy
   target-reconstruction path directly.
3. Move `get_attr` next, reusing the same shortcut-target helper and adding the
   mountpoint-stat runtime field.
4. Move `opendir` last if it still fits naturally as a tiny sibling wrapper.
5. Add `test/testDriveViews.ml` and cover the main policy branches before
   deciding whether `read_dir` deserves its own extracted module.

## Follow-Up Work, But Not In This Plan

- evaluate a separate `DriveDirectoryReads` extraction after `DriveViews` lands
- reduce direct `Context` usage in the remaining read/content paths
- consider tiny pure-helper extraction inside `read` for strategy selection
- keep `write`/`truncate` aligned with mutation/upload architecture, not with
  read-side view extraction

## Assumptions

- OUnit remains the test framework.
- The immediate goal is unit-testability of read-side view policy, not broad
  extraction of all non-mutation behavior from `Drive`.
- It is acceptable for the extracted view core to stay close to the current
  code shape in the first pass; the main objective is introducing a reliable
  seam and tests, not performing a broad rewrite.
- A small functor around `DriveViews` is acceptable; a coarse functor around
  all remaining read-side `Drive` behavior is not.
