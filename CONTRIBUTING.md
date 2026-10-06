# Contributing to SwiftyToys

Bug fixes, focused improvements, documentation and reproducible reports are welcome.
Discuss a substantial feature or architecture change in an issue before implementing
it. Contributions are made through forks and pull requests; public access does not
grant permission to push to the upstream repository.

## Workflow

1. Read README.md and AGENTS.md, fork the repository and create a feature branch.
2. Make one focused change. Follow the existing native Swift and Windows API patterns.
3. Run the relevant build/tests and document hardware or platform limitations.
4. Open a pull request describing the problem, resulting behavior and validation.
5. Address maintainer feedback. Only the maintainer controls merges into main.

Use concise imperative commit/PR titles. Main uses squash merges, so the final PR
description should explain the complete resulting change. Keep unrelated cleanup
separate. Do not merge work-in-progress or untested functionality into main.

## Review and checks

External changes require approval from the designated code owner, passing CI and
resolved review discussions. New commits invalidate previous approval. Passing
checks alone do not authorize a merge. Maintainer-authored changes also use PRs;
the maintainer can review their own changes before merging, while CI still applies.
Force pushes and deletion of main are blocked. Do not bypass repository rules.

Run scripts/build.ps1 and scripts/test.ps1 as described in README.md. Builds/tests
must finish successfully before packaging or running a new executable. Separate
portable/native checks from physical display/input-device validation. Never modify
the watchdog, recovery state or driver trust configuration just to make a test pass.

Keep blocking driver calls on the dedicated display executor and input callbacks
on their own message thread. Use swift-format and the checked-in formatting rules.
Display validation should cover 0%/100%, restoration after exit/crash, reconnection,
multiple-monitor targeting and input. Report anonymized GPU/driver/HDR/streaming
conditions. Do not add a global dimming fallback for unsupported GPUs or alter a
virtual streaming output. Keep private configurations, dumps and recovery backups
out of commits and release packages.

## Privacy, licensing and security

Keep personal agent instructions and machine configuration outside the repository.
Never commit private hostnames, SSH destinations, home/account paths, credentials,
raw device identifiers or private logs. Use anonymized reproduction details and
generic examples. GitHub's noreply email is suitable for public commit metadata.
Review the staged diff and release archives before publishing.

Preserve copyright and third-party notices. Submit contributions under the project's
MIT license and include only material you have permission to contribute. Do not
redistribute proprietary driver/layout binaries or change signatures/trust roots.
Report security vulnerabilities privately as described in SECURITY.md.
