# GenAgentOpenAI

[![CI](https://github.com/genagent/gen_agent/actions/workflows/ci.yml/badge.svg)](https://github.com/genagent/gen_agent/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/gen_agent_openai.svg)](https://hex.pm/packages/gen_agent_openai)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/gen_agent_openai)

The package source and new issues live in
[`genagent/gen_agent/integrations/openai`](https://github.com/genagent/gen_agent/tree/main/integrations/openai).
The [former repository](https://github.com/genagent/gen_agent_openai) retains
historical releases and discussions.

HTTP-direct OpenAI backend for [GenAgent](https://github.com/genagent/gen_agent),
built on [Req](https://hex.pm/packages/req).

Provides `GenAgent.Backends.OpenAI`, which talks directly to the
[OpenAI Responses API](https://platform.openai.com/docs/api-reference/responses)
(`POST /v1/responses`) and translates the response into the
normalized `GenAgent.Event` values the state machine consumes.

Unlike the CLI-backed backends (`gen_agent_claude`, `gen_agent_codex`),
this backend:

- Talks HTTP, not a subprocess
- Has **no tool use** by default (pure text in/text out)
- Tracks conversation state via the API's server-side
  `previous_response_id`, so multi-turn works without resending
  the full history each turn
- Is the simplest backend to use for HTTP-only workflows or when
  you do not want a CLI dependency

## Responses API vs Chat Completions

This backend targets the **Responses API** (`/v1/responses`), not
Chat Completions. The Responses API is OpenAI's newer agent-first
primitive and is a much cleaner fit for `GenAgent`:

- Server-side state via `previous_response_id` means the session
  struct only has to track one id across turns, not a messages
  array.
- Reasoning models (o1/o3/o4/gpt-5) surface reasoning items in the
  output array; this backend ignores them for text extraction but
  surfaces `reasoning_tokens` in the `:usage` event so patterns
  can reason about cost.
- Built-in tools, streaming, and structured outputs are available
  in future versions without redesigning the session shape.

If you specifically need Chat Completions, open an issue and we
can add `GenAgent.Backends.OpenAI.ChatCompletions` alongside.

## Prerequisites

You need an OpenAI API key. Set `OPENAI_API_KEY` in your
environment, or pass `:api_key` as a backend option.

## Installation

```elixir
def deps do
  [
    {:gen_agent, "~> 0.3.0"},
    {:gen_agent_openai, "~> 0.2.0"}
  ]
end
```

## Quick start

```elixir
defmodule MyApp.Assistant do
  use GenAgent

  defmodule State do
    defstruct responses: []
  end

  @impl true
  def init_agent(_opts) do
    backend_opts = [
      instructions: "You are a concise, helpful assistant.",
      max_output_tokens: 512
    ]

    {:ok, backend_opts, %State{}}
  end

  @impl true
  def handle_response(_ref, response, state) do
    {:noreply, %{state | responses: state.responses ++ [response.text]}}
  end
end

{:ok, _pid} = GenAgent.start_agent(MyApp.Assistant,
  name: "my-assistant",
  backend: GenAgent.Backends.OpenAI
)

{:ok, response} = GenAgent.ask("my-assistant", "Explain OTP gen_statem in one sentence.")
IO.puts(response.text)
```

## Session continuation

The Responses API is **stateful server-side**. Each response is
stored for 30 days and can be referenced via `previous_response_id`
in the next request. This backend threads one id across turns:

```elixir
# Turn 1: fresh conversation, no previous_response_id
{:ok, r1} = GenAgent.ask("my-assistant", "Remember the number 42")
# Turn 2: backend sends previous_response_id = r1.response_id
# OpenAI replays turn 1's context on the server side
{:ok, r2} = GenAgent.ask("my-assistant", "What number did I ask you to remember?")
# r2.text =~ "42"
```

The `previous_response_id` lives on the session struct and is
updated via `update_session/2` when each terminal `:result` event
lands. `store: true` is sent on every request (the default) so
responses remain referenceable.

## Instructions do not persist across turns

OpenAI's docs are explicit: instructions from a prior turn do
**not** carry over when you chain via `previous_response_id`. This
backend therefore resends `:instructions` on every request when
the option is set. The per-turn token cost is tiny, but the
invariant matters -- a future optimization that "only sends
instructions once" would silently break system-prompt behavior on
every turn after the first.

## Backend options

- `:api_key` -- OpenAI API key. Defaults to
  `System.get_env("OPENAI_API_KEY")`.
- `:model` -- model name. Defaults to `"gpt-5"`.
- `:instructions` -- system prompt (string). Resent every turn.
- `:reasoning_effort` -- one of `:low | :medium | :high | nil`.
  When set, requests a specific reasoning effort for o1/o3/o4/gpt-5.
- `:max_output_tokens` -- cap on output tokens per turn. Defaults
  to `nil` (model default).
- `:http_fn` -- a 1-arity function
  `(request_map) -> {:ok, response_map} | {:error, term}`
  that replaces the default `Req`-backed HTTP call. Intended for
  tests that want to stub out the API.

See `GenAgent.Backends.OpenAI` for the full module docs.

## Why no tool use?

This backend is deliberately minimal: text in, text out. The
Responses API supports built-in tools (web search, file search,
code interpreter) and custom function tools, but adding them
means a richer event surface and roundtripping tool results --
better served by a future version or by using `gen_agent_claude`
if you want tool-using agents today.

## Testing

```bash
mix test
```

Unit tests stub the HTTP layer via the `:http_fn` backend option,
so no tokens are burned during `mix test`.

Live tests (tagged `:integration`) hit the real API and require
`OPENAI_API_KEY` in the environment:

```bash
mix test --only integration
```

## License

MIT. See [LICENSE](LICENSE).
