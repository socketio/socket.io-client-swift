# Releasing

[Documentation index](../README.md) · [Testing](Testing.md)

Swift Package Manager is the only supported distribution channel. A release is
a reviewed commit and a version tag, not whichever revision happens to be on a
branch. Treat published tags as immutable: fix later issues in a new version.

## Before creating a release

Review the changelog, migration instructions, supported platform/toolchain values,
installation examples and parity scope. Preserve explicit unsupported-feature
reasons. Update version-specific tooling deliberately: `test-spm-consumer.sh`
currently accepts `v17.1.0` for remote exact-version validation; a future release
must update that expected tag/version before using the same check.

Require every CI job in the [workflow](../../.github/workflows/swift.yml) to pass
on the exact candidate commit. This includes documentation checks, the native
suite and executed parity contracts, both independent consumers, Thread Sanitizer,
strict concurrency, Apple SDK builds, wire proofs and the pinned reference suites.
Do not publish using evidence from an earlier SHA just because only docs changed.

## Validate the published version

After creating the intended tag, explicitly dispatch the Swift workflow against
that tag. The existing SPM consumer detects a tag run and resolves the expected
exact version from GitHub instead of a local package path. Confirm the resolved
version and commit in the job output. A branch run validates the checkout, not a
published release dependency. This checklist is not an automated publishing job.

Record the tag, commit SHA, CI run links, actual test results and any remaining
scope limitations on the release page. Do not infer physical iOS/watchOS runtime
validation from macOS tests or SDK compilation. Coverage is code execution data,
not a percentage of all possible JavaScript behavior.

## Historical release

[Release 17](../Release17.md) and its linked release page retain the version-specific
record. The repository may contain later documentation or fixes not present in
that tag; these do not change the contents of an existing published version.
