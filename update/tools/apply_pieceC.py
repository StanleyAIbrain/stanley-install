#!/usr/bin/env python3
"""
apply_pieceC.py  —  installs the date-aware hybrid retrieve (Piece C) into mcp-memory-service.

What it does (read-path only; reranker is NOT touched):
  - locates the installed storage/sqlite_vec.py (or use --target)
  - backs it up (timestamped) and inserts 3 marked blocks (helpers, gated branch, method)
  - IDEMPOTENT: re-running is a no-op if the marker is already present
  - REFUSES partial patches: if any anchor is missing it writes nothing and exits non-zero
  - py_compile-verifies before writing
  - optionally sets `export HYBRID_DATE_ENABLED=true` in the launch script (--server-sh)

Target version: mcp-memory-service 10.26.5 (anchors match that release).
Rollback: restore the printed .prepatch_* backup and (if set) remove the flag line; restart service.

Usage:
  python3 apply_pieceC.py [--target /path/to/sqlite_vec.py] [--server-sh ~/stanley-ai/memory-server.sh] [--dry-run]
"""
import argparse, os, shutil, subprocess, sys, time

MARKER = "PIECE_C_DATE_HYBRID_V1"

HELPERS = '''# === ''' + MARKER + ''' (helpers) — date-aware hybrid retrieve =======================
_HD_MONTHS = {m: i + 1 for i, m in enumerate(
    ["january", "february", "march", "april", "may", "june", "july", "august",
     "september", "october", "november", "december"])}
_HD_MONTHS.update({m[:3]: _HD_MONTHS[m] for m in list(_HD_MONTHS)}); _HD_MONTHS["sept"] = 9
_HD_MONTH_NAME = {1: "January", 2: "February", 3: "March", 4: "April", 5: "May", 6: "June",
                  7: "July", 8: "August", 9: "September", 10: "October", 11: "November", 12: "December"}
_HD_MONTHS_RE = "|".join(sorted(_HD_MONTHS, key=len, reverse=True))


def _extract_query_date(q):
    """(year, month, day) if the query carries a date token, else None. Month-token guarded; year->2026 default."""
    ql = (q or "").lower()
    m = re.search(r'\\b(' + _HD_MONTHS_RE + r')\\.?\\s+(\\d{1,2})(?:st|nd|rd|th)?(?:,?\\s+((?:19|20)\\d{2}))?\\b', ql)
    if m:
        return (int(m.group(3)) if m.group(3) else None, _HD_MONTHS[m.group(1)], int(m.group(2)))
    m = re.search(r'\\b((?:19|20)\\d{2})-(\\d{1,2})-(\\d{1,2})\\b', ql)
    if m:
        return (int(m.group(1)), int(m.group(2)), int(m.group(3)))
    return None


def _hd_rrf(lists, k0=60):
    sc = {}
    for L in lists:
        for rank, item in enumerate(L):
            sc[item] = sc.get(item, 0.0) + 1.0 / (k0 + rank)
    return [it for it, _ in sorted(sc.items(), key=lambda kv: -kv[1])]
# === ''' + MARKER + ''' (helpers end) ==============================================


'''

BRANCH = '''
            # === ''' + MARKER + ''' (branch): date-aware hybrid retrieve, flag-gated, date-triggered.
            # Non-date queries and HYBRID_DATE_ENABLED!=true fall through to the unchanged vector path.
            if os.getenv("HYBRID_DATE_ENABLED", "false").lower() == "true":
                _qd = _extract_query_date(query)
                if _qd is not None:
                    try:
                        _hres = await self._retrieve_date_hybrid(query, query_embedding, n_results, _qd, tags)
                        if _hres is not None:
                            return _hres
                    except Exception as _he:
                        logger.warning(f"date-hybrid path failed, falling back to vector: {_he}")
'''

METHOD = '''    # === ''' + MARKER + ''' (method) ===
    async def _retrieve_date_hybrid(self, query, query_embedding, n_results, qd, tags):
        """Date-triggered hybrid retrieve. Exact date INSTANCES via precise content LIKE
        ("Month DD, YYYY"), RRF-fused with the vector pool, fused order FINAL (NO rerank),
        synthesis-tagged memories deprioritized. Returns None to FAIL OPEN to the vector path
        (e.g. a date with no matching instance, or any error)."""
        if tags:
            return None
        y, mo, da = qd
        mn = _HD_MONTH_NAME.get(mo)
        if not mn:
            return None
        qb = serialize_float32(query_embedding)
        POOL = 50
        like_a = f"%{mn} {da:02d}, {y}%" if y else f"%{mn} {da:02d},%"   # year if given, else any year
        like_b = f"%{mn} {da}, {y}%" if y else f"%{mn} {da},%"

        def _gather():
            vec = [r[0] for r in self.conn.execute(
                "SELECT m.content_hash FROM memories m INNER JOIN "
                "(SELECT rowid, distance FROM memory_embeddings WHERE content_embedding MATCH ? AND k = ?) e "
                "ON m.id = e.rowid WHERE m.deleted_at IS NULL ORDER BY e.distance LIMIT ?",
                (qb, POOL, POOL)).fetchall()]
            like = [r[0] for r in self.conn.execute(
                "SELECT m.content_hash FROM memories m JOIN memory_embeddings me ON me.rowid = m.id "
                "WHERE m.deleted_at IS NULL AND (m.content LIKE ? OR m.content LIKE ?) "
                "ORDER BY vec_distance_cosine(me.content_embedding, ?)",
                (like_a, like_b, qb)).fetchall()]
            return vec, like

        vec, like = await self._execute_with_retry(_gather)
        if not like:
            return None
        like_set = set(like)
        window = _hd_rrf([vec, like])[:POOL]
        if not window:
            return None
        ph = ",".join("?" * len(window))

        def _fetch():
            return self.conn.execute(
                f"SELECT m.content_hash, m.content, m.tags, m.memory_type, m.metadata, "
                f"m.created_at, m.updated_at, m.created_at_iso, m.updated_at_iso, "
                f"vec_distance_cosine(me.content_embedding, ?) AS dist "
                f"FROM memories m JOIN memory_embeddings me ON me.rowid = m.id "
                f"WHERE m.content_hash IN ({ph}) AND m.deleted_at IS NULL", (qb, *window)).fetchall()

        rows = await self._execute_with_retry(_fetch)
        by_hash = {r[0]: r for r in rows}

        def _is_synth(r):
            if "status:rolling" in (r[2] or ""):
                return True
            md = self._safe_json_loads(r[4], "date_hybrid_meta") or {}
            return bool(md.get("synthesizes"))

        ordered = [by_hash[h] for h in window if h in by_hash]
        nonsyn = [r for r in ordered if not _is_synth(r)]
        syn = [r for r in ordered if _is_synth(r)]
        final = (nonsyn + syn)[:n_results]

        results = []
        for r in final:
            content_hash, content, tags_str, memory_type, metadata_str = r[:5]
            created_at, updated_at, created_at_iso, updated_at_iso, dist = r[5:]
            tg = [t.strip() for t in tags_str.split(",") if t.strip()] if tags_str else []
            md = self._safe_json_loads(metadata_str, "memory_metadata")
            mem = Memory(content=content, content_hash=content_hash, tags=tg, memory_type=memory_type,
                         metadata=md, created_at=created_at, updated_at=updated_at,
                         created_at_iso=created_at_iso, updated_at_iso=updated_at_iso)
            vec_rel = max(0.0, 1.0 - (float(dist) / 2.0)) if dist is not None else 0.0
            rel = max(vec_rel, 0.95) if content_hash in like_set else vec_rel
            mem.record_access(query)
            results.append(MemoryQueryResult(memory=mem, relevance_score=rel,
                           debug_info={"distance": dist, "backend": "sqlite-vec", "path": "date-hybrid"}))
        try:
            await self._persist_access_metadata_batch([x.memory for x in results])
        except Exception as e:
            logger.warning(f"date-hybrid: persist access failed: {e}")
        logger.info(f"date-hybrid retrieved {len(results)} for date {qd}")
        return results

'''

ANCHOR_HELPERS = "class SqliteVecMemoryStorage(MemoryStorage):"
ANCHOR_BRANCH = ('            if embedding_count == 0:\n'
                 '                logger.warning("No embeddings found in database. Memories may have been stored without embeddings.")\n'
                 '                return []\n')
ANCHOR_METHOD = ('    async def retrieve(self, query: str, n_results: int = 5, '
                 'tags: Optional[List[str]] = None) -> List[MemoryQueryResult]:\n')

def locate_target():
    try:
        import importlib.util
        spec = importlib.util.find_spec("mcp_memory_service.storage.sqlite_vec")
        if spec and spec.origin: return spec.origin
    except Exception: pass
    return None

def set_flag(server_sh):
    txt = open(server_sh).read()
    if "HYBRID_DATE_ENABLED" in txt:
        print(f"  flag already present in {server_sh}"); return
    if "exec memory server" in txt:
        txt = txt.replace("exec memory server",
                          "export HYBRID_DATE_ENABLED=true\nexec memory server", 1)
    else:
        txt = txt.rstrip() + "\nexport HYBRID_DATE_ENABLED=true\n"
    shutil.copy(server_sh, server_sh + f".prepatch_{time.strftime('%Y%m%d_%H%M%S')}")
    open(server_sh, "w").write(txt)
    print(f"  set HYBRID_DATE_ENABLED=true in {server_sh}")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", default=None)
    ap.add_argument("--server-sh", default=None)
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    target = a.target or locate_target()
    if not target or not os.path.exists(target):
        print("ERROR: could not locate storage/sqlite_vec.py (use --target)."); sys.exit(2)
    src = open(target).read()
    if MARKER in src:
        print(f"Already patched ({MARKER} present) — idempotent no-op: {target}")
        if a.server_sh and not a.dry_run: set_flag(a.server_sh)
        return
    for name, anchor in (("helpers", ANCHOR_HELPERS), ("branch", ANCHOR_BRANCH), ("method", ANCHOR_METHOD)):
        if anchor not in src:
            print(f"ERROR: anchor for {name} not found — version mismatch? No changes written."); sys.exit(3)
    out = src.replace(ANCHOR_HELPERS, HELPERS + ANCHOR_HELPERS, 1)
    out = out.replace(ANCHOR_BRANCH, ANCHOR_BRANCH + BRANCH, 1)
    out = out.replace(ANCHOR_METHOD, METHOD + ANCHOR_METHOD, 1)
    tmp = target + ".pieceC.tmp"
    open(tmp, "w").write(out)
    r = subprocess.run([sys.executable, "-m", "py_compile", tmp], capture_output=True, text=True)
    if r.returncode != 0:
        os.remove(tmp); print("ERROR: patched file failed py_compile:\n" + r.stderr); sys.exit(4)
    if a.dry_run:
        os.remove(tmp); print(f"DRY-RUN ok: would patch {target} (+{out.count(chr(10))-src.count(chr(10))} lines)"); return
    bak = target + f".prepatch_{time.strftime('%Y%m%d_%H%M%S')}"
    shutil.copy(target, bak)
    os.replace(tmp, target)
    print(f"PATCHED {target}\n  backup: {bak}")
    if a.server_sh: set_flag(a.server_sh)
    print("  RESTART the service to activate (launchctl unload/load; KeepAlive=true).")

if __name__ == "__main__":
    main()
