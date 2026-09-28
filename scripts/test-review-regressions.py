#!/usr/bin/env python3
"""Offline checks for review evidence and shell fail-fast behavior."""
import collections
import csv
import json
import os
import runpy
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class ReviewRegressions(unittest.TestCase):
    def test_inventory_summary_matches_every_csv_row(self):
        with (ROOT / "Documentation/JavaScriptTestInventory.csv").open(newline="") as source:
            rows = list(csv.DictReader(source))
        summary = json.loads((ROOT / "Documentation/ReviewEvidence/InventorySummary.json").read_text())
        self.assertEqual({row["upstream_sha"] for row in rows}, {summary["upstream_sha"]})
        actual = collections.Counter(row["status"] for row in rows)
        recorded = {key: count for key, count in summary["review_statuses"].items() if count}
        self.assertEqual(dict(actual), recorded)
        runtime = collections.Counter(row["package"] for row in rows if row["scope"] == "runtime-declaration")
        self.assertEqual(dict(runtime), summary["runtime_by_package"])
        self.assertEqual(len(rows) - sum(runtime.values()), summary["typescript_type_declarations"])

    def test_reviewed_contracts_exist_and_strict_mode_refuses_incomplete_parity(self):
        validate = runpy.run_path(str(ROOT / "scripts/check-parity-contracts.py"))["validate"]
        self.assertEqual(validate(), [])
        self.assertEqual(validate(strict=True), [])
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copytree(ROOT / "Documentation", root / "Documentation")
            shutil.copytree(ROOT / "Tests", root / "Tests", ignore=shutil.ignore_patterns("Fixtures"))
            path = root / "Documentation/JavaScriptParityContracts.json"
            manifest = json.loads(path.read_text())
            # Regress a complete mapping back to limited evidence. The strict
            # checker must reject it even though the ordinary contract is valid.
            contract = next(c for c in manifest["contracts"] if c["upstream_ids"] == ["JS-049"])
            contract["kind"] = "native-adaptation"
            path.write_text(json.dumps(manifest))
            self.assertEqual(validate(root=root), [])
            self.assertIn("Complete parity NOT established; uncertified supported rows: JS-049",
                          validate(root=root, strict=True))

    def test_contract_check_rejects_missing_symbols_and_missing_runtime_evidence(self):
        validate = runpy.run_path(str(ROOT / "scripts/check-parity-contracts.py"))["validate"]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copytree(ROOT / "Documentation", root / "Documentation")
            shutil.copytree(ROOT / "Tests", root / "Tests", ignore=shutil.ignore_patterns("Fixtures"))
            path = root / "Documentation/JavaScriptParityContracts.json"
            manifest = json.loads(path.read_text())
            manifest["contracts"][0]["tests"][0]["symbol"] += "DoesNotExist"
            path.write_text(json.dumps(manifest))
            self.assertTrue(any("missing test method" in e for e in validate(root=root)))
            empty_log = root / "empty.log"
            empty_log.write_text("No test executions\n")
            self.assertTrue(any("No passed XCTest" in e for e in validate(swift_log=empty_log, strict=True)))

    def test_contract_check_rejects_an_unreviewed_backlog_change(self):
        validate = runpy.run_path(str(ROOT / "scripts/check-parity-contracts.py"))["validate"]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copytree(ROOT / "Documentation", root / "Documentation")
            shutil.copytree(ROOT / "Tests", root / "Tests", ignore=shutil.ignore_patterns("Fixtures"))
            path = root / "Documentation/JavaScriptParityContracts.json"
            manifest = json.loads(path.read_text())
            manifest["remaining_unmapped_ids"] = ["JS-999"]
            path.write_text(json.dumps(manifest))
            self.assertIn("Unmapped backlog changed without explicit review", validate(root=root))

    def test_disposition_requires_reason_and_complete_original_id_set(self):
        validate = runpy.run_path(str(ROOT / "scripts/check-parity-contracts.py"))["validate"]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copytree(ROOT / "Documentation", root / "Documentation")
            shutil.copytree(ROOT / "Tests", root / "Tests", ignore=shutil.ignore_patterns("Fixtures"))
            path = root / "Documentation/JavaScriptParityContracts.json"
            manifest = json.loads(path.read_text())
            manifest["remaining_review"]["dispositions"][0]["reason"] = ""
            path.write_text(json.dumps(manifest))
            self.assertTrue(any("requires a reviewed reason" in e for e in validate(root=root)))
            manifest["remaining_review"]["dispositions"].pop()
            path.write_text(json.dumps(manifest))
            self.assertTrue(any("all 44 original IDs" in e for e in validate(root=root)))

    def test_native_disposition_requires_matching_executable_contract(self):
        validate = runpy.run_path(str(ROOT / "scripts/check-parity-contracts.py"))["validate"]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copytree(ROOT / "Documentation", root / "Documentation")
            shutil.copytree(ROOT / "Tests", root / "Tests", ignore=shutil.ignore_patterns("Fixtures"))
            path = root / "Documentation/JavaScriptParityContracts.json"
            manifest = json.loads(path.read_text())
            entry = next(e for e in manifest["remaining_review"]["dispositions"] if e["status"] == "focused-regression")
            entry["contract"] = "missing-contract"
            path.write_text(json.dumps(manifest))
            self.assertTrue(any("requires an executable contract" in e for e in validate(root=root)))

    def test_unsupported_exclusions_are_explicit_and_do_not_hide_supported_gaps(self):
        validate = runpy.run_path(str(ROOT / "scripts/check-parity-contracts.py"))["validate"]
        errors = validate(strict=True)
        self.assertEqual(errors, [])
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copytree(ROOT / "Documentation", root / "Documentation")
            shutil.copytree(ROOT / "Tests", root / "Tests", ignore=shutil.ignore_patterns("Fixtures"))
            path = root / "Documentation/JavaScriptParityContracts.json"
            manifest = json.loads(path.read_text())
            group = manifest["excluded_unsupported_features"][0]
            group["reason"] = ""
            path.write_text(json.dumps(manifest))
            self.assertTrue(any("reviewed reason" in e for e in validate(root=root)))
            group["reason"] = "Native compression controls are not exposed"
            removed = group["upstream_ids"].pop()
            path.write_text(json.dumps(manifest))
            self.assertIn("Unsupported-feature rows require explicit reviewed exclusions", validate(root=root))
            group["upstream_ids"].append(removed)
            group["upstream_ids"].append(manifest["contracts"][0]["upstream_ids"][0])
            path.write_text(json.dumps(manifest))
            self.assertTrue(any("exclusion must refer" in e for e in validate(root=root)))

    def test_inventory_test_pointers_must_match_the_gated_contracts(self):
        validate = runpy.run_path(str(ROOT / "scripts/check-parity-contracts.py"))["validate"]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copytree(ROOT / "Documentation", root / "Documentation")
            shutil.copytree(ROOT / "Tests", root / "Tests", ignore=shutil.ignore_patterns("Fixtures"))
            path = root / "Documentation/JavaScriptTestInventory.csv"
            with path.open(newline="") as source:
                rows = list(csv.DictReader(source))
            row = next(r for r in rows if r["status"] == "focused-regression")
            # A bare class name or a stale pointer is not the certified test.
            row["swift_tests"] = "SomeTestClass"
            with path.open("w", newline="") as target:
                writer = csv.DictWriter(target, fieldnames=rows[0].keys(), lineterminator="\n")
                writer.writeheader()
                writer.writerows(rows)
            self.assertIn(row["id"] + ": inventory swift_tests differ from the gated contract tests",
                          validate(root=root))

    def test_mktemp_failure_stops_before_prepare_or_compilation(self):
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            (temp / "mktemp").write_text("#!/bin/sh\nexit 73\n")
            (temp / "node").write_text('#!/bin/sh\ntouch "$SENTINEL"\nexit 0\n')
            (temp / "swiftc").write_text('#!/bin/sh\ntouch "$SENTINEL"\nexit 0\n')
            for name in ("mktemp", "node", "swiftc"):
                (temp / name).chmod(0o755)
            environment = dict(os.environ, PATH=str(temp) + os.pathsep + os.environ["PATH"], SENTINEL=str(temp / "ran"))
            result = subprocess.run([shutil.which("bash"), str(ROOT / "scripts/test-parser-parity.sh"), directory],
                                    cwd=directory, env=environment, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 73, result.stderr.decode())
            self.assertFalse((temp / "ran").exists())

if __name__ == "__main__":
    unittest.main()
