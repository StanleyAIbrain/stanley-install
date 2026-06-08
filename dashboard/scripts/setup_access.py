#!/usr/bin/env python3
"""Create or normalize an OTP-only Cloudflare Access application + a single
owner-email allow policy for the dashboard hostname, and print its AUD.

Hardened:
 * OTP-only from birth (allowed_idps=[otp], auto_redirect=True) — no Google, ever
   (Google org_internal would hard-block a personal Gmail).
 * Idempotent (FIX 5): an existing app for the hostname is normalized in place —
   idps + policy re-asserted — never duplicated.
 * Post-condition guard (FIX 4): after create/normalize, re-fetch the live config
   and assert allowed_idps == [otp] (so Google is absent); self-heals once on drift.

Env:   CF_ACCOUNT_ID, CF_API_TOKEN   (token needs Access: Apps and Policies: Edit)
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
# Fields Cloudflare manages / rejects on PUT — never echo them back.
READONLY = {"id", "aud", "created_at", "updated_at", "uid", "policies", "scim_config"}


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


def find_app(hostname):
    apps = call("GET", f"/accounts/{ACCT}/access/apps")
    for a in apps.get("result") or []:
        if a.get("domain") == hostname:
            return a
    return None


def set_otp_only(app_id, app, otp):
    body = {k: v for k, v in app.items() if k not in READONLY}
    body["allowed_idps"] = [otp]
    body["auto_redirect_to_identity"] = True
    return call("PUT", f"/accounts/{ACCT}/access/apps/{app_id}", body)


def ensure_policy(app_id, email):
    want = {
        "name": "Allow owner email",
        "decision": "allow",
        "include": [{"email": {"email": email}}],
    }
    pols = call("GET", f"/accounts/{ACCT}/access/apps/{app_id}/policies").get("result") or []
    if pols:  # update the first policy in place (idempotent)
        return call("PUT", f"/accounts/{ACCT}/access/apps/{app_id}/policies/{pols[0]['id']}", want)
    return call("POST", f"/accounts/{ACCT}/access/apps/{app_id}/policies", want)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hostname", required=True)
    ap.add_argument("--email", required=True)
    ap.add_argument("--otp-idp", required=True)
    a = ap.parse_args()

    app = find_app(a.hostname)
    if app:
        print(f"# existing app id={app['id']} — normalizing in place")
        r = set_otp_only(app["id"], app, a.otp_idp)
        if not r.get("success"):
            print("APP UPDATE FAILED:", json.dumps(r.get("errors")), file=sys.stderr)
            sys.exit(1)
        app_id, aud = app["id"], app["aud"]
    else:
        body = {
            "name": f"Brain Dashboard ({a.hostname})",
            "domain": a.hostname,
            "type": "self_hosted",
            "session_duration": "24h",
            "app_launcher_visible": True,
            "allowed_idps": [a.otp_idp],
            "auto_redirect_to_identity": True,
        }
        r = call("POST", f"/accounts/{ACCT}/access/apps", body)
        if not r.get("success"):
            print("APP CREATE FAILED:", json.dumps(r.get("errors")), file=sys.stderr)
            sys.exit(1)
        app_id, aud = r["result"]["id"], r["result"]["aud"]
        print(f"# app created id={app_id}")

    rp = ensure_policy(app_id, a.email)
    if not rp.get("success"):
        print("POLICY FAILED:", json.dumps(rp.get("errors")), file=sys.stderr)
        sys.exit(1)

    # FIX 4 — post-condition guard: OTP-only, Google absent. Self-heal once on drift.
    cur = call("GET", f"/accounts/{ACCT}/access/apps/{app_id}")["result"]
    if cur.get("allowed_idps") != [a.otp_idp]:
        set_otp_only(app_id, cur, a.otp_idp)
        cur = call("GET", f"/accounts/{ACCT}/access/apps/{app_id}")["result"]
    if cur.get("allowed_idps") != [a.otp_idp]:
        print("GUARD FAILED: could not enforce OTP-only login; allowed_idps=",
              cur.get("allowed_idps"), file=sys.stderr)
        sys.exit(1)

    print("AUD=" + aud)


if __name__ == "__main__":
    main()
