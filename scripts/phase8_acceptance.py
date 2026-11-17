#!/usr/bin/env python3
"""Phase 8 acceptance checks (CI config, docs, release notes, no committed keys).

Usage: python3 scripts/phase8_acceptance.py [--root DIR] [--only ci,readme,docs,arch,keys]
Exits non-zero on any failure. Swift build/test/lint are covered by `make check`, not here.
"""
import argparse
import re
import subprocess
import sys
from pathlib import Path

import yaml

FAILS: list[str] = []
SHA = re.compile(r"^[^@\s]+@[0-9a-f]{40}$")
KEY_PATTERNS = [r"sk-ant-[A-Za-z0-9_-]{10,}", r"\bsk-[A-Za-z0-9]{32,}", r"\bAKIA[0-9A-Z]{16}\b", r"\bghp_[A-Za-z0-9]{30,}"]


def check(cond, msg):
    print(("PASS " if cond else "FAIL ") + msg)
    if not cond:
        FAILS.append(msg)


def md_links(path: Path):
    """Relative link targets in a Markdown file (no URLs, no pure anchors)."""
    for target in re.findall(r"\]\(([^)\s]+)\)", path.read_text()):
        if not re.match(r"^[a-z]+:", target) and not target.startswith("#"):
            yield target.split("#")[0]


def check_links(path: Path):
    for t in md_links(path):
        check((path.parent / t).exists(), f"{path.name}: link '{t}' resolves")


def steps_text(job):
    return "\n".join(str(s.get("run", "")) for s in job.get("steps", []))


def ci(root: Path):
    wf = yaml.safe_load((root / ".github/workflows/ci.yml").read_text())
    jobs = wf.get("jobs", {})
    for name in ["lint", "macos", "linux", "ios", "live"]:
        check(name in jobs, f"ci: job '{name}' exists")
    check(wf.get("permissions") == {"contents": "read"}, "ci: top-level permissions are contents: read")
    for jid, job in jobs.items():
        for s in job.get("steps", []):
            if "uses" in s:
                check(bool(SHA.match(s["uses"])), f"ci: {jid} '{s['uses']}' pinned to a commit SHA")
            if "secrets." in str(s.get("run", "")):
                check(False, f"ci: {jid} interpolates secrets inside run: (use env:)")
    for jid in ["macos", "linux"]:
        txt = steps_text(jobs.get(jid, {}))
        check("swift test" in txt and "-warnings-as-errors" in txt, f"ci: {jid} runs swift test with -warnings-as-errors")
    ios = steps_text(jobs.get("ios", {}))
    check(re.search(r"xcodebuild\b[^\n]*\btest\b", ios.replace("\n", " ")) is not None, "ci: ios runs xcodebuild test")
    check(re.search(r"(?<!generic/)platform=iOS Simulator,(name|id|OS)=", ios) is not None, "ci: ios tests on a concrete iOS Simulator destination")
    for target in ["AgentHarnessKitTests", "AgentHarnessKitALMTests"]:
        check(f"-only-testing:{target}" in ios, f"ci: ios runs {target}")
    check(ios.count("-skipMacroValidation") >= 2, "ci: ios build and test both pass -skipMacroValidation")

    live = jobs.get("live", {})
    raw = yaml.safe_dump(live)
    check("secrets.AHK_LIVE_BASE_URL" in raw, "ci: live job reads secrets.AHK_LIVE_BASE_URL")
    txt = steps_text(live)
    check("LiveEndpointTests" in txt, "ci: live job runs LiveEndpointTests only")
    check("swift:6.3" in txt and "docker" in txt, "ci: live job covers Linux (swift:6.3)")
    check("-e AHK_LIVE_BASE_URL" in txt, "ci: live Linux passes AHK_LIVE_BASE_URL into the container by name")
    check("TEST_RUNNER_AHK_LIVE_BASE_URL" in raw, "ci: live job covers iOS via TEST_RUNNER_ env")
    runs_on = yaml.safe_dump(live.get("runs-on", "")) + yaml.safe_dump(live.get("strategy", {}))
    check("macos" in runs_on, "ci: live job covers macOS")
    for s in live.get("steps", []):
        if "LiveEndpointTests" in str(s.get("run", "")):
            guard = str(s.get("if", "")) + str(live.get("if", ""))
            check("AHK_LIVE_BASE_URL" in guard, f"ci: live step '{s.get('name', '?')}' skipped when secret is absent")


def readme(root: Path):
    p = root / "README.md"
    check(p.exists(), "readme: README.md exists")
    if not p.exists():
        return
    text = p.read_text()
    products = re.findall(r'\.library\(name: "([^"]+)"', (root / "Package.swift").read_text())
    for prod in products:
        check(prod in text, f"readme: mentions product {prod}")
    for word in ["Swift 6.3", "macOS", "iOS", "Linux", ".package(url:", "MLX", "AHK_LIVE_BASE_URL",
                 "make check", "-skipMacroValidation", "docs/README.md", "CHANGELOG.md"]:
        check(word in text, f"readme: contains '{word}'")
    check_links(p)
    # Every type named in a Swift code sample must exist in Sources/.
    sources = "\n".join(f.read_text() for f in (root / "Sources").rglob("*.swift"))
    for block in re.findall(r"```swift\n(.*?)```", text, re.S):
        if ".package(url:" in block:
            continue
        for ident in set(re.findall(r"\b([A-Z][A-Za-z0-9]+)(?=[(<.])", block)):
            if ident in {"String", "Int", "URL", "Double", "Bool", "Codable", "ProcessInfo", "Task", "Array"}:
                continue
            ok = re.search(rf"\b(struct|class|enum|protocol|actor|typealias|func|case)\s+{ident}\b", sources)
            check(ok or ident in {"OpenAILanguageModel", "AnthropicLanguageModel", "GenerationOptions"},
                  f"readme: sample type '{ident}' exists in Sources/ or ALM")


def docs(root: Path):
    idx = root / "docs/README.md"
    check(idx.exists(), "docs: docs/README.md exists")
    if idx.exists():
        linked = {(idx.parent / t).resolve() for t in md_links(idx)}
        for md in (root / "docs").rglob("*.md"):
            if md != idx:
                check(md.resolve() in linked, f"docs: index links {md.relative_to(root)}")
        for top in ["ROADMAP.md", "AGENTHARNESSKIT_PARITY_SPEC.md", "CHANGELOG.md", "README.md"]:
            check((root / top).resolve() in linked, f"docs: index links {top}")
        check_links(idx)
    cl = root / "CHANGELOG.md"
    check(cl.exists() and re.search(r"^## \[?0\.1\.0\]?", cl.read_text(), re.M) is not None,
          "docs: CHANGELOG.md has a 0.1.0 section")
    if cl.exists():
        check("NOT RUN" in cl.read_text() or "Known gaps" in cl.read_text(), "docs: CHANGELOG lists known gaps")
    roadmap = (root / "ROADMAP.md").read_text()
    p8 = roadmap.split("## Phase 8", 1)[-1].split("\n## ", 1)[0]
    check("Status:" in p8, "docs: ROADMAP Phase 8 has a Status line")


def arch(root: Path):
    text = (root / "docs/ARCHITECTURE.md").read_text()
    rows = [line for line in text.splitlines() if "AgentHarnessKitALMTests" in line and "iOS" in line]
    check(bool(rows), "arch: a results row names AgentHarnessKitALMTests on iOS Simulator")
    check(any(re.search(r"PASS|FAIL", r) for r in rows), "arch: that row records PASS or FAIL")
    check(any(re.search(r"\d+ tests?", r) for r in rows), "arch: that row records a test count")


def keys(root: Path):
    files = subprocess.run(["git", "ls-files"], cwd=root, capture_output=True, text=True).stdout.split()
    files += [f for f in ["README.md", "CHANGELOG.md", "docs/README.md"] if (root / f).exists()]
    hits = []
    for f in set(files):
        p = root / f
        if p.is_file() and p.stat().st_size < 2_000_000:
            try:
                t = p.read_text()
            except UnicodeDecodeError:
                continue
            hits += [f"{f}: {m}" for pat in KEY_PATTERNS for m in re.findall(pat, t)]
    check(not hits, "keys: no API keys committed" + (f" ({hits[:3]})" if hits else ""))


SECTIONS = {"ci": ci, "readme": readme, "docs": docs, "arch": arch, "keys": keys}

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=str(Path(__file__).resolve().parent.parent))
    ap.add_argument("--only", default=",".join(SECTIONS))
    a = ap.parse_args()
    for name in a.only.split(","):
        SECTIONS[name](Path(a.root))
    print(f"\n{len(FAILS)} failure(s)")
    sys.exit(1 if FAILS else 0)
