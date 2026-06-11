#!/usr/bin/env python3
"""
apply_security_hardening.py — portable security hardening for mcp-memory-service 10.26.5.

Backports three app-layer fixes into the INSTALLED package so every island enforces
them itself, with no dependency on edge (Cloudflare WAF/Access) config:

  FIX 1 (SEC_DOCAUTH_V1, MANDATORY) — the documents router ships with NO auth dependency
      (every other router has one). Add a router-level Depends(require_read_access) so
      /api/documents/* refuses no-key requests like every other data route. A valid API
      key carries "read write admin", so all legitimate callers are unaffected.
  FIX 3 (SEC_HEADERONLY_V1, best-effort) — stop honoring the ?api_key= query parameter on
      /api/* data routes (key-in-URL = key-in-logs). The /mcp connector legitimately uses
      /mcp?api_key=, so query-param auth is preserved for /mcp paths only.
  FIX 4 (SEC_NOSCHEMA_V1, best-effort) — disable the public OpenAPI schema + interactive
      docs (/openapi.json, /api/docs, /api/redoc) so the full route map + version aren't
      handed to anyone mapping the surface.

Discipline (mirrors apply_pieceC.py): idempotent (markers), anchor-checked, py_compile
verified, timestamped per-file backups, all-or-nothing per file. FIX 1 is mandatory: if
its anchors are missing (version drift) the tool writes NOTHING and exits non-zero. FIX 3/4
are best-effort: a missing anchor logs a loud warning and skips THAT fix only, so the
critical fix still lands.

Target: mcp-memory-service 10.26.5. Rollback: restore the printed .presec_* backups, restart.

Usage: python3 apply_security_hardening.py [--site-packages /path] [--dry-run]
"""
import argparse, importlib.util, os, shutil, subprocess, sys, time

def locate(mod):
    try:
        spec = importlib.util.find_spec(mod)
        if spec and spec.origin:
            return spec.origin
    except Exception:
        return None
    return None

# ---- FIX 1: documents router auth (MANDATORY) ----
DOC_MARK = "SEC_DOCAUTH_V1"
DOC_EDITS = [
    # (anchor, replacement)
    ("from fastapi import APIRouter, UploadFile, File, Form, HTTPException, BackgroundTasks",
     "from fastapi import APIRouter, UploadFile, File, Form, HTTPException, BackgroundTasks, Depends"),
    ("from ..dependencies import get_storage",
     "from ..dependencies import get_storage\nfrom ..oauth.middleware import require_read_access  # " + DOC_MARK),
    ("router = APIRouter()",
     "router = APIRouter(dependencies=[Depends(require_read_access)])  # " + DOC_MARK
     + " — gate every documents route behind a valid key (key grants read+write+admin)"),
]

# ---- FIX 3: header-only key auth on /api/* (best-effort) ----
HDR_MARK = "SEC_HEADERONLY_V1"
HDR_ANCHOR = ('        # Try query parameter as fallback (less secure, but convenient)\n'
              '        api_key_param = request.query_params.get("api_key")\n')
HDR_REPLACE = ('        # ' + HDR_MARK + ': query-param key honored ONLY for the /mcp connector\n'
               '        # (claude.ai needs /mcp?api_key=); never for /api/* data routes (key-in-URL = key-in-logs).\n'
               '        api_key_param = request.query_params.get("api_key") if request.url.path.startswith("/mcp") else None\n')

# ---- FIX 4: disable public schema + docs (best-effort) ----
SCHEMA_MARK = "SEC_NOSCHEMA_V1"
SCHEMA_ANCHOR = ('        docs_url="/api/docs",\n'
                 '        redoc_url="/api/redoc"\n')
SCHEMA_REPLACE = ('        openapi_url=None,  # ' + SCHEMA_MARK + ': schema + interactive docs off on the public surface\n'
                  '        docs_url=None,\n'
                  '        redoc_url=None\n')


def patch_file(path, mark, edits, mandatory, dry):
    """edits: list of (anchor, replacement). Returns True if applied, False if skipped (already
    patched or best-effort anchor miss). Exits non-zero on a mandatory anchor miss / compile fail."""
    if not path or not os.path.exists(path):
        msg = f"  [{mark}] target not found: {path}"
        if mandatory:
            print("FATAL " + msg); sys.exit(2)
        print("WARN (skip) " + msg); return False
    src = open(path).read()
    if mark in src:
        print(f"  [{mark}] already present — idempotent no-op ({os.path.basename(path)})")
        return False
    for anchor, _ in edits:
        if anchor not in src:
            m = f"  [{mark}] anchor not found in {os.path.basename(path)} (version drift?): {anchor[:60]!r}"
            if mandatory:
                print("FATAL " + m + "\n  -> wrote NOTHING. This is the critical fix; aborting."); sys.exit(3)
            print("WARN (skip) " + m); return False
    out = src
    for anchor, repl in edits:
        out = out.replace(anchor, repl, 1)
    tmp = path + ".sec.tmp"
    open(tmp, "w").write(out)
    r = subprocess.run([sys.executable, "-m", "py_compile", tmp], capture_output=True, text=True)
    if r.returncode != 0:
        os.remove(tmp)
        print(f"FATAL [{mark}] patched file failed py_compile:\n{r.stderr}")
        sys.exit(4)
    if dry:
        os.remove(tmp)
        print(f"  [{mark}] DRY-RUN ok — would patch {os.path.basename(path)} (+{out.count(chr(10))-src.count(chr(10))} lines)")
        return True
    bak = path + f".presec_{time.strftime('%Y%m%d_%H%M%S')}"
    shutil.copy(path, bak)
    os.replace(tmp, path)
    print(f"  [{mark}] PATCHED {os.path.basename(path)}  (backup: {os.path.basename(bak)})")
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--site-packages", default=None,
                    help="package root override (default: auto-locate the importable mcp_memory_service)")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    if a.site_packages:
        base = os.path.join(a.site_packages, "mcp_memory_service")
        docs = os.path.join(base, "web/api/documents.py")
        mw = os.path.join(base, "web/oauth/middleware.py")
        app = os.path.join(base, "web/app.py")
    else:
        docs = locate("mcp_memory_service.web.api.documents")
        mw = locate("mcp_memory_service.web.oauth.middleware")
        app = locate("mcp_memory_service.web.app")

    print("Security hardening (mcp-memory-service 10.26.5):")
    applied = []
    # FIX 1 — MANDATORY
    if patch_file(docs, DOC_MARK, DOC_EDITS, mandatory=True, dry=a.dry_run):
        applied.append("FIX1-documents-auth")
    # FIX 3 — best-effort
    if patch_file(mw, HDR_MARK, [(HDR_ANCHOR, HDR_REPLACE)], mandatory=False, dry=a.dry_run):
        applied.append("FIX3-header-only")
    # FIX 4 — best-effort
    if patch_file(app, SCHEMA_MARK, [(SCHEMA_ANCHOR, SCHEMA_REPLACE)], mandatory=False, dry=a.dry_run):
        applied.append("FIX4-no-schema")

    print(f"\n  applied: {applied or '(none — all already present)'}")
    print("  RESTART the service to activate (launchctl unload/load; KeepAlive=true).")
    if "FIX1-documents-auth" not in applied:
        # not fatal if it was already present (idempotent re-run); fatal cases already exited above
        print("  note: FIX1 not freshly applied this run (already patched, or dry-run).")

if __name__ == "__main__":
    main()
