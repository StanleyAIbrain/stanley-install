# sitecustomize.py — access-log secret redaction shim (v1.5.7)
#
# WHY: the HTTP access log wrote API keys in plaintext (connector requests pass
# the key as ?api_key=...). This shim attaches a logging.Filter to uvicorn's
# loggers BEFORE uvicorn configures logging (Python auto-imports sitecustomize
# at interpreter start when this directory is on PYTHONPATH — wired in
# memory-server.sh). logging.config.dictConfig clears handlers but NOT
# logger-level filters, so the filter survives uvicorn's own setup.
#
# SAFETY SPINE: this changes ONLY what is written to the log. It never touches
# request handling — auth still authenticates, invalid keys still 401. Every
# code path is exception-safe: the worst possible failure is "no redaction",
# never "no serving". Zero engine source bytes are modified.
#
# Scope: redacts the VALUE of api_key (and defense-in-depth: any query/kv param
# named like key/token/secret/password) in log message text and args.
# Method, path, status code, and timing remain intact for debuggability.

try:
    import logging
    import re

    _PAT = re.compile(
        r'\b((?:api_key|apikey|api-key|key|access_token|token|secret|password)=)'
        r'([^&\s"\']+)',
        re.IGNORECASE,
    )

    def _scrub(text):
        try:
            return _PAT.sub(r'\1REDACTED', text)
        except Exception:
            return text

    class _RedactSecretsFilter(logging.Filter):
        def filter(self, record):
            try:
                if record.args:
                    if isinstance(record.args, tuple):
                        record.args = tuple(
                            _scrub(a) if isinstance(a, str) else a for a in record.args
                        )
                    elif isinstance(record.args, dict):
                        record.args = {
                            k: (_scrub(v) if isinstance(v, str) else v)
                            for k, v in record.args.items()
                        }
                if isinstance(record.msg, str) and "=" in record.msg:
                    record.msg = _scrub(record.msg)
            except Exception:
                pass  # never break logging, never break the request
            return True  # always allow the (now scrubbed) record through

    _f = _RedactSecretsFilter()
    for _name in ("uvicorn.access", "uvicorn.error", "uvicorn"):
        logging.getLogger(_name).addFilter(_f)
except Exception:
    pass  # a broken shim must never prevent the server from starting
