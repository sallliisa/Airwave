# Plan 007: Restore pre-004 routing baseline

Status: DONE

Restored tracked production/test files to commit `6f2978f`. Archived the
superseded dirty Plan 004–006 patch under `/tmp/airwave-plan004-006-backup-*`.
Preserved Plans 001–003 and the rejected 004–006 documents.

Verification:

- Debug build: `** BUILD SUCCEEDED **`
- Full suite: `** TEST SUCCEEDED **`, 18 tests executed before recovery work
- No coordinator source remained on the production path during baseline check

Do not overwrite user-owned Xcode project state while reconciling this plan.
