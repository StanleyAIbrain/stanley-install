"""Phase-1 (M1) tests for update/tools/rollback.sh path/port derivation.

rollback.sh must derive the HTTP port and DB path from the install's own
launch script (memory-server.sh) instead of hardcoding the Everest layout.
"""
import pathlib
import subprocess

TOOLS = pathlib.Path(__file__).resolve().parents[1]
ROLLBACK = TOOLS / "rollback.sh"


def _config(env_extra, tmp_path, server_sh_body=None):
    server_sh = tmp_path / "memory-server.sh"
    if server_sh_body is not None:
        server_sh.write_text(server_sh_body)
    env = {"HOME": str(tmp_path), "PATH": "/usr/bin:/bin",
           "SERVER_SH": str(server_sh), "VENV_PY": "/nonexistent-venv-python"}
    env.update(env_extra)
    r = subprocess.run(["bash", str(ROLLBACK), "config"],
                       capture_output=True, text=True, env=env)
    assert r.returncode == 0, r.stderr
    return dict(line.split("=", 1) for line in r.stdout.strip().splitlines() if "=" in line)


def test_syntax_ok():
    r = subprocess.run(["bash", "-n", str(ROLLBACK)], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr


def test_derives_port_and_db_from_launch_script(tmp_path):
    cfg = _config({}, tmp_path, server_sh_body=(
        "#!/bin/bash\n"
        'export MCP_HTTP_PORT=9123\n'
        'export MCP_MEMORY_BASE_DIR="/srv/island/mcp-memory"\n'
        "exec python -m mcp_memory_service\n"))
    assert cfg["PORT"] == "9123"
    assert cfg["DB"] == "/srv/island/mcp-memory/sqlite_vec.db"


def test_falls_back_to_stock_defaults_without_launch_script(tmp_path):
    cfg = _config({}, tmp_path, server_sh_body=None)  # SERVER_SH does not exist
    assert cfg["PORT"] == "8765"
    assert cfg["DB"].endswith("Library/Application Support/mcp-memory/sqlite_vec.db")


def test_env_overrides_beat_launch_script(tmp_path):
    cfg = _config({"PORT": "7777", "DB": "/custom/path.db"}, tmp_path, server_sh_body=(
        "#!/bin/bash\nexport MCP_HTTP_PORT=9123\n"))
    assert cfg["PORT"] == "7777"
    assert cfg["DB"] == "/custom/path.db"
