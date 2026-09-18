#!/usr/bin/env python3
"""Project gates for AppShelf.

One file, standard library only. Every check reports at one of three severities:

  error    fails the run
  warning  passes unless the check is escalated, or `--escalate-warnings` is set
  info     never fails; meant for a human or an agent to read

Design notes worth keeping in mind when editing this file:

* Checks are registered in an explicit list below, not discovered dynamically, so it is
  obvious what a commit will be held to.
* A check that raises is reported as its own error rather than aborting the run. One
  broken check must not hide the state of the others.
* Thresholds only ever tighten. Exemptions fail closed: a missing field, an expired date,
  a wildcard, or a placeholder reason is an error, not a pass.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EXEMPTIONS_FILE = Path(__file__).resolve().parent / "exemptions.json"

ERROR, WARNING, INFO = "error", "warning", "info"


# --------------------------------------------------------------------------- helpers

def sh(*args: str, cwd: Path | None = None) -> str:
    """Run a git command, returning stdout. Raises CalledProcessError to the caller."""
    result = subprocess.run(args, cwd=cwd or ROOT, capture_output=True, text=True, check=True)
    return result.stdout


def tracked_files() -> list[str]:
    return [line for line in sh("git", "ls-files", "-z").split("\0") if line]


def diff_text(refspec: str = "--cached") -> str:
    """The added lines of a diff, so checks can look at what is new rather than at history."""
    try:
        out = sh("git", "diff", refspec, "--unified=0")
    except subprocess.CalledProcessError:
        return ""
    added = []
    for line in out.splitlines():
        if line.startswith("+") and not line.startswith("+++"):
            added.append(line[1:])
    return "\n".join(added)


def count_lines(text: str) -> int:
    """One rule for both HEAD and the working tree, or every file looks like it grew."""
    if not text:
        return 0
    return text.count("\n") + (0 if text.endswith("\n") else 1)


def head_lines(path: str) -> int | None:
    """Line count of a path in HEAD, or None when it does not exist there."""
    try:
        out = subprocess.run(("git", "show", f"HEAD:{path}"), cwd=ROOT,
                             capture_output=True, text=True)
    except OSError:
        return None
    if out.returncode != 0:
        return None
    return count_lines(out.stdout)


@dataclass
class Exemption:
    path: str
    check: str
    reason: str
    owner: str
    cap: int
    expires: str

    @classmethod
    def parse(cls, raw: dict, index: int) -> "Exemption":
        """Fail closed. A half-filled exemption is worse than none: it reads as coverage."""
        missing = [k for k in ("path", "check", "reason", "owner", "cap", "expires") if k not in raw]
        if missing:
            raise ValueError(f"exemption #{index} is missing {', '.join(missing)}")
        path = raw["path"]
        if not path or "*" in path or path.startswith("..") or Path(path).is_absolute():
            raise ValueError(f"exemption #{index} path must be an exact relative path, got {path!r}")
        reason = raw["reason"].strip()
        if len(reason) < 12 or reason.lower() in {"tbd", "todo", "n/a", "历史原因", "以后再拆", "占位"}:
            raise ValueError(f"exemption #{index} needs a specific reason, not {reason!r}")
        try:
            expires = dt.date.fromisoformat(raw["expires"])
        except ValueError:
            raise ValueError(f"exemption #{index} expires must be YYYY-MM-DD") from None
        return cls(path=path, check=raw["check"], reason=reason, owner=raw["owner"],
                   cap=int(raw["cap"]), expires=expires.isoformat())

    def applies_to(self, check: str, path: str) -> bool:
        return self.check == check and self.path == path

    @property
    def expired(self) -> bool:
        return dt.date.fromisoformat(self.expires) < dt.date.today()


def load_exemptions(check: str) -> tuple[list[Exemption], list[str]]:
    """Returns the live exemptions and any configuration problems found while loading."""
    if not EXEMPTIONS_FILE.exists():
        return [], []
    problems: list[str] = []
    try:
        raw = json.loads(EXEMPTIONS_FILE.read_text())
    except json.JSONDecodeError as exc:
        return [], [f"exemptions.json is not valid JSON: {exc}"]
    live: list[Exemption] = []
    for index, entry in enumerate(raw.get("exemptions", []), start=1):
        try:
            exemption = Exemption.parse(entry, index)
        except ValueError as exc:
            problems.append(str(exc))
            continue
        if exemption.expired:
            problems.append(
                f"exemption for {exemption.path} ({exemption.check}) expired {exemption.expires}; "
                "renew it deliberately or remove it"
            )
            continue
        if exemption.check == check:
            live.append(exemption)
    return live, problems


# --------------------------------------------------------------------------- results

@dataclass
class Report:
    check: str
    findings: list[tuple[str, str]] = field(default_factory=list)  # (severity, message)
    seconds: float = 0.0

    def add(self, severity: str, message: str) -> None:
        self.findings.append((severity, message))


# --------------------------------------------------------------------------- checks

def check_file_size(_: str) -> Report:
    """Two thresholds per category, and the verdict depends on what HEAD said.

    A file that was already over the limit and just got smaller must not block the commit,
    or nobody will ever pay the debt down. A file that was over and grew must block.
    """
    report = Report("file-size")
    limits = {  # (warn, block)
        "swift": (300, 700),
        "md": (400, 800),
        "py": (250, 400),
        "sh": (150, 250),
        "json": (400, 900),
        "yaml": (150, 300),
    }
    exemptions, problems = load_exemptions("file-size")
    for problem in problems:
        report.add(ERROR, problem)

    for path in tracked_files():
        suffix = Path(path).suffix.lstrip(".")
        if suffix not in limits or not (ROOT / path).exists():
            continue
        warn, block = limits[suffix]
        current = count_lines((ROOT / path).read_text(errors="replace"))
        previous = head_lines(path)
        exempt = next((e for e in exemptions if e.path == path), None)

        if exempt:
            # The cap is headroom granted for a dated, named, owned reason: the file may
            # reach `cap` and no further. The warn line still applies below it.
            block = exempt.cap
            report.add(INFO, f"{path}: exempt until {exempt.expires} (cap {exempt.cap}, {exempt.owner}): {exempt.reason}")
            if current > exempt.cap:
                report.add(ERROR, f"{path}: {current} lines exceeds the exemption cap of {exempt.cap}")
                continue

        if current <= warn:
            continue
        if previous is None:
            report.add(ERROR if current > block else WARNING,
                       f"{path}: new file at {current} lines exceeds the {warn}-line target")
        elif previous > warn and current < previous:
            report.add(INFO, f"{path}: over target but shrinking ({previous} -> {current})")
        elif previous > warn and current > previous:
            report.add(ERROR, f"{path}: already over target and grew ({previous} -> {current})")
        elif current > block:
            report.add(ERROR, f"{path}: {current} lines, hard limit is {block}")
        else:
            report.add(WARNING, f"{path}: {current} lines exceeds the {warn}-line target")
    return report


FORBIDDEN_STUBS = [
    (re.compile(r"\b(TODO|FIXME|XXX|HACK)\b"), "leftover work marker"),
    (re.compile(r"fatalError\(\s*\"[^\"]*(not implemented|unimplemented)", re.I), "unimplemented entry point"),
    (re.compile(r"\b(fail\(\s*\"not implemented)", re.I), "unimplemented entry point"),
    (re.compile(r"\b(mock|fake|stub|dummy|placeholder)_\w+", re.I), "stand-in value in production code"),
    (re.compile(r"return\s+\[\]\s*//\s*(stub|todo|not implemented)", re.I), "stubbed return"),
]


def check_no_stubs(_: str) -> Report:
    """No placeholder logic standing in for a real implementation outside the tests.

    Fixtures legitimately use stand-ins; production code may not.
    """
    report = Report("no-stubs")
    # The scanner carries the banned words in its own pattern table, so it excludes itself.
    # This is the one self-exemption in the chain and it is deliberate.
    here = "Scripts/gates/gates.py"
    for path in tracked_files():
        if path == here:
            continue
        if not path.startswith(("Sources/", "Scripts/")):
            continue
        if not path.endswith((".swift", ".py", ".sh")):
            continue
        for number, line in enumerate((ROOT / path).read_text(errors="replace").splitlines(), 1):
            stripped = line.strip()
            if stripped.startswith(("///", "//", "#")) and "FIXME" not in stripped:
                continue
            for pattern, label in FORBIDDEN_STUBS:
                if pattern.search(line):
                    report.add(ERROR, f"{path}:{number}: {label} — {stripped[:90]}")
    return report


COMMIT_TYPES = ("feat", "fix", "refactor", "perf", "test", "docs", "build", "ci", "chore")


def check_commit_message(scope: str) -> Report:
    """Type prefix, a length ceiling, and a body that says why.

    scope: "HEAD" checks the newest commit only; a range checks each commit in it.
    """
    report = Report("commit-msg")
    if scope in {"staged", "all"}:
        report.add(INFO, "not applicable to a content sweep; the commit-msg hook and `push` cover it")
        return report

    try:
        revisions = sh("git", "rev-list", scope).split() if scope != "HEAD" else ["HEAD"]
    except subprocess.CalledProcessError as exc:
        report.add(ERROR, f"cannot resolve revision range {scope!r}: {exc}")
        return report

    for revision in revisions:
        subject = sh("git", "log", "-1", "--format=%s", revision)
        body = sh("git", "log", "-1", "--format=%b", revision).strip()
        short = revision[:8]
        if not re.match(rf"^({'|'.join(COMMIT_TYPES)})(\([^)]*\))?[!]?: .+", subject):
            report.add(ERROR, f"{short}: subject needs one of {', '.join(COMMIT_TYPES)} plus a colon: {subject!r}")
        if len(subject) > 72:
            report.add(ERROR, f"{short}: subject is {len(subject)} characters, cap is 72")
        if re.search(r"[，。；]$", subject):
            report.add(WARNING, f"{short}: subject should not end in punctuation")
        if not body and not subject.startswith(("docs:", "chore:", "ci:")):
            report.add(WARNING, f"{short}: no body; say why the change exists, not only what moved")
    return report


# Generic shapes only. Named internal identifiers belong in the gitignored local
# blocklist, never in this file: committing the list of things to hide would itself leak.
SECRET_PATTERNS = [
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"), "private key material"),
    (re.compile(r"\b(ghp|gho|ghu|ghs|ghr)_[0A-Za-z]{20,}\b"), "GitHub token"),
    (re.compile(r"\bgithub_pat_[0A-Za-z_]{20,}\b"), "GitHub fine-grained token"),
    (re.compile(r"\bAKIA[0-9A-Z]{16}\b"), "AWS access key id"),
    (re.compile(r"\bxox[baprs]-[0-9A-Za-z-]{10,}\b"), "Slack token"),
    (re.compile(r"(?i)\b(secret|token|password|passwd|apikey|api_key)\b\s*[:=]\s*[\"'][^\"']{12,}[\"']"),
     "hard-coded credential"),
]
FORBIDDEN_PATH_PATTERNS = [
    (re.compile(r"(^|/)\.env(\.|$)"), "dot-env file"),
    (re.compile(r"(^|/)[^/]*\.secret$"), "secret file"),
    (re.compile(r"\.(pem|p12|p8|keystore|mobileprovision|provisionprofile)$"), "key or provisioning material"),
    (re.compile(r"(^|/)id_(rsa|ed25519|ecdsa)(\.|$)"), "ssh private key"),
    (re.compile(r"(^|/)secrets?(/|$)", re.I), "secrets directory"),
    (re.compile(r"^release/.*\.dmg$"), "installer committed instead of published"),
    (re.compile(r"^ANALYSIS\.md$"), "working analysis scratch file"),
]
ABSOLUTE_HOME = re.compile(r"(?<![\w.])/(?:Users|home)/[A-Za-z0-9._-]{2,}/")


def load_blocklist(report: Report) -> list[str]:
    """Read the gitignored term list, or explain why internal-name screening is off."""
    blocklist = Path(__file__).resolve().parent / "blocklist.local.txt"
    if blocklist.exists():
        needles = [line.strip() for line in blocklist.read_text().splitlines()
                   if line.strip() and not line.strip().startswith("#")]
        report.add(INFO, f"local blocklist active: {len(needles)} terms (file is gitignored)")
        return needles
    # Informational, not a failure: a clean CI checkout legitimately has no local
    # blocklist, and making that red would train everyone to ignore the check.
    report.add(INFO,
               "no Scripts/gates/blocklist.local.txt, so internal-name screening is off "
               "for this run. Create it locally if the machine also holds private work.")
    return []


def committer_emails() -> set[str]:
    try:
        return {sh("git", "config", "user.email").strip().lower()} - {""}
    except subprocess.CalledProcessError:
        return set()


def scan_lines(rel: str, content: str, report: Report, needles: list[str],
               emails: set[str]) -> None:
    for number, line in enumerate(content.splitlines(), 1):
        for pattern, label in SECRET_PATTERNS:
            if pattern.search(line):
                report.add(ERROR, f"{rel}:{number}: {label}")
        if ABSOLUTE_HOME.search(line):
            report.add(ERROR, f"{rel}:{number}: absolute personal path in a public file")
        lowered = line.lower()
        for email in emails:
            if email and email in lowered:
                report.add(ERROR, f"{rel}:{number}: committer email address")
        for needle in needles:
            if needle.lower() in lowered:
                report.add(ERROR, f"{rel}:{number}: blocked term (see local blocklist)")


def check_publication(scope: str) -> Report:
    """Nothing that must stay private may become visible on a public remote.

    Covers tracked paths, the content of tracked text files, the staged additions, and an
    optional local blocklist. Fails closed: an unreadable tracked file is an error.
    """
    report = Report("publication")
    needles = load_blocklist(report)
    emails = committer_emails()

    for path in tracked_files():
        for pattern, label in FORBIDDEN_PATH_PATTERNS:
            if pattern.search(path):
                report.add(ERROR, f"{path}: {label} must not be tracked")

    texts = [path for path in tracked_files() if Path(path).suffix in
             {".swift", ".py", ".sh", ".md", ".json", ".yml", ".yaml", ".txt", ".plist", ".strings"}]
    for path in texts:
        try:
            content = (ROOT / path).read_text()
        except (OSError, UnicodeDecodeError) as exc:
            report.add(ERROR, f"{path}: cannot scan for publication safety ({exc})")
            continue
        scan_lines(path, content, report, needles, emails)

    if scope in {"staged", "all"}:
        added = diff_text("--cached")
        for pattern, label in SECRET_PATTERNS:
            if pattern.search(added):
                report.add(ERROR, f"staged additions contain {label}")
        for needle in needles:
            if needle.lower() in added.lower():
                report.add(ERROR, "staged additions contain a blocked term (see local blocklist)")
    return report


def check_i18n(_: str) -> Report:
    """Both language tables stay complete, and every key the code asks for exists."""
    report = Report("i18n")
    base = ROOT / "Resources/Localization"
    try:
        zh = json.loads((base / "zh-Hans.json").read_text())
        en = json.loads((base / "en.json").read_text())
    except (OSError, json.JSONDecodeError) as exc:
        report.add(ERROR, f"language tables unreadable: {exc}")
        return report

    if set(zh) != set(en):
        only_zh = sorted(set(zh) - set(en))[:8]
        only_en = sorted(set(en) - set(zh))[:8]
        report.add(ERROR, f"tables diverge; zh-only {only_zh} en-only {only_en}")
    for key, value in en.items():
        if not str(value).strip():
            report.add(ERROR, f"en.json: {key!r} has an empty translation")

    cjk = re.compile(r"[一-鿿]")
    key_call = re.compile(r"""(?:\bt|L10nText|L10n\.shared\.t)\(\s*"((?:[^"\\]|\\.)+)\"""")
    literal = re.compile(r'"((?:[^"\\\n]|\\.)+)"')
    referenced: set[str] = set()
    for path in tracked_files():
        if not path.startswith("Sources/") or not path.endswith(".swift"):
            continue
        raw = (ROOT / path).read_text(errors="replace")
        # Doc comments and inline comments quote Chinese freely; scanning them produced
        # phantom "missing keys" for prose.
        text = "\n".join(line for line in raw.splitlines()
                          if not line.strip().startswith(("///", "//", "/*", "*")))
        for match in key_call.finditer(text):
            referenced.add(match.group(1))
        # Any Chinese literal is a candidate key; symbols and identifiers are not.
        for match in literal.finditer(text):
            value = match.group(1)
            if cjk.search(value) and len(value) < 120 and " " not in value[:2]:
                referenced.add(value)
        for match in re.finditer(r'return "(appearance\.[a-z]+|language\.system|external_localization_hint|key_code)"', text):
            referenced.add(match.group(1))

    noise = {"中文", "应用架"}
    missing = sorted(k for k in referenced if k not in zh and k not in noise)
    for key in missing[:15]:
        report.add(ERROR, f"{key!r} is asked for in code but absent from the tables")
    if len(missing) > 15:
        report.add(ERROR, f"...and {len(missing) - 15} more missing keys")
    return report


def check_typography_ratchet(_: str) -> Report:
    """Un-named font sizes may go down, never up.

    A full token sweep would have to be eyeballed one change at a time, so the debt is
    frozen instead: new ad-hoc sizes are refused, and paying the rest down always passes.
    """
    report = Report("typography-ratchet")
    baseline_file = Path(__file__).resolve().parent / "ratchet.json"
    if not baseline_file.exists():
        report.add(ERROR, "Scripts/gates/ratchet.json is missing")
        return report
    baseline = json.loads(baseline_file.read_text()).get("unnamed_font_sizes")
    sites = 0
    for path in tracked_files():
        if not path.startswith("Sources/AppShelf/") or not path.endswith(".swift"):
            continue
        if path.endswith("Theme.swift"):
            continue  # the role definitions themselves live here
        sites += len(re.findall(r"\.font\(\.system\(size:", (ROOT / path).read_text(errors="replace")))
    report.add(INFO, f"un-named font sizes: {sites} (baseline {baseline})")
    if baseline is not None and sites > int(baseline):
        report.add(ERROR,
                   f"un-named font sizes grew from {baseline} to {sites}. Add a named role in "
                   f"Theme.swift instead of a new magic size, or lower the baseline.")
    return report


def check_ledger(_: str) -> Report:
    """Every recorded trap must point at a test that exists.

    A ledger row with no named defence is a reminder, and reminders rot.
    """
    report = Report("traps-ledger")
    path = ROOT / "docs/ledger/traps.md"
    if not path.exists():
        report.add(ERROR, "docs/ledger/traps.md is missing")
        return report
    text = path.read_text()
    test_names: set[str] = set()
    for source in (ROOT / "Tests").rglob("*.swift"):
        test_names.update(re.findall(r"func (\w+)\(\)", source.read_text(errors="replace")))
    rows = re.findall(r"^\|\s*(T-\d+)\s*\|(.*)$", text, re.M)
    if not rows:
        report.add(ERROR, "docs/ledger/traps.md has no rows")
        return report
    uncovered = []
    for identifier, rest in rows:
        # Only the defence column counts, so prose that happens to use backticks is not
        # mistaken for a test pointer.
        columns = [c.strip() for c in rest.split("|")]
        defence = columns[2] if len(columns) > 2 else ""
        named = re.findall(r"`(\w+)`", defence)
        if named:
            for name in named:
                if name not in test_names:
                    report.add(ERROR, f"{identifier}: defence names {name!r}, which is not a test in Tests/")
        elif not re.search(r"无（[^）]+）", defence):
            report.add(ERROR,
                       f"{identifier}: defence column must name a test in backticks, or say "
                       f"无（<where it is covered instead>). Found {defence!r}")
        else:
            uncovered.append(identifier)
    if uncovered:
        report.add(INFO, f"{len(uncovered)} row(s) carry no automated defence: {', '.join(uncovered)}")
    report.add(INFO, f"{len(rows)} ledger rows checked against {len(test_names)} tests")
    return report


CHECKS = {
    "file-size": check_file_size,
    "no-stubs": check_no_stubs,
    "commit-msg": check_commit_message,
    "publication": check_publication,
    "i18n": check_i18n,
    "typography-ratchet": check_typography_ratchet,
    "traps-ledger": check_ledger,
}

# Checks whose warnings are escalated by default: a leak is never a matter of taste.
ALWAYS_ESCALATE = {"publication", "publication-products"}


# --------------------------------------------------------------------------- runner

def print_report(report: Report, escalate_warnings: bool, quiet_info: bool) -> int:
    """Print one report and return its exit code. Only errors fail; warnings block solely
    for an escalated check, otherwise a known, dated exemption would stall every release."""
    blocking = [f for f in report.findings if f[0] == ERROR]
    warnings = [f for f in report.findings if f[0] == WARNING]
    if escalate_warnings or report.check in ALWAYS_ESCALATE:
        blocking += warnings
        warnings = []
    shown = [f for f in report.findings if f[0] == INFO]

    status = "FAIL" if blocking else ("warn" if warnings else "ok")
    print(f"[{status:>4}] {report.check}  ({len(blocking)} error(s), {len(warnings)} warning(s), "
          f"{report.seconds:.2f}s)")
    for severity, message in blocking:
        print(f"        {severity}: {message}")
    for severity, message in warnings:
        print(f"        {severity}: {message}")
    if not quiet_info:
        for _, message in shown:
            print(f"        info: {message}")
    return 1 if blocking else 0


def run(scope: str, only: list[str] | None, skip: list[str] | None,
        escalate_warnings: bool, quiet_info: bool) -> int:
    selected = [name for name in CHECKS
                if (not only or name in only) and not (skip and name in skip)]
    if not selected:
        print("no checks selected", file=sys.stderr)
        return 2

    failures = 0
    for name in selected:
        started = dt.datetime.now()
        try:
            report = CHECKS[name](scope)
        except Exception as exc:  # a broken check is reported, not swallowed
            report = Report(name)
            report.add(ERROR, f"check itself failed: {type(exc).__name__}: {exc}")
        report.seconds = (dt.datetime.now() - started).total_seconds()
        failures += print_report(report, escalate_warnings, quiet_info)
    return 1 if failures else 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["staged", "all", "push", "precommit", "list"])
    parser.add_argument("range", nargs="?", default="HEAD~1..HEAD", help="revision range for push")
    parser.add_argument("--only", help="comma-separated check ids")
    parser.add_argument("--skip", help="comma-separated check ids")
    parser.add_argument("--escalate-warnings", action="store_true",
                        help="treat every warning as a failure")
    parser.add_argument("--quiet", action="store_true", help="hide info findings")
    args = parser.parse_args(argv)

    if args.command == "list":
        for name in CHECKS:
            print(name)
        return 0

    only = args.only.split(",") if args.only else None
    skip = args.skip.split(",") if args.skip else None

    if args.command == "precommit":
        # The cheap, high-signal subset runs on every commit; the slow full sweep runs in CI.
        # Publication is escalated here by design, so a leak stops the commit.
        return run("staged", ["publication", "no-stubs", "i18n"], None, args.escalate_warnings, args.quiet)
    if args.command == "staged":
        return run("staged", only, skip, args.escalate_warnings, args.quiet)
    if args.command == "all":
        return run("all", only, skip, args.escalate_warnings, args.quiet)
    if args.command == "push":
        # Hooks are bypassable locally; the push range is re-checked in full, including
        # every commit message being sent, because a single bad commit in the range matters.
        return run(args.range, None, None, args.escalate_warnings, args.quiet) or \
            run(args.range, ["commit-msg"], None, args.escalate_warnings, args.quiet)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
