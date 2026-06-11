"""Tests for apply_security_hardening.py — the portable app-layer security patch.

Runs the tool against a SYNTHETIC mcp_memory_service tree carrying the exact 10.26.5
anchor lines (CI can't pip-install the real engine). Proves the three patches land,
are idempotent, py_compile, and that a missing MANDATORY anchor aborts with nothing written.
"""
import pathlib
import subprocess
import sys
import textwrap

TOOL = pathlib.Path(__file__).resolve().parents[1] / "apply_security_hardening.py"

DOCUMENTS = (
    "from fastapi import APIRouter, UploadFile, File, Form, HTTPException, BackgroundTasks\n"
    "from pydantic import BaseModel\n"
    "from ..dependencies import get_storage\n"
    "\n"
    "router = APIRouter()\n"
)
MIDDLEWARE = (
    "def get_current_user(request):\n"
    "    if API_KEY:\n"
    "        api_key_header = request.headers.get('X-API-Key')\n"
    "        # Try query parameter as fallback (less secure, but convenient)\n"
    "        api_key_param = request.query_params.get(\"api_key\")\n"
    "        if api_key_param:\n"
    "            return api_key_param\n"
)
APP = (
    "def create_app():\n"
    "    app = FastAPI(\n"
    "        title=\"MCP Memory Service\",\n"
    "        version=__version__,\n"
    "        docs_url=\"/api/docs\",\n"
    "        redoc_url=\"/api/redoc\"\n"
    "    )\n"
    "    return app\n"
)


def _tree(tmp_path):
    base = tmp_path / "sp" / "mcp_memory_service"
    (base / "web" / "api").mkdir(parents=True)
    (base / "web" / "oauth").mkdir(parents=True)
    (base / "web" / "api" / "documents.py").write_text(DOCUMENTS)
    (base / "web" / "oauth" / "middleware.py").write_text(MIDDLEWARE)
    (base / "web" / "app.py").write_text(APP)
    return tmp_path / "sp"


def _run(sp, *extra):
    return subprocess.run([sys.executable, str(TOOL), "--site-packages", str(sp), *extra],
                          capture_output=True, text=True)


def test_all_three_patches_apply(tmp_path):
    sp = _tree(tmp_path)
    r = _run(sp)
    assert r.returncode == 0, r.stdout + r.stderr
    docs = (sp / "mcp_memory_service/web/api/documents.py").read_text()
    mw = (sp / "mcp_memory_service/web/oauth/middleware.py").read_text()
    app = (sp / "mcp_memory_service/web/app.py").read_text()
    # FIX 1
    assert "SEC_DOCAUTH_V1" in docs
    assert "dependencies=[Depends(require_read_access)]" in docs
    assert "BackgroundTasks, Depends" in docs
    assert "from ..oauth.middleware import require_read_access" in docs
    # FIX 3
    assert "SEC_HEADERONLY_V1" in mw
    assert 'request.url.path.startswith("/mcp")' in mw
    # FIX 4
    assert "SEC_NOSCHEMA_V1" in app
    assert "openapi_url=None" in app


def test_idempotent_rerun(tmp_path):
    sp = _tree(tmp_path)
    assert _run(sp).returncode == 0
    r2 = _run(sp)
    assert r2.returncode == 0
    assert "already present" in r2.stdout
    # router line must not be doubly-wrapped
    docs = (sp / "mcp_memory_service/web/api/documents.py").read_text()
    assert docs.count("dependencies=[Depends(require_read_access)]") == 1


def test_patched_files_compile(tmp_path):
    sp = _tree(tmp_path)
    _run(sp)
    for f in ["web/api/documents.py", "web/oauth/middleware.py", "web/app.py"]:
        p = sp / "mcp_memory_service" / f
        c = subprocess.run([sys.executable, "-m", "py_compile", str(p)], capture_output=True, text=True)
        assert c.returncode == 0, f"{f} failed py_compile: {c.stderr}"


def test_dry_run_writes_nothing(tmp_path):
    sp = _tree(tmp_path)
    before = (sp / "mcp_memory_service/web/api/documents.py").read_text()
    r = _run(sp, "--dry-run")
    assert r.returncode == 0
    assert (sp / "mcp_memory_service/web/api/documents.py").read_text() == before


def test_mandatory_anchor_miss_aborts(tmp_path):
    sp = _tree(tmp_path)
    # break ONLY the FIX1 mandatory anchor
    docs = sp / "mcp_memory_service/web/api/documents.py"
    docs.write_text(DOCUMENTS.replace("router = APIRouter()", "router = APIRouter(prefix='/x')"))
    mw_before = (sp / "mcp_memory_service/web/oauth/middleware.py").read_text()
    r = _run(sp)
    assert r.returncode != 0
    assert "FATAL" in r.stdout
    # nothing else should have been written when the mandatory fix aborts
    assert (sp / "mcp_memory_service/web/oauth/middleware.py").read_text() == mw_before


def test_best_effort_anchor_miss_skips_only_that_fix(tmp_path):
    sp = _tree(tmp_path)
    # break only FIX4's anchor; FIX1 + FIX3 must still apply
    app = sp / "mcp_memory_service/web/app.py"
    app.write_text(APP.replace('docs_url="/api/docs",', 'docs_url="/custom",'))
    r = _run(sp)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "SEC_DOCAUTH_V1" in (sp / "mcp_memory_service/web/api/documents.py").read_text()
    assert "WARN (skip)" in r.stdout
    assert "SEC_NOSCHEMA_V1" not in (sp / "mcp_memory_service/web/app.py").read_text()
