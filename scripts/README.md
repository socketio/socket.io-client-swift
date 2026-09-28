# Validation scripts

[Contributing](../CONTRIBUTING.md) · [Testing guide](../Documentation/Development/Testing.md)

Run commands from the repository root unless noted otherwise. Use `bash`, `python3`
or `node` explicitly; scripts do not all have executable permission bits.

| Script | Purpose / prerequisites |
| --- | --- |
| `check-documentation.py` | Offline current-documentation file and anchor checks; Python 3.9+ |
| `test-documentation.py` | Regression tests for the documentation checker; Python 3.9+ |
| `test-documentation-examples.sh` | Compile/run the marked README quick start as an independent local SPM consumer; Apple toolchain |
| `test-spm-consumer.sh` | Independent package import; local checkout on branch runs, exact 17.1.0 GitHub dependency on the expected release-tag run |
| `test-native-distributions.sh` | Check removed Swift dependencies and compile the package for four Apple SDK destinations |
| `test-native-transport.sh` | Filtered deterministic native transport tests in the actual package |
| `check-strict-concurrency.sh` | Complete Swift concurrency checking against the recorded warning baseline |
| `check-parity-contracts.py` | Check inventory/contracts; `--strict` requires complete supported mappings; `--swift-log FILE` requires actual passed XCTest evidence |
| `test-review-regressions.py` | Guard evidence consistency, validator failure modes and shell fail-fast behavior |
| `test-parser-safety.sh` | Compile real Swift parser sources and probe malformed-input safety |
| `test-parser-parity.sh UPSTREAM [OUTPUT]` | Decoder/encoder differential with the pinned official implementation; Swift, Node, TypeScript and upstream checkout |
| `test-upstream-clients.sh UPSTREAM OUTPUT` | Run the pinned original Node client suites and regenerate declaration evidence; use Node 24 |
| `inventory-upstream-tests.cjs` | Extract original test declarations with the TypeScript AST; used by the upstream suite helper |
| `report-swift-coverage.py INPUT OUTPUT` | Produce a library-only summary from Swift's coverage JSON |

`parser-parity/` contains the differential harness and small Swift compilation
shims, not an alternate runtime implementation. The pinned upstream commit is
`aaf2af36ec8ad05910f357a788e0e358bad32738`; the workflow shows the fetch and
TypeScript 5.8.3 setup. Do not substitute a moving upstream branch.

Fixture wire proofs and observer tests remain beside the Node server in
`Tests/TestSocketIO/E2E/Fixtures`. Their dependencies are installed with `npm ci`
from the committed lockfile, not a floating `npm install`.

A filtered helper is not a replacement for the full native suite. The documentation
checker does not access the network and excludes explicitly historical bodies;
see the [scope](../Documentation/Development/RepositoryLayout.md#keep-the-structure-coherent).
