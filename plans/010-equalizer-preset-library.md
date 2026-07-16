# Plan 010: Add a strict EqualizerAPO preset library

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before continuing. If a
> STOP condition occurs, report it instead of expanding the format or scope.
> Update this plan's row in `plans/README.md` when complete.
>
> **Drift check (run first)**:
> `git diff --stat 28b0210..HEAD -- Airwave/HRIRManager.swift Airwave/AirwaveStyle.swift Airwave/ProductSetup.swift AirwaveTests/ProductSurfaceTests.swift Airwave.xcodeproj/project.pbxproj dev_assets/CCA\ CRA\ ParametricEq.txt`
> Compare the current import and persistence patterns below if these paths have
> changed.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW
- **Depends on**: `plans/009-import-and-hidden-app-lifecycle.md`
- **Category**: direction
- **Planned at**: commit `28b0210`, 2026-07-16

## Why this matters

Airwave needs a deterministic boundary between untrusted text files and future
realtime DSP. This phase establishes a user-managed library and a deliberately
small EqualizerAPO-compatible grammar before any filter can affect audio. A bad
file must never partially replace a working curve.

## Current state

- `dev_assets/CCA CRA ParametricEq.txt:1-11` contains the target v1 syntax: one
  `Preamp` followed by ten `ON` filters using `LSC`, `PK`, and `HSC`.
- `Airwave/HRIRManager.swift` provides the filesystem convention to match:
  managed Application Support copies, stable UUIDs, structured preflight and
  partial batch results, atomic replacement, and persisted metadata.
- `Airwave/AirwaveStyle.swift:230-315` provides the existing typed URL drop,
  conflict confirmation, and inline-result pattern. Do not put SwiftUI types in
  the parser or library.
- The Xcode project uses a synchronized production group but an explicit test
  group; register new test sources/resources in the project if Xcode does not
  discover them automatically.
- EqualizerAPO documents that filter numbers are not interpreted. Preserve
  source line order. Reference:
  <https://sourceforge.net/p/equalizerapo/wiki/Configuration%20reference/>.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Focused tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:AirwaveTests/EqualizerAPOParserTests -only-testing:AirwaveTests/EqualizerLibraryTests test` | selected tests pass |
| Full tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test` | all tests pass |
| Build | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build` | `BUILD SUCCEEDED` |
| Whitespace | `git diff --check` | no output |

## Scope

**In scope**:

- New focused model/parser and `EqualizerManager` production files.
- New parser and filesystem-library test files plus a tracked fixture copied
  from `dev_assets/CCA CRA ParametricEq.txt`.
- `Airwave.xcodeproj/project.pbxproj` only when registration is required.

**Out of scope**:

- DSP, Core Audio, runtime readiness, Settings UI, menu-bar controls, or docs.
- Editing, exporting, downloading, or bundling user-facing EQ presets.
- EqualizerAPO `Include`, `Channel`, `Device`, expressions, routing, bandwidth,
  slopes, or any filter type beyond `PK`, `LSC`, and `HSC`.
- Watching external source files or processing them in place.

## Git workflow

- Branch: `codex/010-equalizer-preset-library`
- Suggested commit: `feat(eq): add EqualizerAPO preset library`
- Do not push or open a PR unless instructed.

## Steps

### Step 1: Define the format-neutral model

Create value types with no UI or DSP dependencies:

- `EqualizerFilterType`: `peaking`, `lowShelf`, `highShelf`.
- `EqualizerFilter`: source line, optional source number, enabled flag, type,
  frequency Hz, gain dB, and Q.
- `EqualizerDefinition`: optional/zero-default preamp dB plus filters in source
  order.
- `EqualizerPreset`: stable UUID, display name, managed file URL, and parsed
  definition.
- `EqualizerSelection`: `.none` or `.preset(UUID)`. `.none` is synthetic and
  must never be encoded as a file-backed preset.

Use `Double` for imported numeric values. Make models `Equatable`, and only make
persisted metadata `Codable`; reparsing managed text remains authoritative.

**Verify**: Build command succeeds.

### Step 2: Implement the strict parser

Accept case-insensitive UTF-8 `.txt` data up to 1 MiB, with an optional UTF-8
BOM, CRLF/LF endings, blank lines, and lines whose first non-whitespace
character is `#`. Accept exactly:

- `Preamp: <finite-number> dB`, at most once; absent means `0 dB`.
- `Filter [number]: ON|OFF PK|LSC|HSC Fc <number> Hz Gain <number> dB Q <number>`.
  The optional number is metadata only. Require the tokens and units, while
  allowing ordinary whitespace and case variations.

Reject the entire file when a non-comment line is unsupported or malformed,
when preamp is duplicated, when a number is non-finite, when frequency or Q is
not positive, when more than 64 filter declarations exist, or when the file
contains neither a non-zero preamp nor an enabled supported filter. Return a
structured error containing filename, one or more line numbers, and concise
reasons. Do not silently skip active directives as EqualizerAPO itself does;
Airwave's approved subset is intentionally strict.

**Verify**: Parser tests cover the complete grammar and every rejection rule.

### Step 3: Add the managed library

Create `EqualizerManager` as a main-actor observable object with injectable
`FileManager`, `UserDefaults`, and managed directory. Production storage is
`~/Library/Application Support/Airwave/Equalizer Presets/`. Use a small JSON
manifest mapping stable UUIDs to filenames/display names and a namespaced
`UserDefaults` key for the selected UUID.

On launch, enumerate direct child `.txt` files only, parse each, reconcile the
manifest, and sort imported presets by localized display name. Publish the
synthetic “None” selection separately; do not insert a fake URL into the preset
array. Missing, deleted, or invalid selected files fall back to `.none` and
clear the stale key while exposing a nonfatal library error.

**Verify**: Library tests cover empty/default state, reload, stable IDs, stale
metadata, invalid managed files, and missing selected files.

### Step 4: Implement safe import, collision, replacement, and delete

Mirror `HRIRManager`'s structured preflight/result API. Process each dropped
file independently so a batch can partially succeed between files, but each
file is atomic:

1. Balance security-scoped resource access with `defer`.
2. Reject directories, non-`.txt` extensions, unreadable data, oversized data,
   and parse errors before touching managed storage.
3. Derive the destination only from `lastPathComponent` and confirm its
   standardized parent is the managed directory.
4. Copy through a temporary sibling, then atomically move/replace.
5. On approved same-name replacement, preserve the UUID. If validation or copy
   fails, preserve the existing bytes, manifest entry, active selection, and
   realtime-facing definition.
6. Delete only managed copies. Deleting the selected preset first selects
   `.none`; never delete an external source file.

Persist manifest and selection immediately after successful mutation. Expose
structured results suitable for the UI in Plan 013; do not format SwiftUI
alerts here.

**Verify**: Filesystem tests cover valid copy, uppercase extension, security-
scoped balancing via an adapter, traversal-resistant basename handling,
partial batch success, rejected/approved collision, failed replacement
preserving old bytes, stable replacement UUID, selected deletion, and source
bytes remaining unchanged.

### Step 5: Add the reference fixture and close the phase

Copy the supplied sample into a tracked test-fixture location; preserve the
original `dev_assets` file. Assert it parses to preamp `-2.56 dB`, ten enabled
filters, low shelf first, high shelf last, and the exact ordered numeric values.
Do not treat the fixture as a preset bundled in the app target.

**Verify**: Focused tests, full tests, build, and `git diff --check` all pass.

## Test plan

- `EqualizerAPOParserTests`: reference fixture, BOM/CRLF, whitespace/case,
  comments, missing preamp, `OFF`, optional numbers, malformed/unsupported
  lines, duplicates, infinities/NaN, nonpositive frequency/Q, limits, and empty
  effective configuration.
- `EqualizerLibraryTests`: managed storage, manifest/selection persistence,
  collision policies, atomic replacement, partial batches, deletion, and
  relaunch reconciliation.
- Follow the temporary-directory and injected-defaults conventions in
  `AirwaveTests/ProductSurfaceTests.swift:98-160`.

## Done criteria

- [ ] The supplied reference file parses exactly and no unsupported directive
  can enter the library silently.
- [ ] “None” is the default without a managed file or bundled curve.
- [ ] Import/replacement is atomic per file and never changes source files.
- [ ] IDs and selection survive relaunch; stale state falls back to “None.”
- [ ] Focused and full test commands pass; no production audio path changed.

## STOP conditions

- The requested subset cannot represent the supplied fixture exactly.
- Safe replacement would require deleting the destination before a validated
  temporary copy exists.
- Adding the fixture to tests would also copy it into the application bundle.
- Implementation starts accepting unapproved EqualizerAPO directives merely
  to make parsing permissive.

## Maintenance notes

Keep the parsed definition independent from coefficient math. Future format
extensions must add parser fixtures and explicit product approval; never make
unknown directives silently active.

