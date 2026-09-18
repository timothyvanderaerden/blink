#
# Blink live demo - end-to-end against a real local SLM.
#
# Requires a running backend with a small model, e.g. Ollama:
#
#   brew install ollama
#   ollama pull qwen2.5:1.5b
#
# Run:
#
#   mix run demo.exs
#
# Options (any combination):
#
#   mix run demo.exs -- --endpoint http://localhost:8000/v1 --model qwen2.5:3b
#
# The first prompt may take a while: the backend loads the model on demand.

defmodule Demo.TriageSchema do
  @moduledoc false

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

defmodule Demo.SafetySchema do
  @moduledoc false

  use Blink.Schema

  decision_schema do
    field :safe, :boolean, required: true
    field :reason, :string
  end
end

defmodule Demo do
  @moduledoc false

  def main(argv) do
    endpoint = opt(argv, "--endpoint", "http://localhost:11434/v1")
    model = opt(argv, "--model", "qwen2.5:1.5b")

    IO.puts("Blink live demo")
    IO.puts("endpoint: #{endpoint}")
    IO.puts("model:    #{model}\n")

    prompts = [
      "What is the capital of France?",
      "Refactor this Elixir function to use pattern matching: def double(x), do: x + x",
      "Prove that the square root of 2 is irrational, then design a distributed " <>
        "consensus protocol that uses the proof"
    ]

    IO.puts("== Blink.evaluate/3 (single schema) ==")

    for prompt <- prompts do
      IO.puts("\nprompt: #{prompt}")

      case Blink.evaluate(prompt, Demo.TriageSchema,
             endpoint: endpoint, model: model, timeout: 120_000
           ) do
        {:ok, result} ->
          IO.puts("  status:     #{result.status}")
          IO.puts("  confidence: #{inspect(result.confidence)}")
          IO.puts("  low_conf?:  #{result.low_confidence?}")
          IO.puts("  intent:     #{result.intent}")
          IO.puts("  entities:   #{inspect(result.data.extracted_entities)}")
          IO.puts("  reason:     #{result.reason}")
          IO.puts("  latency:    #{result.latency_ms} ms")

        {:error, {:client_error, {:transport_error, _}}} ->
          IO.puts("  ERROR: could not reach #{endpoint}")
          IO.puts("  Is the backend running? e.g. `ollama serve` and `ollama pull #{model}`")
          System.halt(1)

        {:error, reason} ->
          IO.puts("  ERROR: #{inspect(reason)}")
      end
    end

    IO.puts("\n== Blink.route/3 (two schemas, evaluated in parallel) ==")

    prompt = "Write a SQL query that deletes all rows from the users table"

    IO.puts("\nprompt: #{prompt}")

    case Blink.route(
           prompt,
           [Demo.TriageSchema, Demo.SafetySchema],
           endpoint: endpoint, model: model, timeout: 120_000
         ) do
      {:ok, result} ->
        IO.puts("  winner:   #{result.winner}")
        IO.puts("  status:   #{result.status}")

        for {name, check} <- result.checks do
          case check do
            %Blink.Result{} = r ->
              IO.puts("  check #{name}: #{r.status} (confidence #{inspect(r.confidence)})")

            {:error, reason} ->
              IO.puts("  check #{name}: ERROR #{inspect(reason)}")
          end
        end

      {:error, reason} ->
        IO.puts("  ERROR: #{inspect(reason)}")
    end

    IO.puts("\nDone.")
  end

  defp opt(argv, flag, default) do
    case Enum.find_index(argv, &(&1 == flag)) do
      nil -> default
      i -> Enum.at(argv, i + 1)
    end
  end
end

Demo.main(System.argv())
