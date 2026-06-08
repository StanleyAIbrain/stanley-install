#!/usr/bin/env python3
"""
tag_apply.py  —  applies an OWNER-APPROVED proposed_tag_map.json to a sqlite_vec.db.

APPEND-ONLY + relocate. Invariants (asserted): zero memories deleted, zero memories stripped to
no tags, idempotent on re-run. Date-pattern tags are MOVED to metadata['date_tags'] (never lost).

REQUIRES the map's "approved": true. Operate on a COPY / after a backup (see RUNBOOK).

Usage:  python3 tag_apply.py --db <sqlite_vec.db> --map proposed_tag_map.json
"""
import sqlite3, json, re, argparse, sys, os
from collections import Counter
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # find tag_propose regardless of cwd
# reuse the exact date logic from the proposal tool so detection matches
from tag_propose import is_date_tag, parse_tags, already_faceted

def build_reverse(mapping):
    proj = {}
    for pf in mapping.get("project_facets", []):
        canon = pf["canonical"]
        for t in pf.get("from_tags", []):
            proj[t.lower()] = canon
    typ = {k.lower(): v for k, v in mapping.get("type_facets_from_memory_type", {}).items()}
    sts = {k.lower(): v for k, v in mapping.get("status_facets", {}).items()}
    pri = {k.lower(): v for k, v in mapping.get("priority_facets", {}).items()}
    return proj, typ, sts, pri

def derive_facets(kept_tags, memory_type, proj, typ, sts, pri):
    facets = set()
    low = {t.lower() for t in kept_tags}
    for t in low:
        if t in proj: facets.add("project:" + proj[t])
        if t in sts:  facets.add("status:" + sts[t])
        if t in pri:  facets.add("priority:" + pri[t])
    mt = (memory_type or "").strip().lower()
    if mt in typ: facets.add("type:" + typ[mt])
    return facets

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", required=True); ap.add_argument("--map", required=True)
    ap.add_argument("--force", action="store_true", help="apply even if approved!=true (NOT recommended)")
    a = ap.parse_args()
    mapping = json.load(open(a.map))
    if not mapping.get("approved") and not a.force:
        print("ERROR: map is not approved (set \"approved\": true after review). Aborting."); sys.exit(2)
    proj, typ, sts, pri = build_reverse(mapping)

    con = sqlite3.connect(a.db)
    cols = [r[1] for r in con.execute("PRAGMA table_info(memories)")]
    has_del = "deleted_at" in cols
    where = "WHERE deleted_at IS NULL" if has_del else ""
    c = con.cursor()
    rows = c.execute(f"SELECT id, tags, memory_type, metadata FROM memories {where}").fetchall()
    before_active = len(rows)
    before_total = c.execute("SELECT COUNT(*) FROM memories").fetchone()[0]
    tc_before = Counter(t for r in rows for t in parse_tags(r[1]))

    moved = appended = stripped_guard = 0
    for mid, tags, mtype, meta in rows:
        orig = parse_tags(tags)
        date_tags = [t for t in orig if is_date_tag(t)]
        kept = [t for t in orig if not is_date_tag(t)]
        new_facets = sorted(f for f in derive_facets(kept, mtype, proj, typ, sts, pri)
                            if f.lower() not in {x.lower() for x in kept})
        final = kept + new_facets
        if not final:                      # never strip to empty: keep original (incl. dates)
            final = orig[:]; date_tags = []; stripped_guard += 1
        appended += len(new_facets); moved += len(date_tags)
        md = {}
        if meta:
            try: md = json.loads(meta)
            except Exception: md = {}
        if date_tags:
            md["date_tags"] = sorted(set(md.get("date_tags", [])) | set(date_tags))
        c.execute("UPDATE memories SET tags=?, metadata=? WHERE id=?",
                  (",".join(final), json.dumps(md), mid))
    con.commit()

    after_rows = c.execute(f"SELECT tags FROM memories {where}").fetchall()
    after_active = len(after_rows)
    after_total = c.execute("SELECT COUNT(*) FROM memories").fetchone()[0]
    tc_after = Counter(t for r in after_rows for t in parse_tags(r[0]))
    untagged_after = sum(1 for r in after_rows if not parse_tags(r[0]))
    con.close()

    deleted = before_total - after_total
    print("=== tag_apply RESULT ===")
    print(f"  active memories: {before_active} -> {after_active}   total rows: {before_total} -> {after_total}")
    print(f"  unique tags: {len(tc_before)} -> {len(tc_after)}   date assignments moved: {moved}   facets appended: {appended}")
    print(f"  INVARIANTS:  deleted={deleted} ({'OK' if deleted==0 else 'VIOLATION'})   "
          f"untagged_after={untagged_after}   stripped-guard fired={stripped_guard}")
    facet_cov = sum(1 for r in after_rows
                    if any(t.startswith(('project:', 'type:', 'status:', 'priority:')) for t in parse_tags(r[0])))
    print(f"  any-facet coverage: {facet_cov}/{after_active} ({round(100*facet_cov/after_active)}%)")
    assert deleted == 0, "DELETION DETECTED — abort"

if __name__ == "__main__":
    main()
