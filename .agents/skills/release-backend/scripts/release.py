#!/usr/bin/env python3
"""Manotu backend release helper: what is in a release, and public checks after the deploy.

  release.py plan [--since <sha deployed on .150>] [--to origin/master]
  release.py verify [--expect "POST /api/v1/drops 401"] ...

Run from the repo root. It never builds, pushes or deploys anything: WS556 builds, WS556-SERVER deploys.
"""
import argparse, subprocess, sys, urllib.error, urllib.request

HOSTS = ["https://gimano-api.bukitbunga.com", "https://api.manotu.app"]
IN_IMAGE = ["backend", "deploy/Dockerfile.api", "deploy/Dockerfile.worker", "deploy/Dockerfile.importer", "data/moderation"]
ON_SERVER = ["deploy/docker-compose.prod.yml", "deploy/.env.prod.example", "data/tolls"]


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout.strip()


def plan(a):
    git("fetch", "--quiet", "origin")
    to = git("rev-parse", "--short", a.to)
    print(f"Release candidate: {a.to} = {to}  (build-push tags the images :{to})")
    rng = f"{a.since}..{a.to}" if a.since else None
    if not rng:
        print("No --since given: ask the deploy session for the current TAG in deploy/.env.prod on .150.\n"
              "Showing the last 15 commits that change the images instead.")
    log = git("log", "--oneline", "--no-merges", *([rng] if rng else ["-15", a.to]), "--", *IN_IMAGE)
    print("\nIn the images:\n" + (log or "  (nothing: no image rebuild needed)"))
    if not rng:
        return
    srv = git("log", "--oneline", "--no-merges", rng, "--", *ON_SERVER)
    print("\nServer files (git pull on .150 picks these up):\n" + (srv or "  (none)"))
    migs = [f for f in git("diff", "--name-only", "--diff-filter=A", rng, "--", "backend/src/Gimano.Core/Data/Migrations").splitlines()
            if f.endswith(".cs") and not f.endswith((".Designer.cs", "Snapshot.cs"))]
    print("\nNew migrations:" + ("".join(f"\n  {m}" for m in migs) + "\n  → pg_dump on .150 BEFORE the new image starts (it migrates on start)." if migs else " none"))
    env = [l[1:] for l in git("diff", rng, "--", "deploy/.env.prod.example").splitlines() if l.startswith("+") and not l.startswith("+++")]
    if env:
        print("\nNew/changed lines in .env.prod.example (set them in deploy/.env.prod on .150 if needed):\n  " + "\n  ".join(env))


def get(method, url):
    # Cloudflare blocks Python's default user agent; an empty octet-stream body gets past the 415 to the auth check.
    req = urllib.request.Request(url, method=method, data=b"" if method in ("POST", "PUT") else None,
                                 headers={"User-Agent": "manotu-release-check", "Content-Type": "application/octet-stream"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, r.read(400).decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read(400).decode("utf-8", "replace")
    except Exception as e:  # DNS, TLS, timeout
        return 0, str(e)


def verify(a):
    ok = True
    for host in HOSTS:
        for path, want in [("/healthz", 200), ("/readyz", 200)]:
            s, body = get("GET", host + path)
            good = s == want and ("Unhealthy" not in body)
            ok &= good
            print(f"{'OK  ' if good else 'FAIL'} GET {host}{path} → {s} {body[:160].strip()}")
        for e in a.expect:
            method, path, want = e.split()
            s, _ = get(method, host + path)
            good = s == int(want)
            ok &= good
            print(f"{'OK  ' if good else 'FAIL'} {method} {host}{path} → {s} (want {want})")
    sys.exit(0 if ok else 1)


p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
sub = p.add_subparsers(dest="cmd", required=True)
pp = sub.add_parser("plan"); pp.add_argument("--since"); pp.add_argument("--to", default="origin/master"); pp.set_defaults(fn=plan)
pv = sub.add_parser("verify"); pv.add_argument("--expect", action="append", default=[], help='"METHOD /path status", e.g. "POST /api/v1/drops 401"'); pv.set_defaults(fn=verify)
a = p.parse_args()
a.fn(a)
