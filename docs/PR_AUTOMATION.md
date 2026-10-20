# Review and merge automation

This repository calls an immutable revision of the shared MIT-licensed automation in gma3-mcp. The review reads this
repository's GPL licence, instructions, Lua/peer code and tests independently. The shared workflow is infrastructure;
no product implementation is copied between repositories.

Setup: add the repository Actions secret `OPENAI_API_KEY` (OpenAI API billing applies). Add Actions variables
`PR_AUTOMATION_ENABLED=true` and `PR_MERGE_ENABLED=false`. Merge this policy change manually and dispatch
**Actions → PR automation** for a review-only smoke test. Missing credentials leave the review unsuccessful.

After the review-only smoke tests pass, allow GitHub Actions to create/approve pull requests in Settings → Actions →
General, and set `PR_MERGE_ENABLED=true`. Keep default token permissions read-only. The shared workflow requests
write permission only for trusted publication and controller jobs. The chat monitor should remain until the end-to-end
handoff is verified. This PR does not activate either switch.

The second review is a read-only offline Codex pass; it does not run candidate code with secrets or test a live console.
The existing CI builds/tests the Lua and Link peer code. Approval and SHA-guarded squash merge require clean official
code **and security** reviews, a clean independent review for the exact head/base, successful current-base CI, no
unresolved discussions and GitHub mergeability. Only owner-authored, same-repository, non-draft PRs to main are eligible.
Workflow, Codex-policy and AGENTS.md changes require manual merge. GitHub's server-side protections are still enforced.

Cleanup preserves protected, advanced and default branches. It retargets stacked PRs first and retains the parent branch
until the children are rebased and checked; dispatch the merged parent PR number to retry deletion afterwards.
Set `PR_MERGE_ENABLED=false` to stop mutation jobs or `PR_AUTOMATION_ENABLED=false` to stop the entire service.

Full policy, limitations and controller tests are maintained at the exact revision pinned in the workflow:
https://github.com/bdstark/gma3-mcp/blob/c708e1d91e84edc1de94562ab4e4c12943169980/docs/PR_AUTOMATION.md

After resolving the last discussion, bdstark can post `/accept` to reevaluate all gates without repeating a completed independent review.

Merges and cleanup serialize repository-wide. Deletion uses an atomic Git SHA lease. An explicit workflow dispatch rescans other PRs after a GITHUB_TOKEN merge; stale-base CI still requires a rebase before acceptance.
