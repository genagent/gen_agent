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
      system_prompt: "You are a concise, helpful assistant.",
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
# Turn 2: backend sends previous_response_id from r1's terminal event
# (r1.terminal.data.response_id), carried forward automatically
# OpenAI replays turn 1's context on the server side
{:ok, r2} = GenAgent.ask("my-assistant", "What number did I ask you to remember?")
# r2.text =~ "42"
```

The `previous_response_id` lives on the session struct and is
updated via `update_session/2` when each terminal `:result` event
lands. `store: true` is sent on every request (the default) so
responses remain referenceable.

If the API rejects an established chain because the previous response is
unavailable or the context window is exceeded, the failed turn returns
`{:error, {:conversation_lost, body}}`. The backend clears the saved
`previous_response_id`, so the next prompt starts a fresh conversation
without losing the agent process or its application state. It does not
retry the failed prompt automatically. Set `truncation: "auto"` to let the
API drop older items before the context window fills; the default is the
API's `"disabled"` behavior. Other HTTP errors retain the chain. The backend
always sends `store: true` and does not support local transcript replay for
organizations where response storage is disabled.

## Instructions do not persist across turns

OpenAI's docs are explicit: instructions from a prior turn do
**not** carry over when you chain via `previous_response_id`. This
backend therefore resends the `:system_prompt` option as API `instructions`
on every request when the option is set. The per-turn token cost is tiny, but the
invariant matters -- a future optimization that "only sends
instructions once" would silently break system-prompt behavior on
every turn after the first.

## Backend options

- `:api_key` -- OpenAI API key. Defaults to
  `System.get_env("OPENAI_API_KEY")`. Starting without a non-empty key
  returns `{:error, :missing_api_key}` (through `GenAgent.start_agent/2`,
  `{:error, {:backend_start_failed, :missing_api_key}}`), unless a one-arity
  `:http_fn` is supplied.
- `:model` -- model name. Defaults to `"gpt-5"`.
- `:system_prompt` -- system prompt (string). Resent every turn as API
  `instructions`; `:instructions` and `:system` remain deprecated aliases.
- `:reasoning_effort` -- an atom or string passed through as
  `reasoning.effort` on reasoning models (for example `:low`,
  `:medium`, `:high`), or `nil` for the model default. The backend
  does not validate it; accepted values depend on the model.

- `:max_output_tokens` -- cap on output tokens per turn. Defaults
  to `nil` (model default). `:max_tokens` remains a deprecated alias.
- `:truncation` -- `"auto"` or `"disabled"`. Omitted by default; the API
  then uses `"disabled"`. `"auto"` drops older conversation items to fit
  the context window.
- `:receive_timeout` -- HTTP receive timeout in milliseconds. Defaults
  to `60_000`. The 60-second default can be short for long reasoning turns.
- `:connect_timeout` -- HTTP connect timeout in milliseconds. Defaults
  to `nil` (Req's default).
- `:http_fn` -- a 1-arity function
  `(request_map) -> {:ok, response_map} | {:error, term}`
  that replaces the default `Req`-backed HTTP call. Intended for
  tests that want to stub out the API.

See `GenAgent.Backends.OpenAI` for the full module docs.
Unknown keys fail session startup with `{:unknown_option, key}`; conflicting
values supplied through aliases fail with `{:conflicting_options, keys}`.

When the API includes `usage.input_tokens_details.cached_tokens`, the
normalized `Response.usage.cached_input_tokens` reports that subset of
`input_tokens`. It is not added to the total a second time.

## Why no tool use?

This backend is deliberately minimal: text in, text out. The
Responses API supports built-in tools (web search, file search,
code interpreter) and custom function tools, but adding them
means a richer event surface and roundtripping tool results --
better served by a future version or by using `gen_agent_claude`
if you want tool-using agents today.

## Testing your agent

Return `:http_fn` in the backend options from your agent's `init_agent/1`
(for example, `{:ok, Keyword.take(opts, [:http_fn]), initial_state}`).
Then application tests can use a canned response with no API key or HTTP calls:

```elixir
body = %{
  "id" => "resp_test", "model" => "test-model", "status" => "completed",
  "output" => [%{"type" => "message", "content" => [%{"type" => "output_text", "text" => "hi"}]}],
  "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}
}

{:ok, _pid} = GenAgent.start_agent(MyApp.Assistant,
  name: "test-assistant",
  backend: GenAgent.Backends.OpenAI,
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

Unit tests stub the HTTP layer via the `:http_fn` backend option,
so no tokens are burned during `mix test`.

Live tests (tagged `:live`) hit the real API and require
`OPENAI_API_KEY` in the environment:

```bash
mix test --only live
```

## License

MIT. See [LICENSE](LICENSE).
