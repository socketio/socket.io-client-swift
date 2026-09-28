# Repository layout

[Documentation index](../README.md) · [Contributing](../../CONTRIBUTING.md)

```text
README.md                       Project purpose, client choice, installation and quick start
CONTRIBUTING.md                  Contributor entry point
Package.swift                   The supported distribution/build manifest
Source/SocketIO/                 Library implementation, grouped by responsibility
Tests/TestSocketIO/              Unit tests, mocks and real-server E2E fixtures
scripts/                        Reproducible validation helpers and their index
.github/                        CI and issue/pull-request templates
Documentation/
  README.md                     Documentation navigation
  Guides/                       Client selection, application recipes and troubleshooting
  Development/                  Architecture, testing, releasing and this layout
  ReviewEvidence/               Live baselines and recorded historical evidence
  Archive/                      Preserved old pages and history pointers
  JavaScriptParityContracts.json  Executable assertion mappings
  JavaScriptTestInventory.csv    Reviewed upstream declaration inventory
  *Migration.md                 Detailed migration contracts at stable paths
  NativeWebSocketTransport.md    Native backend/TLS migration and design
  Release17.md                   Version-specific release record
  ProtocolParityReview.md        Chronological review with later follow-ups
PARITY.md                       Current supported parity scope and deviations
CHANGELOG.md                    Version history
LICENSE                         Current licensing terms and applicable notices
docs/index.html                 Existing Pages landing page, not a second handbook
```

## Stable paths and preservation

The SPM-only cleanup does not require source or test renames. The manifest,
source, test/fixture files, contract data and existing evidence remain in place.
The split guides retain every substantive section of the former README; only
navigation is replaced with the new index. Old usage pages are retained byte for
byte under `Documentation/Archive/UsageDocs`, not advertised as current guidance.

Already removed plans and completed reports remain reachable through pinned
links in the [archive index](../Archive/README.md). Carthage, CocoaPods and the
retired framework/Xcode project are not restored. Consult [LICENSE](../../LICENSE)
for the current licensing terms and applicable notices; dependency metadata is
defined separately in `Package.swift`. Documentation-only layout changes must
not silently rewrite licensing terms.

## Keep the structure coherent

Add application documentation to `Guides`, implementation/contributor instructions
to `Development`, and a link from the relevant index. Use the detailed migration
pages for compatibility contracts rather than copying competing versions into
new locations. Evidence files must identify their original commit/run and are
not a substitute for a green current CI run.

Keep the README focused on choosing and using the library. Put detailed upstream
comparisons in [Why this fork?](../Guides/WhyThisFork.md), with a review date and
pinned source references. Label the branch a CI badge represents, distinguish
released versions from development revisions, and do not present old test counts
or coverage snapshots as live status. Keep the marked README quick start
compilable by `scripts/test-documentation-examples.sh`.

The offline checker covers current root docs, guides, development pages, indexes,
migration/release pages and the Pages landing page. It deliberately does not
rewrite the historical changelog, chronological review bodies, evidence snapshots
or raw archived pages. It checks local paths and Markdown/HTML anchors, not remote
website availability or the semantic correctness of prose.

Do not add generated API HTML, local IDE state, Node dependencies, build outputs,
credentials or test certificates. `docs/index.html` points to the authored docs;
changing it does not itself deploy a website or merge a branch.
