# Accessibility

gma3-beat-sync aims to make its documentation, configuration and status reporting usable by people with different
abilities and ways of working. Accessibility is relevant even though the plugin runs inside the console, which
provides the interface people use.

This is a statement of intent and contribution guidance, not a claim of conformance to an accessibility standard.
No formal accessibility audit or assistive-technology testing has been completed.

## What this project controls

The project controls its documentation, its configuration format, the status it publishes and the messages it
writes to the console. grandMA3 itself, the console's screens, onPC and any tool that reads the plugin's status
(such as gma3-mcp) are separate products. Their accessibility also affects the complete workflow and cannot be
guaranteed by this repository.

## Guidance for contributions

- Write clear instructions with descriptive headings and link text. Expand unfamiliar abbreviations, such as BPM,
  and explain actionable errors in plain language.
- Keep commands and configuration examples available as selectable text. Include text explanations of important
  screenshots and diagrams; provide meaningful alternative text when adding images.
- Do not rely on colour, flashing, position or timing alone to communicate status. The plugin reports states such
  as "no session" or "peer lost" in words in its published status and messages, not only through a colour or an
  indicator on the console.
- Distinguish success, failure, uncertainty and unavailable data in the published status, so that other tools can
  present them in different ways. A missing tempo is reported as missing, not as zero.
- Beat-synchronised actions can produce flashing light. Document that operators remain responsible for keeping
  flash rates within safe limits for their audience, and do not add examples that flash faster than three times a
  second without saying so.
- When adding a user-facing interface or example, consider keyboard use, readable names and non-visual status
  feedback. Record what was actually tested and any known limitations.

## Report an accessibility barrier

Use the [bug report template](https://github.com/bdstark/gma3-beat-sync/issues/new?template=bug_report.md) for an
existing barrier or the
[feature request template](https://github.com/bdstark/gma3-beat-sync/issues/new?template=feature_request.md) for a
proposed improvement. If the issue form itself is a barrier, or you prefer a private report, email
**[bdstark@gmail.com](mailto:bdstark@gmail.com)** with the subject `gma3-beat-sync accessibility`.

Describe the task you were trying to complete, where you encountered the barrier, what happened and what would
help. If relevant and comfortable to share, include the operating system, console, assistive technology and
versions used. You do not need to disclose a disability, diagnosis or other medical information. Remove private
show data, credentials and identifying information from examples.

Reports are reviewed on a best-effort basis without a guaranteed response or fix time. If a barrier is in grandMA3
or another product, the maintainer may help identify that boundary or suggest a workaround; fixes to those products
depend on their maintainers. Accessibility reports that also expose a security vulnerability should follow the
[private security reporting process](SECURITY.md).
