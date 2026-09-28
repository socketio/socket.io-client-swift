#!/usr/bin/env python3
"""Validate traceable contracts; optionally require passed XCTest executions.

A green default check only protects reviewed contracts and the explicit backlog.
--strict fails while any supported runtime row is uncertified. Reviewed feature
exclusions are resolved scope boundaries, never counted as executed tests.
"""
import argparse
import csv
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def validate(root=ROOT, swift_log=None, upstream_inventory=None, strict=False):
    with (root / 'Documentation/JavaScriptTestInventory.csv').open(newline='') as f:
        rows = list(csv.DictReader(f))
    manifest = json.loads((root / 'Documentation/JavaScriptParityContracts.json').read_text())
    errors = []
    by_id = {row['id']: row for row in rows}
    if len(by_id) != len(rows):
        errors.append('Duplicate upstream IDs')
    if {row['upstream_sha'] for row in rows} != {manifest['upstream_sha']}:
        errors.append('Upstream SHA does not match contract manifest')
    remaining = sorted(row['id'] for row in rows if row['status'] == 'unmapped')
    if remaining != sorted(manifest['remaining_unmapped_ids']):
        errors.append('Unmapped backlog changed without explicit review')
    passed = set()
    if swift_log is not None:
        text = Path(swift_log).read_text()
        passed = {cls + '.' + method for cls, method in
                  re.findall(r"Test Case '-\[TestSocketIO\.(\w+) (test\w+)\]' passed", text)}
        if not passed:
            errors.append('No passed XCTest cases found in supplied log')
    certified = set()
    seen_contracts = set()
    for contract in manifest['contracts']:
        name = contract['id']
        if name in seen_contracts:
            errors.append('Duplicate contract ' + name)
        seen_contracts.add(name)
        if not contract.get('assertions') or not contract.get('tests'):
            errors.append(name + ': assertions and executable tests are required')
        for id in contract['upstream_ids']:
            row = by_id.get(id)
            if row is None:
                errors.append(name + ': unknown upstream ID ' + id)
            elif row['status'] != 'focused-regression':
                errors.append(id + ': reviewed contract must have focused-regression status')
            if contract['kind'] in ('assertion-port', 'native-assertion-equivalent', 'native-URI-equivalent'):
                certified.add(id)
        for test in contract['tests']:
            path = (root / test['path']).resolve()
            if not path.is_relative_to((root / 'Tests').resolve()) or not path.is_file():
                errors.append(name + ': missing/invalid test file ' + test['path'])
                continue
            symbol = test['symbol']
            parts = symbol.split('.')
            if len(parts) != 2:
                errors.append(name + ': expected Class.testMethod, got ' + symbol)
                continue
            cls, method = parts
            source = path.read_text()
            if not re.search(r'\b(?:class|extension)\s+' + re.escape(cls) + r'\b', source):
                errors.append(name + ': missing test class ' + symbol)
            if not re.search(r'\bfunc\s+' + re.escape(method) + r'\s*\(', source):
                errors.append(name + ': missing test method ' + symbol)
            if swift_log is not None and symbol not in passed:
                errors.append(name + ': XCTest did not report a PASS for ' + symbol)
    # The inventory's swift_tests column is a derived view of the gated
    # contracts, never independent evidence: it must name exactly the symbols
    # the contracts certify for that row, so readers and CI see the same tests.
    contract_symbols = {}
    for contract in manifest['contracts']:
        for id in contract['upstream_ids']:
            contract_symbols.setdefault(id, set()).update(t['symbol'] for t in contract['tests'])
    for row in rows:
        if row['status'] != 'focused-regression':
            continue
        listed = {ref for ref in re.split(r'[;\s]+', row['swift_tests']) if ref}
        expected = contract_symbols.get(row['id'], set())
        if listed != expected:
            errors.append(row['id'] + ': inventory swift_tests differ from the gated contract tests')
    review = manifest.get('remaining_review')
    if review is None:
        errors.append('Missing explicit remaining-client review')
    else:
        original = review.get('original_unmapped_ids', [])
        dispositions = review.get('dispositions', [])
        seen = [entry.get('id') for entry in dispositions]
        if len(original) != 44 or len(set(original)) != 44 or sorted(seen) != sorted(original):
            errors.append('Remaining-client review must account for all 44 original IDs exactly once')
        contracts = {entry['id']: entry for entry in manifest['contracts']}
        for entry in dispositions:
            id = entry.get('id')
            row = by_id.get(id)
            if row is None or entry.get('status') != row['status']:
                errors.append(str(id) + ': disposition disagrees with inventory status')
            if not entry.get('reason', '').strip():
                errors.append(str(id) + ': disposition requires a reviewed reason')
            status = entry.get('status')
            if status == 'focused-regression':
                contract = contracts.get(entry.get('contract'))
                if contract is None or id not in contract['upstream_ids']:
                    errors.append(str(id) + ': native disposition requires an executable contract')
            elif status not in ('api-difference', 'platform-specific'):
                errors.append(str(id) + ': unreviewed disposition category')
    excluded = set()
    for group in manifest.get('excluded_unsupported_features', []):
        ids = group.get('upstream_ids', [])
        if not ids or not group.get('reason', '').strip():
            errors.append('Unsupported-feature exclusion requires IDs and a reviewed reason')
        for id in ids:
            if id in excluded:
                errors.append(str(id) + ': duplicate unsupported-feature exclusion')
            excluded.add(id)
            row = by_id.get(id)
            if row is None or row['status'] != 'unsupported-feature':
                errors.append(str(id) + ': exclusion must refer to an unsupported-feature row')
    unsupported = {r['id'] for r in rows if r['status'] == 'unsupported-feature'}
    if excluded != unsupported:
        errors.append('Unsupported-feature rows require explicit reviewed exclusions')
    for row in rows:
        if row['status'] in ('unsupported-feature', 'api-difference', 'platform-specific') and not row['review_note'].strip():
            errors.append(row['id'] + ': scope exclusion requires an inventory reason')
    for row in rows:
        if row['status'] in ('candidate-existing-test', 'focused-regression') and row['swift_tests'].strip() == 'browser-only type':
            errors.append(row['id'] + ': platform description is not test evidence')
    if upstream_inventory is not None:
        actual = json.loads(Path(upstream_inventory).read_text())
        keys = ('package', 'scope', 'file', 'line', 'suite', 'title', 'modifier')
        identity = lambda row: tuple(str(row[key]) for key in keys)
        if sorted(map(identity, actual)) != sorted(map(identity, rows)):
            errors.append('CSV declarations differ from the freshly generated pinned upstream AST inventory')
    if strict:
        missing = [r['id'] for r in rows if r['scope'] == 'runtime-declaration'
                   and r['status'] not in ('api-difference', 'platform-specific')
                   and r['id'] not in excluded and r['id'] not in certified]
        if missing:
            errors.append('Complete parity NOT established; uncertified supported rows: ' + ', '.join(missing))
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--swift-log')
    parser.add_argument('--upstream-inventory')
    parser.add_argument('--strict', action='store_true')
    args = parser.parse_args()
    errors = validate(swift_log=args.swift_log, upstream_inventory=args.upstream_inventory, strict=args.strict)
    if errors:
        raise SystemExit('\n'.join(errors))
    print('PASS: reviewed parity contracts and explicit backlog are consistent; no full-parity claim.')


if __name__ == '__main__':
    main()
