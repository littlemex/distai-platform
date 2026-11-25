#!/usr/bin/env python3
"""Fail if a denylisted tool or vendor name appears in given text file(s).

Usage:
    check_tool_attribution.py --denylist PATH --label LABEL FILE [FILE ...]

Reads one case-insensitive term per line from the denylist file (blank
lines and lines starting with "#" are ignored), then checks whether any
term appears, as a case-insensitive substring, anywhere in the given
file(s). Prints one GitHub Actions error annotation per match and exits 1
if at least one term matched; exits 0 otherwise.
"""
import argparse
import re
import sys


def load_denylist(path: str) -> list[str]:
    terms = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            terms.append(line)
    if not terms:
        raise SystemExit(f"{path}: no terms found (every line was blank or a comment)")
    return terms


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--denylist", required=True, help="path to the term list")
    parser.add_argument("--label", required=True, help="what is being checked, for the error message")
    parser.add_argument("files", nargs="+", help="text file(s) to check")
    args = parser.parse_args()

    terms = load_denylist(args.denylist)
    patterns = [(term, re.compile(re.escape(term), re.IGNORECASE)) for term in terms]

    found_any = False
    for path in args.files:
        with open(path, encoding="utf-8") as f:
            text = f.read()
        for term, pattern in patterns:
            if pattern.search(text):
                found_any = True
                print(f"::error::{args.label} contains the denylisted term '{term}' (checked file: {path})")

    if found_any:
        print(
            f"\nOne or more denylisted terms were found in {args.label}. Remove tool "
            f"and vendor names from commit messages, the pull request title and the "
            f"pull request description before merging; see {args.denylist} for the "
            "full list.",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
