# Contributing

[Documentation](Documentation/README.md) · [Repository layout](Documentation/Development/RepositoryLayout.md)

This fork targets Socket.IO 4 / Engine.IO 4 on Apple platforms and distributes
through Swift Package Manager only. Start with a small, focused change and explain
which user-visible behavior or maintenance problem it addresses.

## Set up and validate

Use macOS with Xcode 27 / Swift 6.4, Node.js for the real-server fixtures, Python 3.9+
and OpenSSL. The [testing guide](Documentation/Development/Testing.md#local-setup)
records the fixture/runtime split and all validation commands.

From the repository root:

```sh
(cd Tests/TestSocketIO/E2E/Fixtures && npm ci --ignore-scripts --no-audit --no-fund)
swift build
swift test
python3 scripts/test-documentation.py
python3 scripts/check-documentation.py
python3 scripts/test-review-regressions.py
python3 scripts/check-parity-contracts.py --strict
```

The standalone strict contract check verifies mappings, not test execution.
CI also checks every mapped XCTest against the actual passing test log. Do not
present a static check, filtered suite or previous commit's coverage as a full run.

## Code and tests

Keep client and manager access on their configured serial `handleQueue`; do not
add broad `@unchecked Sendable` annotations to silence concurrency diagnostics.
Add a focused regression for behavior changes. Test the failure, reconnect and
cancellation paths where they are relevant, not just the successful path.

The existing source directories and test names are deliberate stable paths.
Parity contracts refer to exact test files and methods. Changes to mappings,
exclusions or the pinned upstream commit require an explicit review and the
corresponding inventory/validator updates. Do not remove a failing test or relax
a gate just to make CI pass. Preserve applicable copyright and license notices.

## Documentation

Keep the README an entry point. Put application recipes under
`Documentation/Guides`, contributor instructions under `Documentation/Development`,
and link new pages from the documentation index. Update the relevant guide when
changing an API, default, required toolchain or installation instruction.

Use relative links for this checkout. The offline documentation check validates
current local links and headings; it does not crawl the internet or rewrite
historical evidence. The marked README quick start is compiled by CI as an
independent package consumer. Other snippets are contextual recipes, not a claim
that every Markdown code block is independently executable.

## Pull requests and bug reports

Describe the change, its compatibility impact and the checks actually run.
Include a minimal reproducer for bugs, the exact client revision, server and
Swift/Xcode/OS versions, and relevant sanitized logs. Remove tokens, cookies,
private keys and personal payloads before sharing logs or fixtures.

Keep historical reports tied to their original commit. Moving material is not a
reason to discard it: use a documented archive or a commit-pinned history link.
Release preparation follows the [release checklist](Documentation/Development/Releasing.md).
