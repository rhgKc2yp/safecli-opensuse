#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Open or maintain GitHub issues for newer pinned CI tool releases."""

from __future__ import annotations

import json
import os
import re
import urllib.request
from pathlib import Path


WORKFLOW = Path(__file__).resolve().parent.parent / ".github/workflows/publish-ghcr.yml"
TOOLS = {
    "trivy": ("Trivy", "aquasecurity/trivy"),
    "actionlint": ("actionlint", "rhysd/actionlint"),
}
VERSION = re.compile(r"v(\d+)\.(\d+)\.(\d+)")


def parse_version(tag: str) -> tuple[int, int, int]:
    match = VERSION.fullmatch(tag)
    if match is None:
        raise ValueError(f"Unexpected stable release version: {tag}")
    return tuple(int(part) for part in match.groups())


def current_version(tool: str, workflow: str) -> str:
    if tool == "trivy":
        matches = re.findall(
            r"(?m)^        uses: aquasecurity/setup-trivy@[0-9a-f]{40}\n"
            r"        with:\n          version: (v\d+\.\d+\.\d+)$",
            workflow,
        )
    elif tool == "actionlint":
        matches = re.findall(
            r"gh release download (v\d+\.\d+\.\d+) --repo rhysd/actionlint",
            workflow,
        )
        if len(matches) == 1:
            asset = f"actionlint_{matches[0][1:]}_linux_amd64.tar.gz"
            if workflow.count(asset) != 3:
                raise ValueError("Expected three matching actionlint asset references")
    else:
        raise ValueError(f"Unknown CI tool: {tool}")
    if len(matches) != 1:
        raise ValueError(f"Expected exactly one pinned {tool} version")
    parse_version(matches[0])
    return matches[0]


def request_json(token: str, method: str, path: str, data: dict | None = None):
    body = json.dumps(data).encode() if data is not None else None
    request = urllib.request.Request(
        "https://api.github.com" + path,
        data=body,
        method=method,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "safecli-ci-tool-update-checker",
            **({"Content-Type": "application/json"} if body is not None else {}),
        },
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def open_issues(token: str, repository: str) -> dict[str, dict]:
    found = {}
    for page in range(1, 11):
        entries = request_json(
            token, "GET", f"/repos/{repository}/issues?state=open&per_page=100&page={page}"
        )
        if not isinstance(entries, list):
            raise ValueError("GitHub issues API returned unexpected data")
        for issue in entries:
            if "pull_request" in issue:
                continue
            body = issue.get("body") or ""
            for tool in TOOLS:
                if f"<!-- safecli-ci-update:{tool} -->" in body:
                    if tool in found:
                        raise ValueError(f"Multiple managed update issues for {tool}")
                    found[tool] = issue
        if len(entries) < 100:
            return found
    raise ValueError("Too many open issues to safely find managed updates")


def issue_body(tool: str, current: str, latest: str) -> str:
    label, upstream = TOOLS[tool]
    return (
        f"<!-- safecli-ci-update:{tool} -->\n"
        f"A newer stable {label} release is available.\n\n"
        f"- Pinned version: `{current}`\n"
        f"- Latest version: `{latest}`\n"
        f"- Release: https://github.com/{upstream}/releases/tag/{latest}\n"
        "- File: `.github/workflows/publish-ghcr.yml`\n\n"
        "Review the release notes, update the pinned version, and run the CI checks "
        "before merging. This issue does not change workflow files automatically.\n"
    )


def check_updates(token: str, repository: str, workflow: str) -> None:
    releases = {}
    for tool, (_, upstream) in TOOLS.items():
        latest_result = request_json(token, "GET", f"/repos/{upstream}/releases/latest")
        latest = latest_result["tag_name"]
        parse_version(latest)
        releases[tool] = (current_version(tool, workflow), latest)

    managed = open_issues(token, repository)
    for tool, (current, latest) in releases.items():
        existing = managed.get(tool)
        if parse_version(latest) <= parse_version(current):
            print(f"{tool}: {current} is up to date")
            if existing:
                request_json(
                    token, "PATCH", f"/repos/{repository}/issues/{existing['number']}",
                    {"state": "closed"},
                )
            continue

        body = issue_body(tool, current, latest)
        if existing:
            if existing.get("body") != body:
                request_json(
                    token, "PATCH", f"/repos/{repository}/issues/{existing['number']}",
                    {"body": body},
                )
            print(f"{tool}: update issue #{existing['number']} for {latest}")
        else:
            title = f"Update pinned {TOOLS[tool][0]}"
            request_json(
                token, "POST", f"/repos/{repository}/issues",
                {"title": title, "body": body},
            )
            print(f"{tool}: opened update issue for {latest}")


def main() -> None:
    token = os.environ["GITHUB_TOKEN"]
    repository = os.environ["GITHUB_REPOSITORY"]
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Invalid GITHUB_REPOSITORY")
    check_updates(token, repository, WORKFLOW.read_text())


if __name__ == "__main__":
    main()
