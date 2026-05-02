---
name: gsd-debug
description: Systematic debugging using the scientific method — gather symptoms, form hypotheses, test and isolate
tags: [gsd, debugging, investigation]
---

# GSD: Debug

You are investigating a bug or unexpected behavior. Follow the scientific method: observe, hypothesize, test, conclude.

## Workflow

### Step 1: Gather Symptoms

If not already provided in the arguments, ask the user:
1. **Expected behavior** — What should happen?
2. **Actual behavior** — What happens instead? Include exact error messages.
3. **Reproduction steps** — How do you trigger it reliably?
4. **When did this start?** — Was it ever working? What changed?

### Step 2: Initial Evidence

Before forming a hypothesis, collect objective evidence:
- Read error messages and stack traces carefully
- Check relevant log output
- Look at the code path that leads to the failure
- Run the reproduction steps yourself: `bash` the relevant command

Do NOT guess yet. Collect facts.

### Step 3: Form Hypotheses

Based on evidence, list 2–3 candidate root causes in order of likelihood:
```
Hypothesis 1: [Most likely cause]
Hypothesis 2: [Second candidate]
Hypothesis 3: [Edge case]
```

### Step 4: Test Hypotheses (Elimination)

For each hypothesis, design a minimal test:
- Add a targeted log or assertion
- Run a specific test case
- Isolate the code path

After each test, record:
- What you observed
- Whether the hypothesis is confirmed, eliminated, or inconclusive

Continue until one hypothesis is confirmed as root cause.

### Step 5: Fix

Once the root cause is confirmed:
- Make the minimal change that fixes it
- Avoid over-engineering — fix the specific bug
- Add a regression test if possible

Run full verification:
```bash
swift build
swift test --filter [RelevantTestName]
```

### Step 6: Commit

```bash
git add -A
git commit -m "fix: [concise description]\n\nRoot cause: [one sentence]\nFix: [one sentence]"
```

### Step 7: Report

Summarize:
- **Root cause:** What the actual problem was
- **Fix:** What was changed
- **Prevention:** How to avoid this class of bug in future (if applicable)

## Notes
- Never apply a fix before confirming the root cause. Guessing wastes time.
- If you can't reproduce the issue, say so — don't debug in the dark.
- If the investigation reveals a larger systemic problem, report it but don't fix it in this session.
