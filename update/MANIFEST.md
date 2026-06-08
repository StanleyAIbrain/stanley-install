# Brain Update — v1 (Manifest)

**Version:** brain-update v1 · **Target:** mcp-memory-service 10.26.5 (sqlite-vec) · macOS/launchd
**Status:** published. Independently reviewed (two rounds, conditional pass → all conditions applied) and
validated end-to-end before release.
**Document set: complete.** All five package docs and five tools are present in this folder.

## What this package ships
| File | Purpose |
|---|---|
| `UPDATE_NOTES.md` | Owner-facing explainer: what we did, why, and what's coming to your instance. |
| `RUNBOOK.md` | Self-contained apply + verify + rollback. No outside knowledge required. |
| `SYNTHESIS_PATTERN.md` | The additive rolling-summary pattern (link sources by hash; supersede by linking; never edit/delete). |
| `STORE_GUIDANCE.md` | Store-time vocabulary rules so tag sprawl doesn't regrow. |
| `tools/tag_propose.py` | **Cluster → propose** a facet map from the instance's own tags. Changes nothing. |
| `tools/tag_apply.py` | Apply an **owner-approved** map. Append-only; asserts zero deletions; idempotent. |
| `tools/apply_pieceC.py` | Idempotent code patcher for the date path + sets `HYBRID_DATE_ENABLED`. Refuses partial patches. |
| `tools/verify.py` | Post-update gates (zero deletions, tag hygiene, date path works, absent date fails open). |
| `tools/rollback.sh` | `flag-off` (instant date-path disable) and `full` (DB+code+launch restore). |

## The change vs the original (per owner instruction)
An earlier draft hard-coded **the founding instance's project names** as a fixed map. This package ships the
**proposal tool** instead: every instance gets a map **derived from its own tag co-occurrence**, which the
owner reviews and approves. Nothing instance-specific is baked in.

## Generalization notes (what was generalized away)
- Project facets are **derived** (frequency + co-occurrence clustering), not a fixed list.
- `type:` comes from the universal `memory_type` column; `status:`/`priority:` only from generic cue tags **present**.
- Date matching handles **any year** (the query's year if given, else any) — the original hard-coded 2026.
- Date detection keeps the month-token guard (won't fire on "decision"/"marketing").
- No "BRAIN REPORT"/synthesis assumptions; synthesis-tagged memories are deprioritized generically
  (`status:rolling` or `metadata['synthesizes']`), which is a no-op on instances that have none.

## Independent code review (this RC) — findings + fixes
A review pass over `tools/` (correctness, security, edge cases, portability) found and **fixed** four issues;
all were re-validated after fixing (py_compile, run-from-root, double-apply idempotency, full `verify` pass):
1. **`tag_apply.py` portability** — importing `tag_propose` failed when not run from `tools/`. Fixed: the script
   now bootstraps its own directory onto `sys.path`, so it runs from any working directory.
2. **`verify.py` ↔ `tag_apply.py` consistency** — a date-only / null-`memory_type` memory legitimately keeps its
   date tag (relocating it would strip it to no tags, which is forbidden), but `verify` flagged it as a miss.
   Fixed: `verify` now counts only **relocatable** date tags (memories that also carry a non-date tag).
3. **`verify.py` date gate robustness** — the gate required the exact discovered row; recurring same-date entries
   would fail it spuriously. Fixed: it now passes if the top result carries the same date string.
4. **`rollback.sh` full-restore safety** — the storage-file locator used system `python3` (which lacks the
   module) and could yield an empty target. Fixed: it uses the brain's **venv** python, with a fallback.
   Minor: simplified `tag_apply` facet-coverage computation (was re-parsing tags per index).

## Independent code review — round 2 (CONDITIONAL PASS → applied)
Reviewer returned a conditional pass with two fixes + one confirm; all applied and re-validated:
1. **Multi-writer race (the 840→842 lesson).** RUNBOOK Step 3 now snapshots the DB **and** captures the
   active count *after* the pause (`sqlite_vec.$TS.paused.db`, `ACTIVE_AT_PAUSE`). §6 full-rollback and
   Step 6 `verify --expect-count` both reference the **post-pause** snapshot/count — so writes that landed
   just before the pause can neither be lost by a rollback nor cause a false verify failure.
2. **Full-restore data-loss warning.** §6 now states a full restore returns the brain to the Step 3 pause
   moment (anything stored after is not in the restored DB); `flag-off` is safe anytime, `full` only
   immediately after a failed apply.
3. **Approval gate confirmed (empirically).** `tag_apply.py` refuses an unapproved map: **exit code 2,
   0 rows changed, 0 facets written**; documented `--force` escape hatch applies (exit 0). Verified on a copy.

Re-validation after round 2: `verify.py` on a freshly-applied cleanroom instance → **ALL GATES PASS**
(zero-deletion 51 vs 51, 100% coverage, 0 relocatable date tags left, date-hybrid hit, absent-date fail-open).

## Clean-room proof (fresh synthetic test instance: "Northwind Robotics", 51 memories)
Ran the package against a vanilla-seeded instance **using only the runbook steps**:
| Gate | Result |
|---|---|
| Map proposal generalizes | PASS — derived project:atlas/orion/logistics/project-review/ops from the data |
| tag_apply zero deletions | PASS — 51→51 active, 0 stripped, 100% facet coverage, 2 date tags relocated |
| tag_apply idempotent (run twice) | PASS — 2nd run: 0 facets appended, 0 dates moved, 0 deleted |
| Code patcher | PASS — patches a vanilla copy, **idempotent** on re-run, py_compile OK, refuses partial |
| Date path works | PASS — "November 03 2025" and "November 03" (no year) → the Nov 03 instance |
| Date path **fails open** | PASS — "March 15 2025" (no such date) → vector path (non-empty), no error |
| Rollback | PASS — restore returns counts/contents to pre-update |
| `verify.py` end-to-end | PASS — ALL GATES PASS (incl. zero-deletion 51 vs 51) |
| Runbook self-contained | PASS — every path discovered in Step 0; no reference to prior context |

## NOT included (deliberately)
- The **reranker** (Piece A) — failed its real-data gates; stays out.
- Auto-synthesis creation — instance/owner-specific; the *pattern* is documented in `SYNTHESIS_PATTERN.md`.
- The install/tunnel/launchd bootstrap — that's the separate `stanley-install` repo; this is an **update** to an
  already-installed brain.

## Provenance
Published as the `update/` directory of this repository. The validation evidence referenced above (the
synthetic clean-room corpus) is intentionally **not** shipped — only the runbook, tools, and guidance are.
