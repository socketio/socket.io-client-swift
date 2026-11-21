# Review evidence

[Documentation index](../README.md) · [Current parity scope](../../PARITY.md)

These records are retained for traceability. A report certifies only the revision,
commands and environment that it names. Later reports can supersede earlier
findings without making the earlier observations disappear.

## Live validation inputs

[JavaScriptParityContracts.json](../JavaScriptParityContracts.json) and
[JavaScriptTestInventory.csv](../JavaScriptTestInventory.csv) are the current
mapping and inventory consumed by the strict parity validator.
[InventorySummary.json](InventorySummary.json) is checked against every inventory
row. [StrictConcurrencyBaseline.json](StrictConcurrencyBaseline.json) is consumed
by the concurrency-warning check. Do not archive or delete these as stale notes.

## Protocol and implementation reviews

| Record | Scope |
| --- | --- |
| [Protocol review](../ProtocolParityReview.md) | Chronological review and later follow-ups; read dates and superseding sections |
| [Parity review](../JevParityReview-2026-09-19.md) | Dated independent parity review |
| [Acknowledgement follow-up](../JevAckFollowup-2026-09-19.md) | Dated acknowledgement analysis |
| [Decoder differential](DecoderDifferential.json) | Recorded parser comparison |
| [Final native assertion mappings](../FinalParityAssertions-2026-09-19.md) | Restored historical assertion-audit report for `43bbe47`; counts and remaining-work statements describe that revision, not current release status |
| [Final parity validation](FinalParityValidation-2026-09-19.json) | Recorded native/contract validation |
| [Native coverage validation](NativeCoverageValidation-2026-09-19.json) | Recorded library coverage |
| [Polling failure validation](PollingFailureValidation-2026-09-19.json) | Later polling/coverage follow-up |

## Detailed dated snapshots

Retained evaluations: [acknowledgements](JevAckEvaluation-2026-09-19.json),
[codec](JevCodecEvaluation-2026-09-19.json), [engine](JevEngineEvaluation-2026-09-19.json),
[parity](JevParityEvaluation-2026-09-19.json) and
[parity snapshot](JevParitySnapshot-2026-09-19.json).

Retained detailed reports: [coverage reachability](JevCoverageReachability-2026-09-19.md),
[final engine review](JevFinalEngineReview-2026-09-19.md),
[final lifecycle review](JevFinalLifecycle-2026-09-19.md) and
[parity backlog](JevParityBacklog-2026-09-19.csv).

These historical bodies may mention old paths, test counts or limitations.
They are not rewritten to make a newer release look better. Current supported
scope lives in `PARITY.md`; current executed evidence comes from the exact CI run.
Previously removed completed reports remain accessible through the
[archive history index](../Archive/README.md).
