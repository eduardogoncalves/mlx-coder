---
name: gsd-new-project
description: Initialize a new project with planning structure (PROJECT.md, REQUIREMENTS.md, ROADMAP.md, STATE.md)
tags: [gsd, planning, project]
---

# GSD: New Project

You are initializing a new project. Your goal is to gather context, define requirements, and create a clear roadmap before any implementation begins.

## Workflow

### Step 1: Understand the Project

Ask the user (or infer from context) to answer:
1. **What are you building?** — Core purpose and value proposition.
2. **Who is it for?** — Target users or use cases.
3. **What does v1 include?** — Minimum viable scope.
4. **What is explicitly out of scope for v1?**
5. **Any technical constraints or preferences?**

If arguments were provided with this command, extract answers from them and only ask for missing information.

### Step 2: Map the Codebase (if existing code)

If the workspace already contains code, read the directory structure and key files to understand:
- Architecture patterns and conventions
- Existing dependencies and tech stack
- Current state and what's already built

Use `read_file` and `list_dir` to explore before creating any planning files.

### Step 3: Create Planning Files

Create the following files in `.planning/`:

**`.planning/PROJECT.md`**
```
# Project: [Name]

## Vision
[One paragraph describing what this project does and why it matters]

## Goals
- [Goal 1]
- [Goal 2]

## Tech Stack
- [Language/Framework]
- [Key dependencies]

## Constraints
- [Any hard constraints]
```

**`.planning/REQUIREMENTS.md`**
```
# Requirements

## v1 (In Scope)
- [ ] [Requirement 1]
- [ ] [Requirement 2]

## v2+ (Out of Scope for Now)
- [Future requirement 1]

## Non-Goals
- [What this will never do]
```

**`.planning/ROADMAP.md`**
```
# Roadmap

## Phase 1: [Name]
**Goal:** [What this phase achieves]
**Delivers:**
- [Deliverable 1]
- [Deliverable 2]

## Phase 2: [Name]
**Goal:** [What this phase achieves]
**Delivers:**
- [Deliverable 1]
```

**`.planning/STATE.md`**
```
# Project State

## Status
- Current phase: 1
- Last updated: [date]

## Decisions
| Decision | Rationale | Date |
|----------|-----------|------|

## Blockers
- None

## Quick Tasks Completed
| Task | Date |
|------|------|
```

### Step 4: Confirm and Summarize

Present the created files to the user and confirm the plan looks correct. Suggest running `/gsd-plan [phase description]` to begin planning the first phase.

## Notes
- Keep PROJECT.md under 200 lines for efficient context loading.
- Phases should be independently completable in 1–2 sessions.
- Prioritize vertical slices (full feature end-to-end) over horizontal layers (all models, then all APIs).
