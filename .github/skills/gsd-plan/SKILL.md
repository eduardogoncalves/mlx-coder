---
name: gsd-plan
description: Research and create a structured execution plan with XML task format and verification steps
tags: [gsd, planning, tasks]
---

# GSD: Plan Task

You are in planning mode. Your goal is to research the problem, then produce a clear, atomic, executable plan in XML format before touching any code.

## Workflow

### Step 1: Understand the Task

Read the task description provided in the arguments. If it's ambiguous, ask one clarifying question before proceeding.

### Step 2: Research the Codebase

Before planning, investigate:
- Existing patterns and conventions in the relevant code areas
- Files that will need to change
- Potential conflicts or dependencies
- Test infrastructure to verify changes

Use `read_file`, `list_dir`, `bash` (grep/find) to explore. Do NOT modify any files during research.

### Step 3: Create the Plan

Write `.planning/PLAN.md` with the following structure:

```markdown
# Plan: [Task Name]

## Goal
[One sentence: what success looks like]

## Research Summary
[2–3 bullet points of key findings from Step 2]

## Tasks

<task>
  <name>[Descriptive task name]</name>
  <files>[path/to/file1.swift, path/to/file2.swift]</files>
  <action>
    [Precise implementation instructions. Include:
    - Exact function/class/method names to add or modify
    - Logic changes with clear before/after intent
    - Any imports or dependencies needed]
  </action>
  <verify>[Build/test command to confirm this task is correct, e.g., swift build, swift test --filter TestSuiteName]</verify>
  <done>[Clear, observable success criterion]</done>
</task>

<task>
  ...
</task>

## Commit Message
[feat/fix/refactor: concise description]
```

### Step 4: Verify Plan Quality

Check the plan before presenting it:
- [ ] Each task modifies at most 2–3 files
- [ ] Each `<verify>` step is runnable and specific
- [ ] Tasks are sequenced (dependencies respected)
- [ ] The plan covers the full requirement — nothing silently dropped
- [ ] No single task is so large it could fail mid-way and leave things broken

### Step 5: Present and Await Approval

Show the plan to the user. Ask:
> "Does this plan look correct? Type `/gsd-execute` to run it, or describe changes."

Do NOT execute any plan steps until the user explicitly approves.

## Notes
- Prefer vertical slices: one task = one complete feature path, not one layer.
- If the task requires more than 5 subtasks, break it into phases.
- If the codebase uses a specific test framework, always include a test task.
