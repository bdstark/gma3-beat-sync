<!-- Keep this proportional to the change. Use N/A with a short explanation for irrelevant sections.
Read CONTRIBUTING.md and CODE_OF_CONDUCT.md. For vulnerabilities, coordinate privately before a public PR:
https://github.com/bdstark/gma3-beat-sync/security/advisories/new -->

## Problem and resulting behavior

<!-- Explain the concrete problem and what this changes for an operator or another tool. -->

Related ticket / issue:

## Scope

- Plugin, harness, test peer or documentation changes:
- Protocol facts used, each with the Link source file it comes from (or the packet capture fixture):
- Changes to the published status or configuration interface, and migration needs:

## Validation

<!-- Give commands and results; record failures, skipped tests and checks not run. -->

- `scripts/check.sh` (SPDX, Lua 5.5 syntax, harness, test peer build):
- Regression or failure-path coverage (malformed packets, lost peer, missing speed master or sequence, late frames):
- Live evidence, if needed: commit, exact grandMA3 version, platform, network, other apps in the session, results:
- Link test plan cases run and their results (none claimed otherwise):
- Accessibility considerations for documentation or user-facing changes (if applicable):
- Remaining limitations or unverified behavior:

## Submission checks

- [ ] I have followed the contribution guidance and code of conduct, and my contribution is licensed under
      GPL-2.0-or-later.
- [ ] Every new source file carries `SPDX-License-Identifier: GPL-2.0-or-later`.
- [ ] "Link" is used only as compatibility wording, and no compatibility is claimed beyond the test plan cases that
      pass.
- [ ] This patch contains no secrets, private show data or material I lack the right to contribute.
