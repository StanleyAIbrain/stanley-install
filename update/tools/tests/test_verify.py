"""Phase-1 (M0) regression tests for update/tools/verify.py.

All data here is synthetic (Northwind-style) — nothing from any live brain.
The functional tests run verify.py as a subprocess against a throwaway
sqlite_vec DB, exactly as an operator would.
"""
import importlib.util
import pathlib
import sqlite3
import struct
import subprocess
import sys

import pytest

TOOLS = pathlib.Path(__file__).resolve().parents[1]
VERIFY = TOOLS / "verify.py"

spec = importlib.util.spec_from_file_location("verify_mod", VERIFY)
verify_mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify_mod)


# ---------- unit: the May KeyError + Sept-shadow bugs (Phase-0 F.1, Bug A) ----------

def test_mname_has_all_twelve_months():
    assert sorted(verify_mod._MNAME) == list(range(1, 13))

def test_may_resolves():
    # the exact lookup chain from verify.py date_path() that raised KeyError(5)
    assert verify_mod._MNAME[verify_mod._MONTHS["may"]] == "May"

def test_september_is_full_name_not_sept():
    # "sept" abbreviation must not shadow the full name (LIKE '%Sept 03,%'
    # never matches content "September 03, 2026")
    assert verify_mod._MNAME[verify_mod._MONTHS["september"]] == "September"
    assert verify_mod._MNAME[verify_mod._MONTHS["sept"]] == "September"

def test_every_month_token_resolves_to_full_name():
    full_names = {m.capitalize() for m in verify_mod._FULL_MONTHS}
    for tok, num in verify_mod._MONTHS.items():
        name = verify_mod._MNAME[num]  # must not raise for any accepted token
        assert name in full_names

def test_datepat_matches_may_dates():
    m = verify_mod._DATEPAT.search("backup completed on May 12, 2026 at noon")
    assert m and m.group(2) == "12" and m.group(3) == "2026"

def test_is_date_token():
    assert verify_mod.is_date_token("may-12-2026")
    assert verify_mod.is_date_token("2026-05-12")
    assert not verify_mod.is_date_token("project:alpha")


# ---------- functional: full gate run on a synthetic DB ----------

def _make_db(path, n=6, deleted=0):
    import sqlite_vec
    con = sqlite3.connect(path)
    con.enable_load_extension(True)
    sqlite_vec.load(con)
    con.enable_load_extension(False)
    con.execute("create table memories (id integer primary key, content_hash text,"
                " content text, tags text, metadata text, deleted_at real)")
    con.execute("create virtual table memory_embeddings using vec0(content_embedding float[384])")
    rows = []
    for i in range(1, n + 1):
        # undated synthetic content -> the date-path gate cleanly skips, so the
        # functional test needs no embedding model download in CI
        rows.append((i, f"hash{i:04d}", f"Northwind supplier record number {i} for testing",
                     "project:northwind,type:reference", "{}", None))
    for i in range(n + 1, n + 1 + deleted):
        rows.append((i, f"hash{i:04d}", f"deleted Northwind record {i}",
                     "project:northwind", "{}", 1234567890.0))
    con.executemany("insert into memories values (?,?,?,?,?,?)", rows)
    for i, *_ in rows:
        vec = [((i * 31 + j) % 97) / 97.0 for j in range(384)]
        con.execute("insert into memory_embeddings(rowid, content_embedding) values (?, ?)",
                    (i, struct.pack("384f", *vec)))
    con.commit()
    con.close()

def _run_verify(db, *args):
    return subprocess.run([sys.executable, str(VERIFY), "--db", str(db), *args],
                          capture_output=True, text=True)

def test_gates_pass_on_clean_synthetic_db(tmp_path):
    db = tmp_path / "synth.db"
    _make_db(db, n=6)
    r = _run_verify(db, "--expect-count", "6")
    assert r.returncode == 0, r.stdout + r.stderr
    assert "ALL GATES PASS" in r.stdout

def test_zero_deletion_gate_catches_count_mismatch(tmp_path):
    db = tmp_path / "synth.db"
    _make_db(db, n=6, deleted=1)  # 6 active, 1 soft-deleted
    r = _run_verify(db, "--expect-count", "7")  # expecting 7 active -> must FAIL
    assert r.returncode == 1
    assert "GATES FAILED" in r.stdout

def test_soft_deleted_rows_are_excluded(tmp_path):
    db = tmp_path / "synth.db"
    _make_db(db, n=5, deleted=2)
    r = _run_verify(db, "--expect-count", "5")
    assert r.returncode == 0, r.stdout + r.stderr
