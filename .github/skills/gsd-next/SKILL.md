---
name: gsd-next
description: Auto-detect the current project state and run the next logical step in the workflow
tags: [gsd, workflow, navigation]
---

# GSD: Next Step

You are auto-advancing the workflow. Read the project state and determine what needs to happen next.

## Workflow

### Step 1: Read Project State

Check for planning files in order of priority:

1. **`.planning/STATE.md`** — Current phase, blockers, last action
2. **`.planning/ROADMAP.md`** — Phases and their status
3. **`.planning/PLAN.md`** — Active plan (if one exists)
4. Recent git log: `git log --oneline -10`

If none of these files exist, suggest running `/gsd-new-project` to initialize.

### Step 2: Determine Next Action

Based on what you found, select ONE of these next actions:

| Situation | Next Action |
|-----------|-------------|
| No `.planning/` directory | Run `/gsd-new-project` workflow |
| PROJECT.md exists but no ROADMAP.md | Ask user to describe what to build next |
| ROADMAP.md exists, no PLAN.md for current phase | Run `/gsd-plan [phase description]` workflow |
| PLAN.md exists, tasks not started | Begin executing the first task in the plan |
| PLAN.md exists, some tasks done | Continue with the next incomplete task |
| All plan tasks done, not committed | Run verification + commit |
| Phase complete | Update STATE.md and ask if ready for next phase |
| Blockers listed in STATE.md | Report the blockers and ask user how to resolve |

### Step 3: Execute the Next Action

Perform the identified next action automatically. Don't ask for confirmation unless:
- The next action is irreversible (e.g., deleting files, pushing to remote)
- There are multiple equally valid options

### Step 4: Report

After completing the next action:
- What state was detected
- What action was taken
- What comes after this

## Notes
- This is an orchestrator skill — it reads state and delegates to the right workflow.
- If you're unsure what the next step is, err on the side of asking rather than guessing.
- Always update STATE.md after completing a phase or significant milestone.
