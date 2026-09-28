# Testing and validation

[Documentation index](../README.md) · [Project overview](../../README.md)

Run the setup below before running `swift test`; the complete suite needs the local Node fixtures. Historical test counts and coverage records do not certify a new checkout.

## JavaScript client parity

This project intentionally tracks the semantics of the official JavaScript socket.io-client where those semantics can be implemented safely and meaningfully on Apple's networking stack.

The test suite includes:

- Swift unit tests
- real Socket.IO server integration tests
- HTTP/HTTPS and WebSocket/WSS fixtures
- transport upgrade tests
- parser/encoder differential tests against a pinned official JavaScript implementation
- protocol wire checks
- strict Swift concurrency validation
- Apple SDK builds

Run the main suite with:

```sh
swift build
swift test
```

Additional validation is available through the scripts in scripts/.

Parity does not mean that every JavaScript browser/Node capability exists on Apple platforms.

Notable intentional boundaries include:

- WebTransport is unsupported
- JavaScript custom transport constructors do not have a direct native equivalent
- native compression controls are not exposed
- custom SOCKS routing is unsupported
- some Swift/platform APIs necessarily differ from the JavaScript API

For the detailed audit, supported mappings and known differences, see:

- [PARITY.md](../../PARITY.md)
- [Protocol parity review](../ProtocolParityReview.md)
- [JavaScript test inventory](../JavaScriptTestInventory.csv)

Always use the CI result for the exact commit you intend to ship rather than relying on historical test counts.

## Local setup

The full package suite requires **macOS with Xcode 27 / Swift 6.4**, its Apple
SDKs, Bash, Python 3.9+, Node.js and OpenSSL. Select the intended Xcode before
running `swift --version`; do not lower the package's Swift language mode.
CI uses Node 26 for fixtures and **Node 24 for the pinned upstream Node suites**.
The latter intentionally avoids an incompatibility in the reference dependency
graph. See the [workflow](../../.github/workflows/swift.yml) for exact versions.

Install only the committed fixture dependency graph:

```sh
(cd Tests/TestSocketIO/E2E/Fixtures && npm ci --ignore-scripts --no-audit --no-fund)
swift build
swift test
```

Fixtures start local servers through the test harness. TLS tests generate ephemeral
private certificates; they do not require installing trust roots into the OS.
Do not commit `node_modules`, generated certificates, build outputs or test logs.

## Fast checks without an Apple SDK

```sh
python3 scripts/test-documentation.py
python3 scripts/check-documentation.py
python3 scripts/test-review-regressions.py
python3 scripts/check-parity-contracts.py --strict
```

These checks can run on Linux, but do not establish Linux runtime support for the
library. The strict contract check alone proves only that the recorded mappings
are consistent with the checked-in test sources.

## Full native evidence

To validate contracts against real executions, use Bash and keep pipeline failures:

```sh
set -o pipefail
swift test --enable-code-coverage 2>&1 | tee /tmp/socketio-swift-tests.log
python3 scripts/check-parity-contracts.py --strict --swift-log /tmp/socketio-swift-tests.log
coverage_path="$(swift test --show-codecov-path)"
python3 scripts/report-swift-coverage.py "$coverage_path" /tmp/socketio-coverage-summary.json
```

For isolated consumers, platform builds and concurrency checks:

```sh
bash scripts/test-spm-consumer.sh
bash scripts/test-documentation-examples.sh
bash scripts/test-native-distributions.sh
bash scripts/check-strict-concurrency.sh
swift test --sanitize=thread \
  --skip E2ETest --skip HarnessSanityTest --skip TestServerProcessTest
```

The Thread Sanitizer job intentionally excludes real-network E2E suites and the
two fixture-harness classes. Its naming check prevents a newly added E2E class
from accidentally escaping the exclusion rule. SDK builds are not physical-device
or simulator-runtime tests.

## CI responsibilities

| Job | Evidence |
| --- | --- |
| `repository-hygiene` | Current documentation links, checker regressions and shell syntax |
| `build` | Native suite, independent SPM consumers, passed parity contracts and coverage |
| `thread-sanitizer` | Deterministic unit suites under Thread Sanitizer |
| `strict-concurrency` | Complete concurrency checking and warning baseline |
| `apple-platforms` | Package compilation against four Apple SDK destinations |
| `protocol-proofs` | Real fixture wire behavior and evidence-checker regressions |
| `parser-parity` | Malformed-input checks and pinned JS/Swift parser differential |
| `upstream-clients` | Original pinned Node suites and fresh declaration inventory |

All jobs matter for their distinct scope. A green reference Node suite alone does
not test Swift; a green Swift suite alone does not prove universal JS parity.
Inspect the exact commit, job logs and uploaded artifacts. Historical evidence
is indexed [separately](../ReviewEvidence/README.md).

## Specialized helpers

The [script index](../../scripts/README.md) explains required arguments and
which helpers need the pinned upstream checkout. Do not replace its SHA with a
moving branch or update fixture lockfiles incidentally while editing docs.
