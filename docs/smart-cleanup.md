# Smart Cleanup — Apple's on-device model

## Use

Scan normally, open the results window using the menu-bar window button, then choose
**Smart Cleanup** in its toolbar. The view first builds a bounded rules-based review.
Nothing is automatically selected. **Analyze with Apple Intelligence** is an explicit,
optional request to rank the first eight candidates. Select individual items, choose
**Review Items**, inspect the immutable list, and confirm **Move Items to Trash**.

Apple analysis requires a build made with Xcode 26 / Swift 6.2 or newer, macOS 26+,
an eligible Mac, enabled Apple Intelligence, and a ready system model. The adapter
checks availability before each generation. macOS 14+ and unsupported devices retain
rules-based review and the normal cleaner. The build includes no model weights,
downloader, API keys, cloud provider, Python, Ollama, or third-party inference library.
Apple owns system-model storage and availability; zero *additional FastCleanup model
files* does not mean Apple's system model takes no disk space.

## Data and model boundary

Only `SystemLanguageModel.default` is passed explicitly to `LanguageModelSession`.
No tools are registered. FoundationModels' cloud providers are never instantiated.
Inference receives at most eight records: opaque candidate IDs, category kind,
integer size in MiB, and enum-valued observations. It never receives filenames,
paths, file contents, manifests, scripts, credentials, or source text. Prompts and
transcripts are not logged or persisted. No network fallback exists.

Guided generation returns IDs, `review`/`keep`, and supported reason codes. An
independent validator rejects unknown IDs, duplicated IDs, mismatched snapshots,
unsupported reasons, and oversized replies. Explanations displayed in the UI are
trusted templates tied to observed facts, not unverified free-form model claims.
A model can reorder advice, not authorize a path, change selection, create an action,
override protection, choose permanent deletion, or claim bytes have been freed.

Refusals, unavailable models, invalid responses, and timeouts retain rules-based
recommendations. Requests are serialized, use fresh sessions, and have a 20-second
cooperative cancellation deadline. Cancellation clears the UI promptly and stale
results are discarded; a framework call that ignores cancellation may finish later,
but cannot mutate data or replace a newer result. No latency or quality benchmark
claim is made by this implementation.

## Candidates and safety

This first slice covers known application-cache children, Xcode DerivedData, and
selected build/dependency directories with matching project-manifest evidence.
Manifest checks read only names/type/size; project code and install scripts never run.
Manifest presence and old modification dates are not proof of disposability.
App/project activity is explicitly unknown. Every suggestion requires human review.

At most 24 trees are inspected to produce at most 16 candidates, with at most 20,000
metadata entries per tree. Symlinks (including ancestors), hardlinks, aliases,
recognized ubiquitous/cloud items, nonlocal volumes, mount boundaries, unreadable
or changing trees, and oversized trees are omitted. The review reports omitted
items; they are not silently characterized as disposable. Supported-root guards,
protected descendants, and conservative overlap rejection are independent of AI.
Custom synchronization roots not discoverable through these signals must be excluded
by the user. There is no general guarantee of detecting every third-party sync client.

Smart Cleanup excludes credentials, source-control metadata, model stores, backups,
VM disks, messaging stores, Trash, app-owned state, known cloud roots, and persistent
user exclusions. Unknown personal files and name-only build directories never enter
its candidate set. The existing manual review can still explicitly handle model and
VM categories; it cannot bypass the shared credential/cloud/app-state/user exclusions.

The actor-isolated `CleanupService` stores a single immutable approval plan. Plans
expire after five minutes, are bound to the scan, are single-use, and contain exact
item identities and complete bounded descendant metadata. All items are revalidated
before the first move and each item is revalidated immediately before its move.
Changed files or new exclusions require review again. Smart Cleanup can only move to
Trash, regardless of the normal cleaner's permanent-delete setting.

Path-based macOS Trash/restore APIs leave a residual TOCTOU window between validation
and the OS operation. Metadata inspection is not a filesystem snapshot or lock and
cannot prove data is unused. This implementation does not claim race-proof deletion.
Never use it as protection against a concurrently hostile local process.

## Existing cleanup hardening

All existing category, bulk, row, and context-menu cleanups now share AppState's
confirmation/mutation gate. Git rows are classified as maintenance actions and cannot
be trashed through the generic entry point. Root identities are captured during scans
and checked before manual file operations. Scan-generation IDs discard canceled work.
The broad `~/.cache` package-store root is removed at catalog construction, and broad
or name-only recipes are review-only rather than preselected. Parent/child overlap,
mixed file/native-tool operations, and selected conflicting actions require separate
runs. Broad native tools are blocked when user exclusions cannot be enforced.

The legacy native-command implementations remain separate from the Smart Cleanup
executor. This PR does not redesign all command subprocess handling, Docker context
validation, APFS dedupe, or Git retention semantics. Smart Cleanup never runs them.
Manual file operations retain root-level validation; the stronger bounded descendant
snapshot is specific to Smart Cleanup. Further command/legacy hardening is follow-up
work, not a claim of completing the entire original 12-package roadmap.

## Storage, outcomes, and recovery

A Trash move is reported as **moved bytes**, not freed capacity. The UI also reports
an observed home-volume free-space change, explicitly not attributed savings; APFS
sharing, snapshots, open files, and unrelated writes can affect the result. Estimates
are allocated footprints, not guarantees about immediately reclaimable space.

**Always Exclude** stores up to 256 local paths in UserDefaults. Exclusions protect
both descendants and ancestors and can be removed in the same view. **Keep** applies
to the current review and never adds a selection. Exclusions are not sent to Apple.

Restore assistance is session-only, bounded to 100 records / 40,000 metadata entries.
It validates the item still in Trash and refuses to overwrite an existing original
path or follow a substituted destination-parent symlink. After a restart, recover
files using Finder's Trash. No automatic Trash emptying or automatic history upload.

## Tests and release checks

Run `swift test` for the portable core, filesystem fixtures, fake-provider failures,
and approval/restore tests. Tests use temporary fixtures and fake Trash operations;
no real Homebrew/Docker pruning or user's files are touched. Linux tests do **not**
validate SwiftUI, FoundationModels macros, actual Apple generation, or macOS Trash.

`Smart Cleanup tests` additionally builds the adapter against a real Apple SDK,
builds a universal app, asserts weak FoundationModels linkage, and launches that
artifact on macOS 14. It separately compiles the disabled-adapter fallback. Hosted
CI is not evidence of model availability on real Apple-Intelligence hardware.

Before merging/releasing, manually test on an eligible Mac:

- Apple Intelligence on, off, model downloading/not ready, and offline after readiness.
- Bounded recommendations versus rules; forged/unsupported outputs fall back in tests.
- Cancel, rescan, exclude, close/reopen, empty results, and a changed-file review.
- Trash-only approval while permanent-delete settings are enabled; restore and collision.
- Actual UI/layout, privacy/network observation, memory use, and inference latency.

## Primary references

- [Apple SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel)
- [Availability and generation](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models)
- [Guided generation](https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation)
- [Apple Foundation Models code-along](https://developer.apple.com/events/resources/code-along-205/)
