#!/usr/bin/env python3
"""Screen a built bundle for content that must not leave this machine.

A release artifact is not in `git ls-files`, so the repository checks never look inside it,
yet the .app ships text a user can open: Info.plist, per-language InfoPlist.strings, the
localization JSON. This runs the same rules over that text.

The patterns, the blocklist loader and the reporting live in gates.py so there is one
definition of what counts as a leak, not two that can drift apart.
"""

import sys
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from gates import (  # noqa: E402
    ERROR, INFO, Report, committer_emails, load_blocklist, print_report, scan_lines,
)

MAX_FILE_BYTES = 2_000_000


def scan_products(target: str, quiet_info: bool) -> int:
    root = Path(target)
    if not root.is_absolute():
        root = Path(__file__).resolve().parents[2] / root
    started = datetime.now()
    report = Report("publication-products")
    needles = load_blocklist(report)
    emails = committer_emails()

    if not root.exists():
        report.add(ERROR, f"{target}: build product does not exist, nothing was scanned")
        report.seconds = (datetime.now() - started).total_seconds()
        return print_report(report, False, quiet_info)

    scanned = 0
    for path in sorted(p for p in root.rglob("*") if p.is_file()):
        try:
            if path.stat().st_size > MAX_FILE_BYTES:
                continue
            content = path.read_text()
        except (OSError, UnicodeDecodeError):
            continue  # Mach-O, asset catalogs, icons: binary, not text
        scanned += 1
        scan_lines(str(path.relative_to(root.parent)), content, report, needles, emails)

    report.add(INFO, f"{scanned} text file(s) scanned under {target}")
    if scanned == 0:
        # Fails closed: pointing this at the wrong directory must not read as a clean pass.
        report.add(ERROR, f"{target}: no readable text at all, is this really an unpacked bundle?")
    report.seconds = (datetime.now() - started).total_seconds()
    return print_report(report, False, quiet_info)


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if a != "--quiet"]
    if len(args) != 1:
        print("usage: scan_products.py <path/to/AppShelf.app> [--quiet]", file=sys.stderr)
        sys.exit(2)
    sys.exit(scan_products(args[0], "--quiet" in sys.argv))
