---
name: bulk-reader
description: "Delegate bulk reading of text files to a local Claude Haiku worker so the files never enter your context. Use when you need an answer about files rather than their exact text: text files over 350 lines, questions across 3+ files, or summaries of large diffs or logs."
---

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/bulk-read" --question "<question>" --paths <file1> [<file2> ...]
```

The worker is `claude -p` on Claude Haiku 4.5 with no tools: it sees only the files you pass
and your question, and you see only its answer. Each call is independent. To ask a follow-up,
ask again with the same `--paths`; re-sending the files costs you nothing.

- Lines are numbered for the worker, so the line numbers it cites are exact. Feed them to a
  targeted Read (`offset`/`limit`) when you need the real text.
- Verify specific line numbers or exact values before using them in edits.
- Text only. Read images and PDFs with the Read tool directly.
- To summarize a diff or command output, save it to a file first
  (`git diff main > /tmp/review.diff`), then pass that file.
- One request must fit the worker's context window (about 600 KB by default). Split larger
  sets into several calls.

Do not delegate:

- **Debugging**: it needs your reasoning over the real code, not a summary
- **Editing**: you need exact content in context; Read just the section with `offset`/`limit`
- **Small files**: under 350 lines, delegation costs more than it saves
- **Architectural decisions**: judgment calls stay with you
