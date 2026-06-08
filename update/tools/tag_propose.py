#!/usr/bin/env python3
"""
tag_propose.py  —  BRAIN UPDATE: tag-map PROPOSAL tool (generalized; no instance-specific map).

Reads a mcp-memory-service sqlite_vec.db (read-only), clusters the EXISTING tag vocabulary,
and PROPOSES a canonical facet map (project:/type:/status:/priority:) for the OWNER to review,
edit, and approve. It does NOT modify anything. Output: a proposed_tag_map.json the owner edits,
plus a human-readable summary.

Workflow:  cluster  ->  propose  ->  (owner edits/approves JSON)  ->  tag_apply.py uses it.

Generalizes to ANY instance: project candidates are DERIVED from the data (frequency +
co-occurrence), not hardcoded. type: comes from the memory_type column. status:/priority:
are proposed only for generic cue tags actually present.

Usage:  python3 tag_propose.py --db <sqlite_vec.db> --out proposed_tag_map.json
"""
import sqlite3, json, re, argparse, sys
from collections import Counter, defaultdict

# --- generic, instance-AGNOSTIC cue lexicons (only proposed if present in the data) ---
STATUS_CUES = {
    "done": "done", "shipped": "done", "complete": "done", "completed": "done", "closed": "done",
    "open": "open", "todo": "open", "wip": "open", "in-progress": "open", "next": "open",
    "active": "active", "live": "active", "ongoing": "active",
    "blocked": "blocked", "superseded": "superseded", "archived": "archived",
    "lesson-learned": "learned", "lesson": "learned", "learned": "learned",
}
PRIORITY_CUES = {
    "permanent": "permanent", "critical": "critical", "important": "important",
    "urgent": "urgent", "pinned": "pinned", "always-pull-first": "pinned", "high-priority": "high",
}
# tags that are facet-like / generic and must NOT be proposed as projects
GENERIC = set(STATUS_CUES) | set(PRIORITY_CUES) | {
    "milestone", "note", "observation", "research", "decision", "reference", "idea", "question",
    "fix", "bug", "feature", "task", "core", "misc", "general", "untagged", "status-update",
    "action-item", "deliverable", "architecture", "configuration", "feedback", "handoff",
    "correction", "report", "deep-dive", "session-learnings", "global", "active", "draft",
}

_MONTHS = ("january|february|march|april|may|june|july|august|september|october|november|december"
           "|jan|feb|mar|apr|jun|jul|aug|sep|sept|oct|nov|dec")
_DATE_RE = [
    re.compile(r'^\d{4}-\d{1,2}-\d{1,2}$'), re.compile(r'^\d{4}-\d{1,2}$'),
    re.compile(r'^(19|20)\d{2}$'),
    re.compile(r'^(?:' + _MONTHS + r')(?:-\d{1,2})?(?:-(?:19|20)\d{2})?$', re.I),
    re.compile(r'^(?:19|20)\d{2}-?q[1-4]$', re.I), re.compile(r'^q[1-4](?:-?(?:19|20)\d{2})?$', re.I),
    re.compile(r'^\d{1,2}-\d{1,2}-(?:19|20)?\d{2}$'),
]
_NOT_DATE = {"decision", "decisions", "marketing"}
_RELTIME = {"today", "yesterday", "tomorrow", "this-week", "last-week", "this-month", "tonight", "next-session"}

def is_date_tag(t):
    tl = t.strip().lower()
    if tl in _NOT_DATE: return False
    if tl in _RELTIME: return True
    return any(p.match(tl) for p in _DATE_RE)

def parse_tags(s):
    return [t.strip() for t in (s or "").split(",") if t.strip() and t.strip().lower() != "untagged"]

def already_faceted(t):
    return t.startswith(("project:", "type:", "status:", "priority:"))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", required=True)
    ap.add_argument("--out", default="proposed_tag_map.json")
    ap.add_argument("--project-min", type=int, default=0, help="min memories for a project candidate (0=auto)")
    a = ap.parse_args()

    con = sqlite3.connect(f"file:{a.db}?mode=ro", uri=True)
    cols = [r[1] for r in con.execute("PRAGMA table_info(memories)")]
    where = "WHERE deleted_at IS NULL" if "deleted_at" in cols else ""
    rows = con.execute(f"SELECT tags, memory_type FROM memories {where}").fetchall()
    con.close()
    N = len(rows)
    if N == 0:
        print("No active memories — nothing to propose."); sys.exit(0)

    per = [parse_tags(r[0]) for r in rows]
    mtypes = Counter((r[1] or "").strip().lower() for r in rows if (r[1] or "").strip())
    tag_count = Counter(t for ts in per for t in ts if not already_faceted(t))
    # auto threshold: a project tag should appear in at least ~0.7% of memories (min 3)
    pmin = a.project_min or max(3, round(N * 0.007))

    # candidate project tags = frequent, non-date, non-generic, non-faceted
    cands = {t: c for t, c in tag_count.items()
             if c >= pmin and not is_date_tag(t) and t.lower() not in GENERIC}
    # co-occurrence among candidates -> cluster (connected components, edge if co-occur >= cc_min)
    cc_min = max(2, round(N * 0.003))
    co = defaultdict(int)
    for ts in per:
        cs = sorted(set(t for t in ts if t in cands))
        for i in range(len(cs)):
            for j in range(i + 1, len(cs)):
                co[(cs[i], cs[j])] += 1
    parent = {t: t for t in cands}
    def find(x):
        while parent[x] != x: parent[x] = parent[parent[x]]; x = parent[x]
        return x
    for (a1, b1), w in co.items():
        if w >= cc_min:
            ra, rb = find(a1), find(b1)
            if ra != rb: parent[rb] = ra
    clusters = defaultdict(list)
    for t in cands: clusters[find(t)].append(t)
    # propose project name = highest-frequency member (lead); owner can rename
    project_clusters = []
    for members in clusters.values():
        members = sorted(members, key=lambda t: -tag_count[t])
        lead = members[0]
        project_clusters.append({
            "proposed_project": lead,
            "member_tags": members,
            "memories": int(sum(1 for ts in per if any(t in members for t in ts))),
        })
    project_clusters.sort(key=lambda c: -c["memories"])

    # type: from memory_type column (identity, normalized)
    type_map = {mt: re.sub(r'[_\s]+', '-', mt) for mt in mtypes}
    # status/priority: only cues PRESENT in the vocabulary
    status_present = {t: STATUS_CUES[t.lower()] for t in tag_count if t.lower() in STATUS_CUES}
    priority_present = {t: PRIORITY_CUES[t.lower()] for t in tag_count if t.lower() in PRIORITY_CUES}

    date_tags = sorted([t for t in tag_count if is_date_tag(t)], key=lambda t: -tag_count[t])
    singletons = sum(1 for c in tag_count.values() if c == 1)

    proposal = {
        "_README": "EDIT this file to approve. Rename/remove project clusters, adjust facets. "
                   "Set 'approved': true when ready. Then run tag_apply.py --map this_file.",
        "approved": False,
        "instance_stats": {"active_memories": N, "unique_tags": len(tag_count),
                           "singleton_tags": singletons, "project_min_threshold": pmin},
        "date_tags_to_metadata": {"count_unique": len(date_tags), "examples": date_tags[:25]},
        "project_facets": [{"canonical": c["proposed_project"], "from_tags": c["member_tags"],
                            "memories": c["memories"]} for c in project_clusters],
        "type_facets_from_memory_type": type_map,
        "status_facets": status_present,
        "priority_facets": priority_present,
        "notes": ["project canonical names are the most-frequent tag in each co-occurrence cluster — RENAME freely.",
                  "type: is derived from the memory_type column (universal).",
                  "status:/priority: are proposed ONLY for generic cue tags found in your data.",
                  "date tags are relocated to metadata['date_tags'] by tag_apply (never deleted)."],
    }
    with open(a.out, "w") as f:
        json.dump(proposal, f, indent=2)

    print(f"=== TAG-MAP PROPOSAL (instance: {N} memories, {len(tag_count)} unique tags) ===")
    print(f"  date tags -> metadata: {len(date_tags)} unique")
    print(f"  project clusters proposed: {len(project_clusters)} (threshold >= {pmin} memories)")
    for c in project_clusters[:12]:
        print(f"     project:{c['proposed_project']:<18} <- {c['member_tags']}  ({c['memories']} mem)")
    print(f"  type: facets (from memory_type): {sorted(type_map.values())}")
    print(f"  status: cues found: {sorted(set(status_present.values())) or '(none)'}")
    print(f"  priority: cues found: {sorted(set(priority_present.values())) or '(none)'}")
    print(f"\n  -> wrote {a.out}.  OWNER: review, edit, set approved:true, then run tag_apply.py.")

if __name__ == "__main__":
    main()
