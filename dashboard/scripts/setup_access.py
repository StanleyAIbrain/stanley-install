#!/usr/bin/env python3
"""Create an OTP-only Cloudflare Access application + email allow-policy for the
dashboard hostname, and print its AUD.

Designed to NEVER produce the org_internal-Google trap: the app is pinned to the
One-time PIN identity provider from the moment of creation (allowed_idps=[otp],
auto_redirect_to_identity=True) — there is no window where Google is offered.

Idempotent: if an app already exists for the hostname, prints its existing AUD.

Env:   CF_ACCOUNT_ID, CF_API_TOKEN  (token needs Access: Apps and Policies: Edit)
Args:  --hostname <dashboard.your-domain>  --email <allow email>  --otp-idp <idp id>
Stdout: a single line  AUD=<value>  on success (plus '# ...' info comments).
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.request

API = "https://api.cloudflare.com/client/v4"
ACCT = os.environ["CF_ACCOUNT_ID"]
TOKEN = os.environ["CF_API_TOKEN"]


def call(method, path, body=None):
    req = urllib.request.Request(
        f"{API}{path}",
        data=json.dumps(body).encode() if body is not None else None,
        method=method,
    )
    req.add_header("Authorization", f"Bearer {TOKEN}")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        return json.load(e)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hostname", required=True)
    ap.add_argument("--email", required=True)
    ap.add_argument("--otp-idp", required=True)
    a = ap.parse_args()

    # Idempotent guard — don't create a second app for the same hostname.
    apps = call("GET", f"/accounts/{ACCT}/access/apps")
    for app in apps.get("result") or []:
        if app.get("domain") == a.hostname:
            print(f"# app already exists id={app['id']}")
            print("AUD=" + app["aud"])
            return

    # Create the app, OTP-only from birth (no Google ever).
    body = {
        "name": f"Brain Dashboard ({a.hostname})",
        "domain": a.hostname,
        "type": "self_hosted",
        "session_duration": "24h",
        "app_launcher_visible": True,
        "allowed_idps": [a.otp_idp],
        "auto_redirect_to_identity": True,
    }
    res = call("POST", f"/accounts/{ACCT}/access/apps", body)
    if not res.get("success"):
        print("APP CREATE FAILED:", json.dumps(res.get("errors")), file=sys.stderr)
        sys.exit(1)
    app = res["result"]
    print(f"# app created id={app['id']}")

    # Single allow policy: the owner's email only.
    pol = {
        "name": "Allow owner email",
        "decision": "allow",
        "include": [{"email": {"email": a.email}}],
    }
    rp = call("POST", f"/accounts/{ACCT}/access/apps/{app['id']}/policies", pol)
    if not rp.get("success"):
        print("POLICY CREATE FAILED:", json.dumps(rp.get("errors")), file=sys.stderr)
        sys.exit(1)

    print("AUD=" + app["aud"])


if __name__ == "__main__":
    main()
