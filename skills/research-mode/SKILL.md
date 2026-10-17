---
name: research-mode
description: Inspect current Windows memory use and prepare a user-reviewed temporary research mode for local Python or PyTorch work. Use for identifying optional background apps, applying reviewed shutdown choices, and restoring a recorded session.
---

# ResearchMode

Use the bundled deterministic Windows tool to inspect current applications, explain tradeoffs, prepare a concrete plan, and carry out the user's reviewed choices.

## Locate the runtime

In an installed skill, the entry point is `scripts/ResearchMode.ps1` relative to this SKILL.md. In the source repository, use `ResearchMode.ps1` at the repository root instead. Resolve the absolute path and invoke it from PowerShell. Do not rewrite shutdown logic in ad hoc commands.

## Workflow

- Run `-Action Scan -Json` first. Interpret the current snapshot, not an earlier scan. It groups applications by executable path; unreadable identities remain unresolved. The HTML report produced by a non-JSON scan contains all applications and local paths.
- Use the user's actual research context. The built-in version targets local Python/PyTorch: keep running computations, GPU drivers, terminals and useful network connections. Audio, eye-tracking and remote-computing work can require programs that look optional in local training. Explain uncertainty for unknown programs; filename or publisher text alone is not proof of identity or purpose.
- Suggest a small relevant set, explaining each application's purpose, current resident memory, effect of closing, available method, and recovery limits. `candidate` is a review suggestion, not permission. `manual` security software is user-reviewable through vendor-supported controls; do not interpret default retention as a ban on the user's choice. This version does not automate those vendor controls or track their manual restoration.
- Create the plan using `-Action Plan -Ids <actual ids> -Method close|terminate|service -Json`. Add `-Remember` only if the user wants reusable approval. Use `-UseSaved` for explicitly requested activation of existing preferences. This always re-scans and verifies file identities.
- Present the concrete plan before new approval: names, paths, method, relevant consequences, services, and recovery limits. Reuse clear authorization already given for these exact actions or saved preferences. Approval to build/test this tool does not authorize closing the user's real apps.
- Preserve the returned `Path` and `PlanHash`. `-Action Apply -PlanPath <path> -WhatIf` previews without stopping anything. Execute with `-PlanHash <reviewed hash> -Approved` only when the user's authorization covers the reviewed actions. Do not amend a plan or broaden its scope after approval. Expired or changed identities require a new plan.
- Report actual action states and observed available-memory change. Do not claim a service or process stopped unless the session says so. An application may remain in the tray or restart itself; do not repeatedly kill it.
- For recovery, inspect the recorded session and call `-Action Restore -SessionPath <path> -Approved` when requested. `-WhatIf` is available. Restarting a program does not recover unsaved data, previous command-line arguments, original windows or running tasks. Interrupted or partial actions require manual verification.

Commands `-Action Approvals`, `-Action Forget -Ids <id>`, and `-Action Sessions` inspect/revoke preferences and list local sessions. Runtime data defaults to `%LOCALAPPDATA%/ResearchMode`; never upload scans, approval files, plans or journals without a specific user request and review for private information. Do not automatically elevate privileges or bypass vendor self-protection. Protected items rejected by the tool remain outside its automated scope.
