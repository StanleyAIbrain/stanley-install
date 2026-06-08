# Store-Time Vocabulary Guidance — keep sprawl from regrowing

Tag hygiene is a one-time cleanup. It stays clean only if **new** memories are tagged with discipline.
These are the rules for every `store_memory` from here on. They're cheap, and they're the difference
between a filing system and a pile.

## The rules

1. **Always attach the canonical facets.**
   - `project:<area>` — which business/area this belongs to. Reuse an existing value.
   - `type:<kind>` — what it is: `lesson`, `decision`, `report`, `research`, `note`, `observation`, etc.
   - Add `status:<state>` when it has a lifecycle (`active`, `done`, `open`, `superseded`).
   - Add `priority:<level>` when it matters (`critical`, `permanent`, `pinned`).
2. **Dates go in `metadata.date_tags`, never in the tag list.** Store the date(s) as structured metadata
   (e.g. `metadata.date_tags = ["2026-04-03"]`), not as a tag like `april-3-2026`. Free-floating date
   tags were the single biggest source of sprawl. The retrieval layer reads dates from content and
   metadata — it never needs a date *tag*.
3. **Reuse before you mint.** Before inventing a new `project:`/`type:`/`status:`/`priority:` value,
   check the values already in use and reuse the closest fit. A new facet value should be a deliberate
   decision, not a typo or a synonym (`refactor` vs `refactoring` vs `cleanup` → pick one).
   - Quick check: list existing facet values with `search_by_tag` on a known facet, or skim a recent
     `tag_propose.py` run. If your new memory's area/kind already exists, use that exact string.
4. **Freeform tags are welcome — on top.** Beyond the four facets, add any descriptive tags you like
   (`gripper`, `q4-budget`, `griffin-funding`). They're useful for recall and don't count as sprawl as
   long as the canonical facets are present. The facets are for *filtering*; freeform tags are for
   *flavor*.

## One good example

```jsonc
{
  "content": "Decided to standardize on the A* router for warehouse pathing; cuts average pick travel ~12%.",
  "tags": ["project:logistics", "type:decision", "status:active", "routing", "a-star"],
  "metadata": { "date_tags": ["2026-04-03"] }
}
```
- Canonical facets present (`project:`, `type:`, `status:`) ✔
- Date in `metadata.date_tags`, not as a tag ✔
- Reused existing `project:logistics` ✔
- Freeform `routing`, `a-star` on top ✔

## One anti-pattern to avoid

```jsonc
// ❌ don't do this
{ "tags": ["logistics-routing-decision-april-2026", "april-3-2026", "important-ish"] }
```
That's a brand-new single-use label, a date as a tag, and a fuzzy priority — exactly the sprawl the
cleanup removed. The good version above filters cleanly forever.
