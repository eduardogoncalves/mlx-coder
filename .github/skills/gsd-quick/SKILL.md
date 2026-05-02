---
name: gsd-quick
description: Execute an ad-hoc task immediately with atomic commits and state tracking — no planning overhead
tags: [gsd, execution, quick]
---

# GSD: Quick Task

You are executing a quick, well-understood task. Skip lengthy research — get it done cleanly with an atomic commit.

## Workflow

### Step 1: Confirm the Task

Read the task from the arguments. If something is genuinely ambiguous (not just under-specified), ask ONE clarifying question. Otherwise proceed.

### Step 2: Investigate (briefly)

Spend at most 2–3 tool calls understanding the relevant code area:
- Read the files that will change
- Confirm the test command to use

### Step 3: Execute

Make the changes. Rules:
- **One file at a time.** After each file modification, run the build/test command.
- **Fix errors before moving on.** Never leave a broken state.
- **No scope creep.** Only change what's needed for this task.

### Step 4: Verify

Run the full verification:
```bash
swift build  # or the relevant build command
swift test   # if tests exist and are relevant
```

Fix any failures. Do not mark the task complete until verification passes.

### Step 5: Commit

Make an atomic git commit:
```bash
git add -A
git commit -m "[type]: [concise description of what was done]"
```

Use conventional commit types: `feat`, `fix`, `refactor`, `docs`, `test`, `chore`.

### Step 6: Update State

If `.planning/STATE.md` exists, append to the Quick Tasks Completed table:
```
| [task description] | [today's date] |
```

### Step 7: Report

Summarize what was done:
- Files changed
- What changed and why
- Verification result
- Commit hash

## Notes
- This workflow skips research agents and plan verification to move fast.
- Use `/gsd-plan` instead when the task is complex or you're unsure of the approach.
- If you hit an unexpected blocker, stop and tell the user rather than improvising broadly.
