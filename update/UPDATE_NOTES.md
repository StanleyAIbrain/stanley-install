# Brain Update — What We Did, Why, and What's Coming to Your Instance

*Prepared June 2026 · StanleyAI Brain (mcp-memory-service appliance)*

---

## TL;DR

We stress-tested Brain to find out where it breaks as it grows — data volume, speed, and accuracy over time. The infrastructure turned out to be strong (hundreds of thousands of memories of headroom), but we found and fixed two real problems that would have quietly degraded *any* Brain instance as it ages, including yours. Both fixes are now live and proven on the founding instance — verified end-to-end through its production connection. This update packages them for yours.

---

## WHY WE DID THIS

Brain's promise is "memory that never dies and never gets dumber." To trust that at business scale, we ran a 30-point stress test against the live system instead of assuming. Three findings drove everything:

**1. Tag sprawl was the silent killer.** Every memory was inventing its own labels. At only ~830 memories the founding instance had 2,011 unique tags — 70% used exactly once. A filing cabinet where nearly every document invents a new folder name stops being a filing system. Left alone, this makes browsing and filtering useless long before any hardware limit matters.

**2. Retrieval accuracy decays as near-duplicates accumulate.** Measured, not theorized: recall dropped from 99% to ~92–94% in roughly a week as similar recurring entries (daily reports, repeated session notes) piled up and crowded search results. About a point a day. Every active instance will experience this — it's a property of how vector search behaves on look-alike data, not a bug in any one install.

**3. Summaries get buried by their own sources, and dates are invisible to semantic search.** Ask for "the rolling report summary" and you get the individual reports instead. Ask for "the April 3rd report" and the search engine literally cannot tell April 3 from April 5 — meaning-based search is blind to exact attributes like dates.

The core design constraint throughout: **nothing is ever deleted.** How a conclusion was reached matters as much as the conclusion, so every fix had to be additive — organize and rank smarter, never remove.

---

## WHAT WE DID

### Fix #1 — Tag Hygiene & Canonical Facets (LIVE, proven)
- A small, fixed labeling backbone added **on top of** existing tags (originals untouched): `project:` (which business/area), `type:` (lesson, decision, report, research…), `status:` (active, superseded…), `priority:`.
- Date-style tags (`april-3-2026`, etc.) moved into structured metadata where they belong — the single biggest source of label sprawl, eliminated losslessly.
- Recurring report snapshots left fully intact, with one **rolling synthesis** memory added on top that links back to every source (full provenance trail).
- **Proven before touching anything live:** three sandbox runs on copies — current data, a refined pass, and an older backup — with hard gates: zero memories deleted (verified by content-hash set), zero stripped of tags, retrieval accuracy unchanged, fully reversible with a timestamped backup. Then applied live and re-verified end-to-end through the production connection.
- Result: 100% of memories reachable through clean filters; date noise gone; nothing lost.

### Fix #2 — Smarter Retrieval (validated; shipping the proven pieces)
Two pieces ship, behind independent on/off flags, both read-path (they change how answers are found and ordered — they never modify stored data):
- **Date-aware retrieval:** when a query contains a date, an exact-match path (built on the structured date metadata from Fix #1) finds the precise entry semantic search can't distinguish. Validated on real data: dated queries went from 1-in-4 correct to **4-for-4**, with zero change to non-date queries and ~4 ms cost.
- **Enriched synthesis pattern:** summaries carry the actual rolled-up substance (not just pointers) and supersede by *linking* — a new summary lists the old one as a source. Nothing edited, nothing removed.

One candidate component — a result re-ranker for de-crowding look-alike entries — was **deliberately held back**: it aced its design goal (buried memories found 0%→100%) but gated validation showed it traded away exact-recall on near-duplicate entries, and our shipping rule is "better, not worse — proven, on your data's shape." It returns in a future release paired with consolidation, where it can deliver the upside without the trade. This is the gate system working.

### The discipline that made it safe
Every change followed the same gauntlet: research → adversarial committee review → built and iterated in an isolated sandbox → replicated by the autonomous executor against real data on copies → hard pass/fail gates (zero deletion, no accuracy regression, latency budgets, byte-identical files in sandbox) → live apply only after explicit approval → independent re-verification through the production path. Two proposed designs failed their gates during this process and were corrected *before* live — which is the system working.

---

## WHAT THIS MEANS FOR YOUR INSTANCE

- **Your Brain stays sharp as it grows.** The decay curve we measured would hit any active instance; the update arrests it.
- **Capacity ceilings are unchanged — but now reachable.** The measured limits (~330K memories before speed matters on Apple-silicon hardware, ~485K before storage does) were never the real risk; functional degradation at a few thousand memories was. This update is the difference between theoretical capacity and usable capacity.
- **Your data is never touched destructively.** The transform is additive and idempotent (running it twice changes nothing the second time). Original tags stay. Nothing is deleted — ever. Full timestamped backup and one-command rollback are part of the procedure.
- **Everything new is switchable.** Retrieval upgrades sit behind config flags; any piece can be turned off in seconds without touching data.
- **Foundation for scale.** The facet labels double as partition keys for the future multi-user / multi-business architecture (per-person memory spaces, per-employee ingestion) — so this update is also the groundwork for where Brain is headed.

---

## WHAT'S IN THE UPDATE

One versioned release, containing:

1. **Tag-hygiene tools** — `tag_propose.py` reads *your* memories and proposes a facet map built from *your* vocabulary, which **you review and approve** (nothing from anyone else's instance is baked in). `tag_apply.py` then applies only the map you approved — append-only, zero-deletion enforced in code, idempotent (safe to run twice).
2. **Date-aware retrieval** — `apply_pieceC.py` patches the retrieve path behind a `HYBRID_DATE_ENABLED` flag; dated questions return the exact entry. If a queried date doesn't exist in your data, it falls back to normal search — proven on a clean test instance.
3. **Synthesis pattern guidance** (`SYNTHESIS_PATTERN.md`) — how to add rolling summaries that link to their sources and supersede by linking, never by deleting.
4. **Store-time vocabulary guidance** (`STORE_GUIDANCE.md`) — how to tag new memories with the clean facets so sprawl doesn't regrow.
5. **`RUNBOOK.md` + `verify.py` + `rollback.sh`** — self-contained apply/verify/rollback: full backup procedure, service pause/restart notes (including the known ~33-second model reload on restart), post-update verification gates, and both instant (flag-off) and full rollback.

Everything above passed two rounds of proof before reaching you: gated validation and a live re-test on the founding instance, then a full clean-room run — a fresh vanilla install with non-StanleyAI test data, updated using only the runbook, gating zero deletions, fail-open behavior, and working rollback. Your appliance stays fully self-contained — the update is code you run on your own hardware, same as day one.
