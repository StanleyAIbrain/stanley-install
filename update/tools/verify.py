#!/usr/bin/env python3
"""
verify.py  —  post-update gates (generalized; auto-discovers a dated memory; no hardcoded data).

Checks, read-only, against a sqlite_vec.db:
  1. integrity: active memory count (optionally == --expect-count -> ZERO-DELETION gate)
  2. tag hygiene: any-facet coverage; 0 date-pattern tags left in the tags column (relocated)
  3. date path: a real "Month DD, YYYY" instance is returned by the date path; an ABSENT date FAILS OPEN

Usage:  python3 verify.py --db <sqlite_vec.db> [--expect-count N]
"""
import sqlite3, json, re, argparse, sys, warnings
import numpy as np, sqlite_vec
warnings.filterwarnings("ignore")
try:
    import torch; torch.set_num_threads(1)
except Exception: pass

_MONTHS = {m: i+1 for i, m in enumerate(["january","february","march","april","may","june","july",
           "august","september","october","november","december"])}
_MONTHS.update({m[:3]: _MONTHS[m] for m in list(_MONTHS)}); _MONTHS["sept"] = 9
_MNAME = {v: k.capitalize() for k, v in _MONTHS.items() if len(k) > 3}
_RE = "|".join(sorted(_MONTHS, key=len, reverse=True))
_DATEPAT = re.compile(r'\b(' + _RE + r')\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+((?:19|20)\d{2}))?\b', re.I)

def is_date_token(t):
    return bool(re.match(r'^(?:' + _RE + r')(?:-\d{1,2})?(?:-(?:19|20)\d{2})?$', t.strip(), re.I)) \
        or bool(re.match(r'^\d{4}-\d{1,2}-\d{1,2}$', t.strip()))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", required=True); ap.add_argument("--expect-count", type=int, default=None)
    a = ap.parse_args()
    con = sqlite3.connect(f"file:{a.db}?mode=ro&immutable=1", uri=True)
    con.enable_load_extension(True); sqlite_vec.load(con); con.enable_load_extension(False)
    rows = con.execute("select content_hash, content, tags, metadata, vec_to_json(e.content_embedding) "
                       "from memories m join memory_embeddings e on e.rowid=m.id where deleted_at is null order by m.id").fetchall()
    N = len(rows); C = [r[1] for r in rows]; H = [r[0] for r in rows]
    E = np.array([json.loads(r[4]) for r in rows], dtype=np.float32); E = E/(np.linalg.norm(E,axis=1,keepdims=True)+1e-9)
    h2i = {h: i for i, h in enumerate(H)}
    gates = []

    # 1. integrity / zero-deletion
    if a.expect_count is not None:
        gates.append(("zero-deletion (count==expected)", N == a.expect_count, f"{N} vs {a.expect_count}"))
    else:
        gates.append(("integrity (active count)", N > 0, str(N)))

    # 2. tag hygiene
    def ptags(s): return [t.strip() for t in (s or "").split(",") if t.strip() and t.strip().lower() != "untagged"]
    faceted = sum(1 for r in rows if any(t.startswith(("project:","type:","status:","priority:")) for t in ptags(r[2])))
    # date tags are only "left behind" (a relocation miss) on memories that ALSO have a non-date tag.
    # A date-only / null-type memory legitimately keeps its date — relocating it would strip it to no tags.
    date_left = 0
    for r in rows:
        ts = ptags(r[2])
        if any(not is_date_token(t) for t in ts):
            date_left += sum(1 for t in ts if is_date_token(t))
    gates.append(("any-facet coverage >= 80%", faceted/N >= 0.8, f"{round(100*faceted/N)}%"))
    gates.append(("0 relocatable date tags left in tags column", date_left == 0, str(date_left)))

    # 3. date path (auto-discover a dated instance)
    dated = None
    for i, c in enumerate(C):
        m = _DATEPAT.search(c)
        if m:
            dated = (i, m.group(0)); break
    if dated is None:
        gates.append(("date-path (no dated instance to test)", True, "skipped"))
    else:
        from sentence_transformers import SentenceTransformer
        model = SentenceTransformer("all-MiniLM-L6-v2")
        def emb(t):
            v = model.encode([t], normalize_embeddings=True)[0].astype(np.float32); return v/(np.linalg.norm(v)+1e-9)
        def rrf(ls, k0=60):
            sc = {}
            for L in ls:
                for r, i in enumerate(L): sc[i] = sc.get(i, 0)+1/(k0+r)
            return [i for i, _ in sorted(sc.items(), key=lambda kv: -kv[1])]
        def date_path(qtext):
            q = emb(qtext); sims = E @ q; vec = [int(i) for i in np.argsort(-sims)[:50]]
            m = _DATEPAT.search(qtext)
            if not m: return None, vec[0]
            mn = _MNAME[_MONTHS[m.group(1).lower()]]; da = int(m.group(2)); yr = m.group(3)
            pats = (f"%{mn} {da:02d}, {yr}%", f"%{mn} {da}, {yr}%") if yr else (f"%{mn} {da:02d},%", f"%{mn} {da},%")
            like = [h2i[h] for (h,) in con.execute("select content_hash from memories where deleted_at is null "
                    "and (content like ? or content like ?)", pats).fetchall() if h in h2i]
            if not like: return "fail-open", vec[0]
            like = sorted(like, key=lambda i: -sims[i])
            return "date-hybrid", rrf([vec, like])[0]
        di, dstr = dated
        path, top = date_path(f"record {dstr}")
        # accept the exact instance OR any memory carrying the same date string (recurring same-date entries)
        hit = path == "date-hybrid" and (top == di or dstr.lower() in C[top].lower())
        gates.append((f"date query '{dstr}' -> dated instance", hit, f"{path}"))
        # absent date -> fail open
        ap2, _ = date_path("record February 29 1999")
        gates.append(("absent date -> FAIL OPEN to vector", ap2 in ("fail-open", None), str(ap2)))
    con.close()

    print("=== VERIFY ===")
    allok = True
    for name, ok, detail in gates:
        allok &= ok
        print(f"  [{'PASS' if ok else 'FAIL'}] {name}  ({detail})")
    print(f"\n  RESULT: {'ALL GATES PASS' if allok else 'GATES FAILED'}")
    sys.exit(0 if allok else 1)

if __name__ == "__main__":
    main()
