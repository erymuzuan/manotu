#!/usr/bin/env python3
"""
Manotu Android release helper (see ../SKILL.md). Steps, in order:

  plan                       read-only: current/next versions, commits since the last tags, preflight checks
  bump  --manotu X           set the manotu flavor's defaults in android/app/build.gradle.kts (versionCode +1),
                             commit "Release Manotu X" on master (does not push)

Only Manotu (my.manotu.app) is released. The legacy my.gimano.app flavor is retired (user decision, 2026-10-24):
it is not built, published or deployed, and its download folder was removed from the website.
  build                      assemble both release APKs from the committed tree, verify, stage under
                             artifacts/release-staging/<flavor>-<ver>/ (APK, .sha256, version.json, notes)
  tag                        tag vX and vY on the bump commit, push master + tags
  github                     create the two GitHub pre-releases from the staged folders
  verify                     public checks of manifests, APK hashes and rollback manifests

Run from the repo root: python3 .claude/skills/release-apk/scripts/release.py <step> ...
"""
import argparse, glob, hashlib, json, os, re, subprocess, sys, urllib.request, random

ROOT = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True).stdout.strip()
GRADLE = os.path.join(ROOT, "android/app/build.gradle.kts")
STAGING = os.path.join(ROOT, "artifacts/release-staging")
SIGNER = "b9baddcd63b3d74b8a374cb93df3278579ba4faeae121c35827d377e210bbec9"  # release key; the installed base needs it
SDK = os.environ.get("ANDROID_HOME", "/opt/homebrew/share/android-commandlinetools")
ENV = dict(os.environ, JAVA_HOME=os.environ.get("JAVA_HOME", "/opt/homebrew/opt/openjdk@17"), ANDROID_HOME=SDK)

FLAVORS = {
    # flavor: (package, staging dir prefix, manifest URL, download folder)
    "manotu": ("my.manotu.app", "manotu", "https://manotu.app/download/version.json", "https://manotu.app/download/"),
}
MIRRORS = {  # same files served from a second host; must stay identical
    "manotu": ["https://www.bukitbunga.com/manotu/download/version.json"],
}


def sh(*cmd, cwd=ROOT, check=True, env=None):
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, env=env)
    if check and r.returncode:
        sys.exit(f"$ {' '.join(cmd)}\n{r.stdout}{r.stderr}")
    return r.stdout.strip()


def tool(name):
    found = sorted(glob.glob(os.path.join(SDK, "build-tools", "*", name)))
    if not found: sys.exit(f"{name} not found under {SDK}/build-tools")
    return found[-1]


def versions():
    src = open(GRADLE, encoding="utf-8").read()
    out = {}
    for f in FLAVORS:
        code = re.search(rf'prop\("{f}\.versionCode", "(\d+)"\)', src)
        name = re.search(rf'prop\("{f}\.versionName", "([^"]+)"\)', src)
        out[f] = (int(code.group(1)), name.group(1))
    return out


def next_patch(v):
    a, b, c = (int(x) for x in v.split("."))
    return f"{a}.{b}.{c + 1}"


def last_tag(prefix):
    tags = sh("git", "tag", "--list", f"v{prefix}.*", "--sort=-v:refname").splitlines()
    return tags[0] if tags else None


def http(url):
    sep = "&" if "?" in url else "?"
    # Cloudflare answers 403 to urllib's default User-Agent.
    req = urllib.request.Request(url + f"{sep}v={random.randrange(1 << 30)}", headers={"User-Agent": "manotu-release-check/1"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read()


def cmd_plan(a):
    v = versions()
    branch = sh("git", "rev-parse", "--abbrev-ref", "HEAD")
    sh("git", "fetch", "-q", "origin")
    behind = sh("git", "rev-list", "--count", "HEAD..origin/master")
    dirty = sh("git", "status", "--porcelain", "--untracked-files=no")
    print(f"branch {branch} (must be master), behind origin/master: {behind}, tracked changes: {'yes' if dirty else 'none'}")
    print(f"keystore.properties: {'present' if os.path.exists(os.path.join(ROOT, 'android/keystore.properties')) else 'MISSING'}")
    for f, (code, name) in v.items():
        print(f"{f}: now {name} ({code}) -> next {next_patch(name)} ({code + 1})")
    since = last_tag(v["manotu"][1].rsplit(".", 1)[0]) or ""
    print(f"\nCommits since {since or 'the beginning'} (raw material for the release notes):")
    rng = f"{since}..HEAD" if since else "HEAD"
    for path, label in (("android", "Android (in the APK)"), ("backend", "Backend (server, not in the APK)")):
        log = sh("git", "log", "--no-merges", "--format=- %h %s", rng, "--", path)
        print(f"\n## {label}\n{log or '(none)'}")


def cmd_bump(a):
    if sh("git", "rev-parse", "--abbrev-ref", "HEAD") != "master": sys.exit("release from master only")
    if sh("git", "status", "--porcelain", "--untracked-files=no"): sys.exit("commit or stash tracked changes first")
    sh("git", "pull", "-q", "--rebase", "origin", "master")
    v = versions()
    src = open(GRADLE, encoding="utf-8").read()
    for f, new in (("manotu", a.manotu),):
        code, name = v[f]
        if [int(x) for x in new.split(".")] <= [int(x) for x in name.split(".")]:
            sys.exit(f"{f}: {new} must be newer than {name}")
        src = src.replace(f'prop("{f}.versionCode", "{code}")', f'prop("{f}.versionCode", "{code + 1}")')
        src = src.replace(f'prop("{f}.versionName", "{name}")', f'prop("{f}.versionName", "{new}")')
    open(GRADLE, "w", encoding="utf-8").write(src)
    nv = versions()
    sh("git", "add", GRADLE)
    sh("git", "commit", "-q", "-m",
       f"Release Manotu {a.manotu} ({nv['manotu'][0]})\n\n"
       "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>")
    print(f"bumped: {nv}; commit {sh('git', 'rev-parse', '--short', 'HEAD')} (not pushed; run build next)")


def verify_apk(apk, flavor):
    pkg, _, manifest_url, _ = FLAVORS[flavor]
    badging = sh(tool("aapt2"), "dump", "badging", apk)
    m = re.search(r"package: name='([^']+)' versionCode='(\d+)' versionName='([^']+)'", badging)
    certs = sh(tool("apksigner"), "verify", "--print-certs", apk,
               env=dict(ENV, PATH=os.path.join(ENV["JAVA_HOME"], "bin") + os.pathsep + ENV.get("PATH", "")))
    sha = re.search(r"certificate SHA-256 digest: ([0-9a-f]+)", certs).group(1)
    dex = subprocess.run(["unzip", "-p", apk, "classes*.dex"], capture_output=True).stdout
    problems = []
    if m.group(1) != pkg: problems.append(f"package {m.group(1)} != {pkg}")
    if sha != SIGNER: problems.append(f"signer {sha[:12]}… is not the release key {SIGNER[:12]}…")
    if manifest_url.encode() not in dex: problems.append(f"update manifest URL {manifest_url} not embedded")
    if problems: sys.exit(f"{apk}: " + "; ".join(problems))
    return int(m.group(2)), m.group(3)


def cmd_build(a):
    if sh("git", "status", "--porcelain", "--untracked-files=no", "--", "android"):
        sys.exit("android/ has uncommitted changes; the APK must equal a commit")
    head = sh("git", "rev-parse", "HEAD")
    sh("./gradlew", "-q", "testManotuDebugUnitTest", "assembleManotuRelease", cwd=os.path.join(ROOT, "android"), env=ENV)
    v = versions()
    for f in FLAVORS:
        code, name = v[f]
        apk = os.path.join(ROOT, f"android/app/build/outputs/apk/{f}/release/manotu-{name}.apk")
        got = verify_apk(apk, f)
        if got != (code, name): sys.exit(f"{f}: APK is {got}, gradle says {(code, name)}")
        out = os.path.join(STAGING, f"{FLAVORS[f][1]}-{name}")
        os.makedirs(out, exist_ok=True)
        dst = os.path.join(out, f"manotu-{name}.apk")
        sh("cp", apk, dst)
        digest = hashlib.sha256(open(dst, "rb").read()).hexdigest()
        open(dst + ".sha256", "w").write(f"{digest}  manotu-{name}.apk\n")
        open(os.path.join(out, "SOURCE"), "w").write(head + "\n")
        print(f"{f}: {name} ({code}) staged at {out}\n  sha256 {digest}\n  signer ok, package ok, manifest URL ok")
    print("\nNext: write notes-en.txt, notes-ms.txt and release.md in each staged folder, then run\n"
          "  android/tools/publish-apk.py --channel <flavor> <apk> --notes-en … --notes-ms … --out <folder>/version.json")


def cmd_tag(a):
    v = versions()
    head = sh("git", "rev-parse", "HEAD")
    for f in FLAVORS:
        src = open(os.path.join(STAGING, f"{FLAVORS[f][1]}-{v[f][1]}", "SOURCE")).read().strip()
        if src != head: sys.exit(f"{f} was built from {src[:7]}, HEAD is {head[:7]}: rebuild")
    for f in FLAVORS:
        sh("git", "tag", "-a", f"v{v[f][1]}", "-m", f"Manotu {v[f][1]} ({v[f][0]})")
    sh("git", "pull", "-q", "--rebase", "origin", "master")
    if sh("git", "rev-parse", "HEAD") != head: sys.exit("master moved during the release; tags point at the bump commit, re-check before pushing")
    sh("git", "push", "-q", "origin", "master", f"v{v['manotu'][1]}")
    print(f"pushed master and tag v{v['manotu'][1]} at {head[:7]}")


def cmd_github(a):
    v = versions()
    titles = {"manotu": "Manotu {n} for Android"}
    for f in titles:
        name = v[f][1]
        d = os.path.join(STAGING, f"{FLAVORS[f][1]}-{name}")
        for need in ("release.md", "version.json", f"manotu-{name}.apk", f"manotu-{name}.apk.sha256"):
            if not os.path.exists(os.path.join(d, need)): sys.exit(f"missing {d}/{need}")
        url = sh("gh", "release", "create", f"v{name}", "--repo", "erymuzuan/manotu", "--verify-tag", "--prerelease",
                 "--title", titles[f].format(n=name), "--notes-file", os.path.join(d, "release.md"),
                 os.path.join(d, f"manotu-{name}.apk"), os.path.join(d, f"manotu-{name}.apk.sha256"),
                 os.path.join(d, "version.json"))
        print(url)


def cmd_verify(a):
    v = versions()
    ok = True
    for f, (pkg, prefix, manifest, folder) in FLAVORS.items():
        name = v[f][1]
        staged = json.load(open(os.path.join(STAGING, f"{prefix}-{name}", "version.json")))
        for url in [manifest] + MIRRORS[f]:
            live = json.loads(http(url))
            good = live.get("versionName") == name and live.get("sha256") == staged["sha256"]
            ok &= good
            print(f"{'OK ' if good else 'BAD'} {url}: {live.get('versionName')} ({live.get('versionCode')})")
        digest = hashlib.sha256(http(staged["apkUrl"])).hexdigest()
        good = digest == staged["sha256"]
        ok &= good
        print(f"{'OK ' if good else 'BAD'} {staged['apkUrl']} sha256 {digest[:12]}…")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    sp = ap.add_subparsers(dest="step", required=True)
    sp.add_parser("plan")
    b = sp.add_parser("bump"); b.add_argument("--manotu", required=True)
    for s in ("build", "tag", "github", "verify"): sp.add_parser(s)
    a = ap.parse_args()
    globals()[f"cmd_{a.step}"](a)
