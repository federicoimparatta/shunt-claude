# shunt-claude

A Claude-only port of Spotify's [shunt](https://github.com/spotify/portal-ai-plugins/tree/main/plugins/shunt) plugin for Claude Code.

shunt keeps large file reads and boilerplate generation out of your main session's context. Hooks block full reads of text files over 350 lines and point Claude at `bulk-read`, which hands the files and a question to a local `claude -p` worker on the latest Claude Haiku and returns only the answer. `code-write` generates boilerplate from a spec and a reference file straight to disk. Upstream delegates to Spotify Portal's AiKA; this port needs nothing beyond Claude Code.

## Install

```bash
claude plugin marketplace add federicoimparatta/shunt-claude
claude plugin install shunt@shunt-claude --scope user
```

New sessions pick it up; a running session needs `/reload-plugins` or a restart.

## Turn it off

```bash
SHUNT_DISABLED=1 claude                          # one session
claude plugin disable shunt@shunt-claude         # until re-enabled
claude plugin uninstall shunt@shunt-claude       # remove it
```

## Docs

Everything else (how the worker is isolated, configuration, hooks, evals, what changed from upstream) is in [plugins/shunt/README.md](plugins/shunt/README.md).

```bash
bash plugins/shunt/evals/run.sh   # 106 checks, no model calls
```

## License

Apache-2.0, see [LICENSE](LICENSE). Original work by Spotify; see [NOTICE](NOTICE) for what was modified.
