---
name: code-writer
description: "Delegate boilerplate code generation to a local Claude Haiku worker that writes straight to disk. Use for tests, config, docstrings, type stubs, or any generation where more than 80% is predictable from a reference file."
---

```bash
# Generate and write directly to the target file
"${CLAUDE_PLUGIN_ROOT}/scripts/code-write" --spec "<what to generate>" --reference <reference-file> --target <output-path>

# Output to stdout instead (omit --target)
"${CLAUDE_PLUGIN_ROOT}/scripts/code-write" --spec "<what to generate>" --reference <reference-file>
```

The worker is `claude -p` on the latest Claude Haiku with no tools. It sees the spec and the
reference file and matches the reference's patterns, naming and style. `--reference` is
required: without it the output would match nothing in the project. Markdown fences are
stripped from the output. `--target` overwrites an existing file, so point it at a new path
unless replacing the file is the intent.

Each call is independent. To build on what was just generated, pass that file as the
`--reference` for the next call.

Review the output and make surgical edits for the 5 to 20% that needs your judgment.

Do not delegate:

- **Debugging or fixing code**: that needs your reasoning, not generation from a pattern
- **Edits to existing files**: make those yourself on the exact content
- **Small snippets**: a few lines are cheaper to write yourself
- **Architectural decisions**: design choices stay with you
