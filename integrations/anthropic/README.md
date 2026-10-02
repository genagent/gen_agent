# GenAgentAnthropic

[![CI](https://github.com/genagent/gen_agent/actions/workflows/ci.yml/badge.svg)](https://github.com/genagent/gen_agent/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/gen_agent_anthropic.svg)](https://hex.pm/packages/gen_agent_anthropic)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/gen_agent_anthropic)

The package source and new issues live in
[`genagent/gen_agent/integrations/anthropic`](https://github.com/genagent/gen_agent/tree/main/integrations/anthropic).
The [former repository](https://github.com/genagent/gen_agent_anthropic) retains
historical releases and discussions.

HTTP-direct Anthropic backend for [GenAgent](https://github.com/genagent/gen_agent),
built on [Req](https://hex.pm/packages/req).

Provides `GenAgent.Backends.Anthropic`, which talks directly to the
[Anthropic Messages API](https://docs.anthropic.com/en/api/messages)
and translates the response into the normalized `GenAgent.Event`
values the state machine consumes.

Unlike the CLI-backed backends (`gen_agent_claude`, `gen_agent_codex`),
this backend:

- Talks HTTP, not a subprocess
- Has **no tool use** by default (pure text in/text out)
- Tracks conversation history in the session struct (the API is
  stateless; every request carries the full messages array)
- Is the simplest backend to use for HTTP-only workflows or when you
  do not want a CLI dependency

## Prerequisites

You need an Anthropic API key. Set `ANTHROPIC_API_KEY` in your
environment, or pass `:api_key` as a backend option.

## Installation

```elixir
def deps do
  [
    {:gen_agent, "~> 0.3.0"},
    {:gen_agent_anthropic, "~> 0.2.0"}
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
      system: "You are a concise, helpful assistant.",
      max_tokens: 512
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
  backend: GenAgent.Backends.Anthropic
)

{:ok, response} = GenAgent.ask("my-assistant", "Explain OTP gen_statem in one sentence.")
IO.puts(response.text)
```

## Session continuation

The Anthropic API is **stateless** -- every request carries the full
messages array. This backend tracks the conversation history on the
session struct so multi-turn conversations work transparently:

```elixir
# Turn 1: fresh conversation
{:ok, r1} = GenAgent.ask("my-assistant", "Remember the number 42")
# Turn 2: backend sends the full history including turn 1
{:ok, r2} = GenAgent.ask("my-assistant", "What number did I ask you to remember?")
# r2.text == "42"
```

Conversation history lives in `session.messages` as an in-order list
of `%{role: ..., content: ...}` maps with atom keys. The user message is
appended on dispatch. The assistant message is appended when the terminal
`:result` event carries non-blank text. If the response is a refusal
(`stop_reason: "refusal"`) or its text is empty or only whitespace, the
unanswered user message is removed instead, so history keeps alternating.

## Backend options

- `:api_key` -- Anthropic API key. Defaults to
  `System.get_env("ANTHROPIC_API_KEY")`. Starting without a non-empty key
  returns `{:error, :missing_api_key}` (through `GenAgent.start_agent/2`,
  `{:error, {:backend_start_failed, :missing_api_key}}`), unless a one-arity
  `:http_fn` is supplied.
- `:model` -- model name. Defaults to `"claude-sonnet-4-5"`.
- `:max_tokens` -- max tokens per turn. Defaults to `1024`.
- `:system` -- system prompt (string).
- `:receive_timeout` -- HTTP receive timeout in milliseconds. Defaults
  to `60_000`. The 60-second default can be short for long reasoning turns.
- `:connect_timeout` -- HTTP connect timeout in milliseconds. Defaults
  to `nil` (Req's default).
- `:http_fn` -- a 1-arity function
  `(request_map) -> {:ok, response_map} | {:error, term}`
  that replaces the default `Req`-backed HTTP call. Intended for
  tests that want to stub out the API.

See `GenAgent.Backends.Anthropic` for the full module docs.

## Why no tool use?

This backend is deliberately minimal: text in, text out. Anthropic's
Messages API supports tool use, but adding it means a richer event
surface, tool schema definitions, and roundtripping tool results --
all of which is better served by the Claude CLI backend
(`gen_agent_claude`), which gets that flow from Claude Code itself.

If you want tool-using agents with Anthropic as the provider, reach
for `gen_agent_claude`. If you want a thin HTTP client for
single-turn or multi-turn text exchanges, this is the right
backend.

## Testing your agent

Return `:http_fn` in the backend options from your agent's `init_agent/1`
(for example, `{:ok, Keyword.take(opts, [:http_fn]), initial_state}`).
Then application tests can use a canned response with no API key or HTTP calls:

```elixir
body = %{
  "id" => "msg_test", "model" => "test-model", "stop_reason" => "end_turn",
  "content" => [%{"type" => "text", "text" => "hi"}],
  "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
}

{:ok, _pid} = GenAgent.start_agent(MyApp.Assistant,
  name: "test-assistant",
  backend: GenAgent.Backends.Anthropic,
  http_fn: fn %{body: _request_body} -> {:ok, body} end
)

{:ok, %GenAgent.Response{text: "hi"}} = GenAgent.ask("test-assistant", "hello")
:ok = GenAgent.stop("test-assistant")
```

The stub receives a request map and returns the decoded response body.
See the [keyless primitive examples](https://github.com/genagent/gen_agent/tree/main/examples/primitives) for callback assertions.

## Testing

```bash
mix test
```

Unit tests stub the HTTP layer via the `:http_fn` backend option, so
no tokens are burned during `mix test`.

Live tests (tagged `:live`) hit the real API and require
`ANTHROPIC_API_KEY` in the environment:

```bash
mix test --only live
```

## License

MIT. See [LICENSE](LICENSE).
