#!/usr/bin/env python3
"""Validate a Conventional Commit PR title from a GitHub event JSON file."""

import argparse
import json
from pathlib import Path
import re
import sys


# Types are words, not a fixed allowlist; scopes and breaking markers are optional.
TITLE = re.compile(r"[a-zA-Z]+(?:\((?P<scope>[^()]+)\))?!?: (?P<description>.*)")
GUIDANCE = (
    "Rename the PR using `type(scope)!: description`, for example "
    "`fix(codex): handle empty responses`, then rerun the check. "
    "The scope and ! are optional. Use a word for the type, a nonblank scope "
    "if present, a colon followed by a space, and a nonblank single-line description."
)


def valid_title(title):
    if not isinstance(title, str) or title.splitlines() != [title]:
        return False
    match = TITLE.fullmatch(title)
    return bool(
        match
        and (match["scope"] is None or match["scope"].strip())
        and match["description"].strip()
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("event_path", type=Path, help="GitHub pull_request event JSON")
    args = parser.parse_args()
    try:
        event = json.loads(args.event_path.read_text(encoding="utf-8"))
        title = event["pull_request"]["title"]
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"Could not read pull_request.title from event JSON: {error}", file=sys.stderr)
        return 1
    if not valid_title(title):
        print(f"::error title=Invalid PR title::{GUIDANCE}", file=sys.stderr)
        return 1
    print("PR title follows Conventional Commit syntax.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
