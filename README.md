# Blink

**Blink** is an open-source, ultra-fast, local-first *System 1 decision gate* and
type-safe router written in Elixir. It evaluates a prompt in well under 150 ms
using a lightweight local SLM (Qwen 2.5 1.5B/3B, Llama 3.2, ...) served by
Ollama, vLLM or oMLX, guarantees schema compliance via Ecto changesets,
extracts a calibrated confidence score from raw token logprobs, and decides
whether the request can be handled locally or must be escalated to a heavier
System 2 reasoning pipeline.

```
prompt ──▶ local SLM (Ollama / vLLM / oMLX)
              │  chat completion, logprobs: true, top_logprobs: 5
              ▼
        JSON parse ──▶ Ecto changeset validation (schema guaranteed)
              │
              ▼
        logprob confidence (geometric mean over decision tokens)
              │
              ▼
   :handled_locally  or  :escalate_to_system_2     (gate overhead < 1 ms)
```

## Why

- **Local-first & private** - prompts never leave your machine; works fully
  offline behind any OpenAI-compatible `/v1/chat/completions` endpoint.
- **Fast** - the gate pipeline (prompt build, JSON parse, changeset
  validation, confidence math) adds **~0.3 ms p95** on top of raw inference
  time (see [bench/overhead.exs](bench/overhead.exs)).
- **Type-safe** - decisions are Ecto schemas; malformed model output is
  rejected by changeset validation, never smuggled into your app.
- **Calibrated** - confidence is the geometric mean of the model's own token
  probabilities over the decision tokens, not a self-reported score.

## Requirements

- Elixir 1.19+ / Erlang/OTP 28
- A local inference backend exposing `/v1/chat/completions` with logprob
  support:
  - [Ollama](https://ollama.com) - `http://localhost:11434/v1`
  - [vLLM](https://docs.vllm.ai) - `http://localhost:8000/v1`
  - [oMLX](https://github.com/ml-explore/mlx-swift) - `http://localhost:8080/v1`

## Installation

```sh
git clone <repo-url> blink
cd blink
mix deps.get
```

Or as a dependency:

```elixir
def deps do
  [{:blink, "~> 0.1.0"}]
end
```

## Quick start

```elixir
# Single schema evaluation
{:ok, result} =
  Blink.evaluate(
    "Refactor this function to use pattern matching",
    MyApp.Routers.TriageSchema,
    endpoint: "http://localhost:11434/v1",
    model: "qwen2.5:1.5b",
    min_confidence: 0.70
  )

if result.requires_system_2 do
  escalate_to_system_2(result)
else
  handle_locally(result.data)
end
```

`result` is a `%Blink.Result{}`:

| field               | meaning                                             |
| ------------------- | --------------------------------------------------- |
| `status`            | `:handled_locally` or `:escalate_to_system_2`       |
| `data`              | the validated schema struct                         |
| `confidence`        | geometric-mean logprob confidence (0..1) or `nil`   |
| `low_confidence?`   | true when confidence is below the threshold         |
| `intent`            | the `intent` field, if the schema has one           |
| `requires_system_2` | the `requires_system_2` field, if present           |
| `reason`            | human-readable explanation of the decision          |
| `schema`, `model`   | which schema / model produced the decision          |
| `latency_ms`        | wall time of the whole gate run                     |
| `winner`, `checks`  | populated by `Blink.route/3` (see below)            |

## Decision schemas

Define a decision schema with the `decision_schema` macro (Ecto embedded
schema + changeset validation under the hood):

```elixir
defmodule MyApp.Routers.TriageSchema do
  use Blink.Schema

  decision_schema do
    field :intent, :string,
          required: true,
          in: ["simple_query", "code_refactor", "complex_reasoning", "unclear"]

    field :requires_system_2, :boolean, required: true
    field :extracted_entities, {:array, :string}, default: []
    field :reasoning_summary, :string
  end
end
```

Supported field options: `required: true`, `in: [...]` (inclusion),
`default: value`. Any Ecto type works (`:string`, `:integer`, `:float`,
`:boolean`, `{:array, :string}`, ...).

Plain Ecto embedded schemas also work - Blink falls back to the schema's
`__schema__(:type)` map for field types.

## Routing across multiple schemas

`Blink.route/3` evaluates several schemas **concurrently** (via
`Blink.Parallel`, `Task.async_stream` under the hood) and picks a winner:

```elixir
{:ok, result} =
  Blink.route(
    prompt,
    [MyApp.Routers.TriageSchema, MyApp.Routers.SafetySchema],
    endpoint: "http://localhost:11434/v1",
    min_confidence: 0.70,
    prefer: [:safety]
  )

result.winner #=> :safety
result.checks #=> [{:triage, %Blink.Result{}}, {:safety, %Blink.Result{}}]
```

- Check names default to the schema's base module name
  (`TriageSchema` → `:triage`); pass `{name, module}` tuples to override.
- Winner = the best `:handled_locally` check in `:prefer` order, broken by
  confidence; if nothing is handled locally, the highest-confidence
  escalation candidate wins.
- `{:error, {:all_checks_failed, checks}}` is returned when every check
  errored (transport failure, timeout, invalid JSON, ...).

## Confidence

`Blink.Confidence.from_logprobs/2` computes the **geometric mean** of the
model's token probabilities over the decision tokens:

```
confidence = exp( (1/N) * Σ logprob_i )
```

- Structural tokens (`{ } [ ] " , :` and whitespace) are filtered out so the
  score reflects the model's actual decisions, not JSON syntax.
- Entries without a numeric `logprob` are excluded (counted in
  `:excluded`).
- Below the threshold (default `0.75`; the facade default is `0.70`) the
  result is flagged `low_confidence?` and escalated.

## Configuration

The default endpoint can be overridden project-wide:

```elixir
# config/config.exs
config :blink, default_endpoint: "http://localhost:8000/v1"
```

Per-call options accepted by `Blink.evaluate/3` and `Blink.route/3`:

| option            | default                          | meaning                          |
| ----------------- | -------------------------------- | -------------------------------- |
| `:endpoint`       | `http://localhost:11434/v1`      | base URL of the backend          |
| `:model`          | `qwen2.5:1.5b`                   | model name                       |
| `:min_confidence` | `0.70`                           | escalation threshold             |
| `:timeout`        | `30_000`                         | receive + task timeout (ms)      |
| `:temperature`    | `0`                              | sampling temperature             |
| `:top_logprobs`   | `5`                              | top logprobs per token           |
| `:extra_body`     | `%{}`                            | extra payload fields             |
| `:client`         | `Blink.Client`                   | swappable client module          |
| `:prefer`         | `[]`                             | winner preference (`route/3`)    |

## Testing, coverage, benchmarks

```sh
mix test            # 76 tests, 0 failures
mix test --cover    # 100.00% coverage on every module
mix run bench/overhead.exs
```

Benchmark (120-token payload × 5 top_logprobs, 1000 iterations, no inference):

```
pipeline total (no inference)          mean 0.288    p50 0.283    p95 0.336    ms
Gate.run end-to-end (fake client)      mean 0.083    p50 0.062    p95 0.128    ms

Parallel multi-check demo (4 checks x 50ms)
sequential:        210 ms
Parallel.run:       55 ms
stream/2 returned in 0 ms; main process did 100 ms of work while checks ran
```

## Project layout

```
lib/
  blink.ex            facade: evaluate/3, route/3
  blink/
    application.ex    OTP application
    client.ex         Req-based OpenAI-compatible client (logprobs)
    confidence.ex     geometric-mean logprob confidence
    gate.ex           orchestration: prompt build → validate → decide
    parallel.ex       Task.async_stream check runner (run/stream/collect)
    result.ex         %Blink.Result{}
    schema.ex         use Blink.Schema + decision_schema/1 macro
bench/
  overhead.exs        gate-overhead + parallel benchmark
test/                 ExUnit suite (Bypass-backed, no real backend needed)
```

## License

MIT
