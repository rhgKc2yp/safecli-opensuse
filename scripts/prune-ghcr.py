#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Remove obsolete GHCR package versions after a seven-day grace period."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import urllib.parse
import urllib.request


RETENTION = dt.timedelta(days=7)
PROFILES = ("strict", "usb", "nested")
MAX_DELETIONS_PER_PACKAGE = 50


def request_json(token: str, method: str, path: str):
    request = urllib.request.Request(
        "https://api.github.com" + path,
        method=method,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "safecli-ghcr-retention",
        },
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        if response.status == 204:
            return None
        return json.load(response)


def package_versions(token: str, path: str) -> list[dict]:
    versions = []
    for page in range(1, 101):
        batch = request_json(token, "GET", f"{path}/versions?per_page=100&page={page}")
        if not isinstance(batch, list):
            raise ValueError(f"Unexpected GHCR versions response for {path}")
        versions.extend(batch)
        if len(batch) < 100:
            return versions
    raise ValueError(f"Too many GHCR versions to safely enumerate: {path}")


def created_at(version: dict) -> dt.datetime:
    timestamp = version["created_at"]
    parsed = dt.datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("GHCR version timestamp has no timezone")
    return parsed


def prune_candidates(versions: list[dict], now: dt.datetime) -> list[dict]:
    if not versions:
        return []
    if now.tzinfo is None:
        raise ValueError("Current time must include a timezone")
    latest = []
    for version in versions:
        if not isinstance(version.get("id"), int) or isinstance(version["id"], bool):
            raise ValueError("Invalid GHCR version ID")
        tags = version["metadata"]["container"]["tags"]
        if not isinstance(tags, list) or not all(isinstance(tag, str) for tag in tags):
            raise ValueError("Invalid GHCR version tags")
        if "latest" in tags:
            latest.append(version)
    if len(latest) != 1:
        print("Expected one latest image version; skipping package cleanup")
        return []
    if now - created_at(latest[0]) >= RETENTION:
        print("Latest image is at least seven days old; skipping package cleanup")
        return []
    cutoff = now - RETENTION
    candidates = [
        version for version in versions
        if version["id"] != latest[0]["id"] and created_at(version) < cutoff
    ]
    candidates.sort(key=lambda version: (created_at(version), version["id"]))
    return candidates[:MAX_DELETIONS_PER_PACKAGE]


def cleanup(token: str, repository: str, owner_type: str, delete: bool) -> None:
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Invalid GITHUB_REPOSITORY")
    if owner_type not in ("User", "Organization"):
        raise ValueError("Unexpected GHCR owner type")
    owner, name = repository.split("/")
    base = "users" if owner_type == "User" else "orgs"
    now = dt.datetime.now(dt.timezone.utc)
    plans = []
    for profile in PROFILES:
        package = f"{name.lower()}-{profile}"
        path = f"/{base}/{urllib.parse.quote(owner, safe='')}/packages/container/{package}"
        versions = package_versions(token, path)
        candidates = prune_candidates(versions, now)
        print(f"{package}: {len(versions)} versions; {len(candidates)} eligible for deletion")
        plans.append((path, candidates))

    for path, candidates in plans:
        for version in candidates:
            identifier = version["id"]
            tags = version["metadata"]["container"]["tags"]
            if delete:
                request_json(token, "DELETE", f"{path}/versions/{identifier}")
                print(f"Deleted {path} version {identifier} ({', '.join(tags) or 'untagged'})")
            else:
                print(f"Dry run: would delete {path} version {identifier} ({', '.join(tags) or 'untagged'})")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--delete", action="store_true", help="Delete eligible versions")
    arguments = parser.parse_args()
    cleanup(
        os.environ["GITHUB_TOKEN"],
        os.environ["GITHUB_REPOSITORY"],
        os.environ["GHCR_OWNER_TYPE"],
        arguments.delete,
    )


if __name__ == "__main__":
    main()
