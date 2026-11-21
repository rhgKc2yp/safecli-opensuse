#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Offline tests for CI update alerts and GHCR package retention."""

import datetime as dt
import importlib.util
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parent.parent


def load_script(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), ROOT / "scripts" / name)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


updates = load_script("check-ci-tool-updates.py")
retention = load_script("prune-ghcr.py")


class ToolUpdateTests(unittest.TestCase):
    def setUp(self):
        self.workflow = updates.WORKFLOW.read_text()

    def test_pinned_versions_are_detected(self):
        self.assertEqual(updates.current_version("trivy", self.workflow), "v0.76.2")
        self.assertEqual(updates.current_version("actionlint", self.workflow), "v1.7.12")

    def test_version_comparison(self):
        self.assertLess(updates.parse_version("v0.76.2"), updates.parse_version("v0.77.0"))
        with self.assertRaises(ValueError):
            updates.parse_version("v0.77.0-rc1")

    def test_new_release_opens_issue_once(self):
        calls = []

        def api(_token, method, path, data=None):
            calls.append((method, path, data))
            if path.endswith("/releases/latest"):
                return {"tag_name": "v0.77.0" if "trivy" in path else "v1.7.12"}
            if method == "GET":
                return []
            return {"number": 1}

        with patch.object(updates, "request_json", side_effect=api):
            updates.check_updates("token", "owner/repo", self.workflow)
        created = [call for call in calls if call[0] == "POST"]
        self.assertEqual(len(created), 1)
        self.assertEqual(created[0][2]["title"], "Update pinned Trivy")

    def test_resolved_release_closes_managed_issue(self):
        calls = []

        def api(_token, method, path, data=None):
            calls.append((method, path, data))
            if path.endswith("/releases/latest"):
                return {"tag_name": "v0.76.2" if "trivy" in path else "v1.7.12"}
            if method == "GET":
                return [{"number": 12, "body": "<!-- safecli-ci-update:trivy -->"}]
            return {}

        with patch.object(updates, "request_json", side_effect=api):
            updates.check_updates("token", "owner/repo", self.workflow)
        self.assertIn(("PATCH", "/repos/owner/repo/issues/12", {"state": "closed"}), calls)


class GhcrRetentionTests(unittest.TestCase):
    NOW = dt.datetime(2026, 11, 20, tzinfo=dt.timezone.utc)

    @classmethod
    def version(cls, identifier, age_days, tags=()):
        return {
            "id": identifier,
            "created_at": (cls.NOW - dt.timedelta(days=age_days)).isoformat(),
            "metadata": {"container": {"tags": list(tags)}},
        }

    def test_keeps_latest_and_recent_versions(self):
        versions = [
            self.version(1, 2, ["latest", "build-1"]),
            self.version(2, 5, ["candidate-2"]),
            self.version(3, 8, ["v1.2.3"]),
            self.version(4, 12),
        ]
        result = retention.prune_candidates(versions, self.NOW)
        self.assertEqual([version["id"] for version in result], [4, 3])

    def test_refuses_cleanup_when_latest_is_old_or_ambiguous(self):
        self.assertEqual(
            retention.prune_candidates(
                [self.version(1, 8, ["latest"]), self.version(2, 10)], self.NOW
            ),
            [],
        )
        self.assertEqual(retention.prune_candidates([self.version(2, 10)], self.NOW), [])
        with self.assertRaises(ValueError):
            retention.prune_candidates([{"id": "bad", "metadata": {}}], self.NOW)

    def test_limits_deletions_per_package(self):
        versions = [self.version(1, 1, ["latest"])] + [
            self.version(identifier, 10) for identifier in range(2, 102)
        ]
        candidates = retention.prune_candidates(versions, self.NOW)
        self.assertEqual(len(candidates), retention.MAX_DELETIONS_PER_PACKAGE)

    def test_dry_run_does_not_delete_and_limits_package_names(self):
        calls = []

        def api(_token, method, path):
            calls.append((method, path))
            return [self.version(1, 1, ["latest"]), self.version(2, 9)]

        with patch.object(retention, "request_json", side_effect=api):
            retention.cleanup("token", "Owner/Repo", "User", False)
        self.assertEqual(len(calls), 3)
        self.assertTrue(all(method == "GET" for method, _ in calls))
        self.assertTrue(all("/packages/container/repo-" in path for _, path in calls))

    def test_delete_only_selected_versions(self):
        calls = []

        def api(_token, method, path):
            calls.append((method, path))
            if method == "GET":
                return [self.version(1, 1, ["latest"]), self.version(2, 9)]
            return None

        with patch.object(retention, "request_json", side_effect=api):
            retention.cleanup("token", "owner/repo", "Organization", True)
        deletions = [path for method, path in calls if method == "DELETE"]
        self.assertEqual(len(deletions), 3)
        self.assertTrue(all(path.endswith("/versions/2") for path in deletions))

    def test_invalid_later_package_prevents_all_deletions(self):
        calls = []

        def api(_token, method, path):
            calls.append((method, path))
            if "repo-nested" in path:
                return [{"id": "invalid"}]
            return [self.version(1, 1, ["latest"]), self.version(2, 9)]

        with patch.object(retention, "request_json", side_effect=api):
            with self.assertRaises(ValueError):
                retention.cleanup("token", "owner/repo", "Organization", True)
        self.assertTrue(all(method == "GET" for method, _ in calls))


if __name__ == "__main__":
    unittest.main()
