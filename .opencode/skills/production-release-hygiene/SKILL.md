---
name: production-release-hygiene
description: Use when iterating on production-deployed code, managing Git tags, handling multi-host rollouts, or writing user-facing shell instructions. Covers tag immutability, diagnose-before-code workflow, batched commits, pre-flight checklists, canary deployments, environment-aware messages, and copy-paste safe command output.
---

# Production Release Hygiene

## When to Use

Every time you iterate on code that is already deployed to production hosts with an existing tag, and real users (or you) are running `git pull && make start/restart/update`.

## Rules

### 1. Tags Are Immutable Checkpoints, Not Draft Paper

A Git tag (e.g. `v2026.09.25`) must represent a point that has survived at least one real host without critical errors. If you need twenty micro-fixes before stability, iterate on `main` first; move or create the tag only after validation.

- **Allowed:** Iterate on `main` with frequent commits, then tag once stable.
- **Forbidden:** Force-push a tag (`git push --force origin vX.Y.Z`) more than once per session. If a post-tag bug appears, the next iteration is `vX.Y.Z+1`, not a rewound tag.

### 2. Diagnose Before You Code

The user reports an error. Do not edit files and commit within the first 60 seconds.

1. Ask for the **exact error message** and **full command output**.
2. Ask for **logs** (`make logs <service>`, `journalctl`, `docker logs`).
3. Determine if the issue is:
   - **Local state** (stale Docker cache, old image, un-pulled repo).
   - **Global bug** (code error, missing dependency, bad config).
4. Only then propose a fix.

### 3. Batch Related Changes into Logical Commits

A session that touches the same script fifteen times for tiny adjustments produces noisy history and makes rollbacks painful.

- **Bad:** 15 commits: "fix typo", "change number", "add return 0", "fix echo quotes"…
- **Good:** One commit: `fix: hardening check on LXC — PAM paths, sysctl discovery, fd-limit threshold`.

If you must iterate rapidly, do it locally without pushing. Push once the logical unit is coherent.

### 4. Pre-Flight Checklist Before Every Commit

Run this mental checklist before `git commit`:

- [ ] **Syntax:** `bash -n script.sh`, `python -m py_compile file.py`, etc.
- [ ] **Diff review:** Read the complete diff. Does it have unintended side effects?
- [ ] **Copy-paste safety:** If the script prints commands for the user to execute, paste them into a scratch terminal to verify they run verbatim.
- [ ] **Magic numbers:** If you changed a threshold (e.g. `65535` vs `65536`), is it consistent everywhere (code, messages, docs)?
- [ ] **One host first:** Has at least one production host validated this change?

### 5. Canary Host, Then the Fleet

If there are multiple production hosts (e.g. Oracle, Bespin, Alderaan), designate **one** as the canary.

1. Apply the fix to the canary.
2. Run `make start` and verify health.
3. Only then tell the remaining hosts to `git pull && make restart`.

This prevents a bad commit from propagating to every host simultaneously.

### 6. Environment-Specific Instructions

When a check behaves differently across environments (LXC vs bare metal, Debian 12 vs 13), do not give generic instructions.

- Detect the environment in code (`systemd-detect-virt`, `uname`, `/proc/1/cgroup`).
- Branch the message so the user sees **only** the commands relevant to their setup.
- Never tell an LXC user to run `systemctl daemon-reexec`.

### 7. Command Output Is a Contract

Any string your script prints to the terminal is a user-facing API. If the user copies and pastes it, it must work.

- Use `echo '...'` (single quotes) for literal output.
- Avoid backslash escapes (`\$`, `\"`) in user-facing messages; they break copy-paste.
- If a heredoc is involved, ensure the terminator is at column 0 and has no leading spaces.

### 8. Tag Hygiene Summary

| Situation | Action |
|-----------|--------|
| Pre-release iteration | Commit to `main`, no tag |
| First stable validation | Create tag `vYYYY.MM.DD` |
| Bug found after tag | Fix on `main`, create `vYYYY.MM.DD+1` |
| Urgent hotfix on tag | Create `vYYYY.MM.DD-hotfix.N`, never force-push original tag |

---

*Created to prevent the "20 force-pushed tags in one afternoon" anti-pattern.*
