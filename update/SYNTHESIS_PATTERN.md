# Synthesis Pattern — Additive Rolling Summaries (never edit, never delete)

When you have a growing pile of related entries (weekly reports, recurring session notes, repeated
status snapshots), don't let them crowd retrieval and don't rewrite history. Instead add a **rolling
synthesis** memory *on top* of them. This is the only sanctioned way to "summarize" in Brain.

## The four rules

1. **Carry real substance, not pointers.** The synthesis memory's content holds the actual rolled-up
   information — the numbers, the trend, the decisions — so a semantic search for the summary finds a
   memory that *reads* like the summary. (A bare "see the 12 reports" index embeds far from real
   questions and gets buried.)
2. **Link every source by content hash.** Put the exact `content_hash` of each source entry in a
   `synthesizes` array in the new memory's `metadata`. This is the provenance trail and the signal the
   date-aware/retrieval layer uses to treat the synthesis as the cluster's representative.
3. **Supersede by LINKING, never by editing or deleting.** When you write a newer synthesis, list the
   *previous* synthesis's `content_hash` in the new one's `synthesizes` array too, and append a
   `status:superseded` tag to the old synthesis (tag-append only — its content is never touched). The
   old summary stays fully retrievable; it's just no longer the front-runner.
4. **Tag it as a rolling summary.** Give the synthesis `type:report` (or your apt type) and
   `status:rolling`. Retrieval deprioritizes `status:rolling` / `synthesizes`-bearing memories on
   *exact* lookups (you asked for the specific entry, not the overview) and surfaces them on *general*
   ones — automatically, because of rules 2 and 4.

> Originals are never edited and never deleted. A synthesis is purely additive: +1 memory, plus
> tag-appends on the items it links. Running the pattern again is safe.

## Generic example

Say you have three weekly health snapshots already stored, with content hashes `aaa…`, `bbb…`, `ccc…`.
You write the first synthesis:

```jsonc
// new memory
{
  "content": "ROLLING HEALTH SUMMARY (weeks 1–3): uptime 99.1% → 99.4% → 99.6%; two incidents, both
              resolved < 1h; error budget 38% remaining. Trend: improving, no action needed.",
  "tags": ["project:platform", "type:report", "status:rolling", "health-summary"],
  "metadata": { "synthesizes": ["aaa…", "bbb…", "ccc…"], "rolling": true }
}
```

A month later, with new snapshots `ddd…`, `eee…` and the old synthesis at hash `S1…`, you supersede it
**by linking**, not editing:

```jsonc
// newer memory — lists the old synthesis (S1) AND the new sources as its sources
{
  "content": "ROLLING HEALTH SUMMARY (weeks 1–5): uptime steady ~99.6%; one new incident; error budget
              31% remaining. Supersedes the weeks 1–3 summary; full series linked below.",
  "tags": ["project:platform", "type:report", "status:rolling", "health-summary"],
  "metadata": { "synthesizes": ["S1…", "ddd…", "eee…"], "rolling": true }
}
```

```text
# and a tag-append (NOT an edit) on the old synthesis S1:
S1.tags += "status:superseded"
```

Result: one clean front-runner summary, an unbroken provenance chain back to every original, and zero
destructive changes. The previous summary and all raw snapshots remain searchable forever.
