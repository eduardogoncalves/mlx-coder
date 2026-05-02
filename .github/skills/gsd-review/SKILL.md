---
name: gsd-review
description: Comprehensive code review covering correctness, security, performance, and maintainability
tags: [gsd, review, quality]
---

# GSD: Code Review

You are performing a thorough code review. Analyze the code with fresh eyes, as if you had no context about implementation choices.

## Workflow

### Step 1: Determine Scope

From the arguments, determine what to review:
- A specific file or directory (if provided)
- Recent changes: `git diff HEAD~1` or `git diff main`
- A pull request's changed files
- The entire relevant module

If no scope is provided, ask: "What should I review? A file path, recent commits, or a specific area?"

### Step 2: Read the Code

Read all relevant files. For each, understand:
- What it does
- How it fits the larger architecture
- Its tests (if any)

Do NOT skip reading tests — they reveal intended behavior.

### Step 3: Review Against Six Pillars

For each file reviewed, evaluate:

#### 1. Correctness
- Does the code do what it's supposed to do?
- Are edge cases handled? (nil/null, empty collections, boundary values)
- Are error conditions handled and propagated correctly?
- Are there off-by-one errors, logic inversions, or wrong comparisons?

#### 2. Security
- Is user input validated and sanitized?
- Are there injection risks (SQL, shell, path traversal)?
- Are secrets or credentials handled safely?
- Are permissions checked before sensitive operations?

#### 3. Performance
- Are there unnecessary allocations in hot paths?
- Are there N+1 patterns or missing batch operations?
- Are large data structures copied when they could be referenced?
- Are expensive operations cached when appropriate?

#### 4. Maintainability
- Is the code easy to understand without comments?
- Are functions short and single-purpose?
- Is naming clear and consistent with project conventions?
- Is there duplicated logic that should be extracted?

#### 5. Test Coverage
- Are the critical paths tested?
- Are edge cases and error paths tested?
- Are tests independent and deterministic?
- Is test setup minimal and clear?

#### 6. Architecture
- Does this fit the existing patterns and conventions?
- Does it introduce unnecessary coupling?
- Are abstractions at the right level?

### Step 4: Write the Review

Structure findings as plain text (replace `[Scope]` with what you reviewed):

    ## Code Review: [Scope]

    ### Summary
    [2–3 sentence overview of code quality]

    ### Critical Issues (must fix)
    - **[File:line]** [Issue description and why it matters]
      - Suggestion: [Concrete fix]

    ### Improvements (should fix)
    - **[File:line]** [Issue description]
      - Suggestion: [Concrete fix]

    ### Observations (consider)
    - **[File:line]** [Minor note or style suggestion]

    ### Positives
    - [What's done well — be specific]

### Step 5: Present

Show the review. Ask:
> "Would you like me to apply any of these fixes? I can address critical issues with `/gsd-quick fix: [issue]`."

## Notes
- Be specific — "consider extracting this into a function" with a concrete example is more useful than "this is complex."
- Prioritize correctness and security issues over style.
- Acknowledge good decisions — a review that only lists problems is demoralizing and less trustworthy.
