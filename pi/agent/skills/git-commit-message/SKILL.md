---
name: git-commit-message
description: Use this skill whenever the user asks to generate, write, draft, or suggest a git commit message - including phrases like "write a commit message", "generate a commit", "draft a commit", "commit these changes", "what should the commit message be", or any request to summarize staged/unstaged changes for a commit. Enforces a strict format - a Conventional Commits summary line, a blank line, then a `- ` bullet list describing each change aspect, in English only. When the working tree contains large or logically unrelated changes, the agent must first group them into logical clusters and propose splitting them into multiple commits. Always invoke this skill before producing any commit message text.
---

# Git Commit Message Generator

## When to use

Invoke this skill whenever the user asks for a git commit message in any form:

- "write / generate / draft / suggest a commit message"
- "commit these changes"
- "what should the commit message be?"
- any request to summarize staged or unstaged changes for a commit

Do NOT produce commit message text without first invoking this skill.

## Workflow

1. Inspect the actual changes. Prefer staged changes as the primary source:
   - `git diff --cached` (staged)
   - `git diff` (unstaged) and `git status` for context if needed
2. Group the changes into logical clusters, each cluster covering one coherent concern (one feature, one bug fix, one refactor, one documentation update, ...). Files belonging to the same feature or fix belong in the same cluster even if they touch several paths.
3. Decide: one commit or several?

   **Prefer a single commit** when the changes are small and coherent.

   **Split into multiple commits** when any of these holds:
   - The changes mix multiple unrelated concerns (e.g. a feature + an unrelated bug fix + a docs update).
   - The diff is large (many files / thousands of lines) and can be decomposed into independently meaningful units.
   - Different clusters need different Conventional Commits types (e.g. partly `feat`, partly `fix`, partly `chore`).
   - A reviewer would want to revert or cherry-pick one part without the rest.

4. When splitting, order the commits by dependency: foundational/refactor/config commits first, then fixes, then features. Each commit must leave the tree in a buildable/reasonable state when possible; call out cases where strict independence is impractical.
5. Write each commit message strictly in the format below, one message per commit.
6. Present each message inside its own fenced code block so it can be copied verbatim. Do not prepend `git commit -m` or extra commentary inside the block unless the user explicitly asked for the full command. When proposing multiple commits, add one short line above the list of blocks explaining the split (e.g. "Split into N commits:") and optionally note the suggested commit order.
7. If the user asked to actually commit (not just draft), commit the clusters one by one in order - use `git add` on the relevant paths (or `git add -p` for partial staging) before each `git commit`, passing the exact message via multiple `-m` flags or `-F`. Only commit when the user asks.

## Format (strict)

1. **Language**: English only. Exceptions allowed for proper nouns and established technical terms with no clear English equivalent (product names, framework identifiers, file paths, code symbols, config keys, etc.).

2. **First line (summary)**:
   - One concise sentence.
   - Prefixed with a Conventional Commits type and a colon: `feat:`, `fix:`, `refactor:`, `docs:`, `style:`, `test:`, `chore:`, `perf:`, `build:`, `ci:`, or `revert:`.
   - Imperative mood ("Add", not "Added").
   - Under ~72 characters when practical.
   - No trailing period.

3. **Body**:
   - Exactly one blank line after the summary.
   - Then an unordered list. Each item:
     - starts with `-`;
     - describes exactly one aspect of the change (what was added / changed / fixed / removed);
     - leads with an action verb (Add, Update, Fix, Remove, Refactor, Rename, Upgrade, Normalize, ...);
     - is specific enough to stand alone - mention the file, module, symbol, or config when relevant.

4. **Multiple commits**: each commit gets the same shape (summary + blank line + list), as a separate message.

## Conventional Commits type reference

| Type | Use for |
| ------ | --------- |
| `feat` | A new feature |
| `fix` | A bug fix |
| `refactor` | Code change that neither fixes a bug nor adds a feature |
| `docs` | Documentation only |
| `style` | Formatting, whitespace, line endings; no code change |
| `test` | Adding or correcting tests |
| `chore` | Build, deps, tooling, configs; no production code |
| `perf` | Performance improvement |
| `build` | Build system or external dependencies |
| `ci` | CI configuration / scripts |
| `revert` | Reverting a previous commit |

## Example: single commit

```
refactor: standardize mobile-uniapp and expand CLAUDE.md

- Expand CLAUDE.md with comprehensive tech stack, dev commands, and deployment architecture
- Upgrade sass from ^1.32.13 to ^1.78.0 in mobile-uniapp
- Add WeChat mini-program config files (project.config.json, project.private.config.json)
- Update WeChat mini-program settings (appid: wx01d291276c880a48, disable urlCheck)
- Fix CSS calc() spacing and line endings across multiple files
- Add backward-compatible exports in utils/index.js (VUE_APP_API_URL, formatTime, parseTime)
- Add API stubs for reservation and order endpoints in activity.js, order.js, user.js
- Add box-sizing: border-box rule for H5 platform
- Normalize file line endings (CRLF to LF) across component files
```

## Example: split into multiple commits

When the changes mix unrelated concerns, present one block per commit, in dependency order:

```
Split into 3 commits:

1) chore: upgrade sass and normalize line endings

- Upgrade sass from ^1.32.13 to ^1.78.0 in mobile-uniapp
- Normalize file line endings (CRLF to LF) across component files

2) fix: correct CSS calc() spacing across mobile-uniapp stylesheets

- Fix CSS calc() spacing and line endings in header.vue, list.vue, detail.vue

3) feat: add reservation and order API stubs

- Add API stubs for reservation and order endpoints in activity.js, order.js, user.js
- Add backward-compatible exports in utils/index.js (VUE_APP_API_URL, formatTime, parseTime)
```

(The three fenced code blocks are omitted here for brevity; in a real output each commit message appears inside its own triple-backtick block.)

## Checks before sending

- Decided explicitly whether the changes warrant one commit or several; if several, each commit is a distinct logical concern and ordering is noted.
- Each summary line is a single sentence with a type prefix, no trailing period.
- Exactly one blank line separates summary and list.
- Every body line starts with `-`.
- Each bullet is one aspect; split merged concerns into separate bullets.
- English only (except allowed terms).
- Messages are shown in copyable code blocks (one block per commit).
