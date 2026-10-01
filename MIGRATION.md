# Source repository migration

The public Hex package and Elixir module names are unchanged. Applications
using published packages do not need a new dependency name. Update local
source paths and repository links when moving to this checkout:

| Package | New source | Previous repository |
| --- | --- | --- |
| `gen_agent_claude` | [`integrations/claude`](integrations/claude) | [`gen_agent_claude`](https://github.com/genagent/gen_agent_claude) |
| `gen_agent_codex` | [`integrations/codex`](integrations/codex) | [`gen_agent_codex`](https://github.com/genagent/gen_agent_codex) |
| `gen_agent_anthropic` | [`integrations/anthropic`](integrations/anthropic) | [`gen_agent_anthropic`](https://github.com/genagent/gen_agent_anthropic) |
| `gen_agent_openai` | [`integrations/openai`](integrations/openai) | [`gen_agent_openai`](https://github.com/genagent/gen_agent_openai) |
| `gen_agent_ensemble` | [`extensions/ensemble`](extensions/ensemble) | [`gen_agent_ensemble`](https://github.com/genagent/gen_agent_ensemble) |

The previous repositories retain their historical issues, pull requests, and
tags. File new source issues and pull requests in
[`gen_agent`](https://github.com/genagent/gen_agent). The
[`claude_wrapper`](https://github.com/genagent/claude_wrapper_ex) and
[`codex_wrapper`](https://github.com/genagent/codex_wrapper_ex) repositories
remain independent.

For local development, use this repository and run Mix from the package
directory. The sibling Mix projects resolve core and each other by path.
For a publishable archive, set `GEN_AGENT_HEX=1` so the dependencies resolve
from Hex instead. See [RELEASING.md](RELEASING.md) for release order and tags.
