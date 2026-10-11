# Claude instruction validation (2026-10-11)

[简体中文](claude-instruction-validation.md) | English

This report records the validation performed for CodeJump 0.3.0. Private project and entry-class names have been anonymized for publication. Numerical results are unchanged from the original record; anonymizing this document did not involve rerunning the experiments. Private source code and the model's original business analysis are not part of the public repository.

CodeJump 0.3.0 added installation, editing, reset, removal, and backup of global reference rules. The app's own editor wrote the rules into a managed block in `~/.claude/CLAUDE.md`, preserving other instructions. The final recommended text was 375 characters, down from 1,128 characters, a reduction of approximately 67%.

## Method

Tests used Claude Code 2.1.294 with the model `anthropic/claude-opus-5-5`. Each case started a new session and received only the single task shown below. No additional formatting request, correction message, or extra system prompt was supplied; instruction loading used Claude Code's global-file mechanism.

Two synthetic projects supported strict checks of paths, class names, duplicate symbols, and cross-project ownership. A third case used a private Java shipping project. Only Read, Glob, and Grep were allowed. An inherited legacy proxy initially caused HTTP 405 errors. The test subprocess alone was configured to reuse the existing local gateway route and bypass the proxy for loopback; persistent model and proxy settings were not changed.

A temporary local forwarding process checked whether actual model requests contained the installed rule text. It recorded a Boolean result and SHA-256, not request bodies or credentials. Claude's loader removes HTML management comments, so validation checked the rule body rather than the full commented file. In the final batch, **16/16 requests** contained the complete rule body and its global-file source attribution.

## Short task prompts

The prompts were submitted in Chinese; they are preserved below except for the private entry-class name.

| Case | Task prompt (private entry anonymized) | Source | Final links |
| --- | --- | --- | ---: |
| Same project | 分析下 PackageApplicationService.createPackage 的代码调用链路，给出符号链接。 | Synthetic source | 11 |
| Cross-project | 分析下 DispatchApplicationService.dispatch 的跨项目代码调用链路，给出符号链接。 | Synthetic source with two classes named ValidationHelper | 10 |
| Real project | 分析下 `<entry class>` 的代码调用链路，给出符号链接。 | Private Java shipping project | 44 |

`<entry class>` is a publication-only placeholder. The real test used the private project's actual class name. The synthetic-case prompts have not been rewritten. Each prompt asks Claude to analyze the named entry's call chain and provide symbol links.

## Findings and instruction changes

The original 49-line instruction produced 61 valid file links, but three labels used location descriptions such as “line N” or “call site.” Cross-project paths were relative to a shared workspace instead of the owning project root. An initial shorter revision fixed cross-project paths but still occasionally produced location-only labels.

The final change strengthened one rule: fields, call sites, and repeated locations should also use the owning class or method as their label, with a final label check before answering. Individual task prompts were not expanded, and examples were not repeatedly added. Final-batch results:

- **65/65 links** used actual, complete symbols as labels, pointed to existing files with valid line numbers, and avoided local absolute paths in the response body.
- **40/40 method links** pointed to lines within the corresponding method.
- **10/10 cross-project links** used paths relative to the owning project root with correct project labels. Same-project references did not add unnecessary project names.
- One strict class-body check had an exception: a class-level link pointed to an import line in its owning file to explain a dependency. It was recorded separately and did not point to the wrong file or method.

## Actual CodeJump resolution

Each original Markdown link was independently passed through the release CLI parser/resolver with the corresponding case's project index. **65/65 were recognized and produced candidates for the correct project, file, and original line number.** Two overloaded-method references in the private project retained a selection step; alternative overload candidates were not automatically opened.

The app's cross-project label handling was also corrected: both Markdown and Accessibility links retain the project name in the label. If the label and target disagree, the target evidence is preserved and confirmation is required.

## Application checks and limitations

- **103 Swift tests passed**, including preservation of unrelated instructions, exact migration of legacy rules, backups, external-edit conflicts, malformed markers, symlinks, UTF-8/BOM/CRLF, permissions, and link parsing regressions.
- Native UI checks covered reading the old rules, resetting to the short version, manual edits, saving and reading back, backup contents, and preserving unsaved drafts across closing and reopening the editor.
- Accessibility permission persisted after an update using the same stable signing identity.
- These results cover a limited sample of real model outputs and actual core-resolution checks. They do not guarantee that future model outputs always comply or that every Claude Desktop rendering and hover-reading scenario has been tested.

Original outputs, request-loading evidence, and per-link reports remain local. Business-analysis text and credentials were not published. This is an anonymized historical validation summary, not a public dataset for complete independent reproduction.
