---
description: Diagnose a failed recording-rig run — examines the cast, sentinels, rendered hooks, and spec to identify the failure mode and propose a fix.
argument-hint: <session-name-or-cast-path>
allowed-tools: [Bash, Read]
---

Invoke the `diagnose` skill on `$ARGUMENTS`.

The skill walks the failure-mode taxonomy:
- Validator `FAILED`: missing required / forbidden present
- Hung before `session-start` (consent dialogs)
- Hung after `session-start` but no `prompt-submitted` (attach race / trust dialog)
- Hung after paste but no `turn-end` (slow model / unanswered AskUserQuestion)
- Companion never ran (envfile malformed / hook didn't fire)
- `must_contain_in_order` order mismatch (cursor overwrite reordering)

Reports symptom + root cause + specific fix + how to verify. Read-only — does not apply fixes.
