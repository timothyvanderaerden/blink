#
# Blink live demo - end-to-end against a real local SLM (or a built-in mock).
#
# Requires a running backend with a small model, e.g. Ollama:
#
#   brew install ollama
#   ollama pull qwen2.5:1.5b
#
# Modes:
#
#   mix run demo.exs                          # built-in demo prompts
#   mix run demo.exs -- --prompt "your text"  # your own prompt (evaluate + route)
#   mix run demo.exs -- --interactive         # type prompts, one per line, Ctrl-D to finish
#   mix run demo.exs -- --mock                # no backend: heuristic mock model
#
# Options (any combination):
#
#   mix run demo.exs -- --endpoint http://localhost:8000/v1 --model qwen2.5:3b
#   mix run demo.exs -- --mock --interactive
#
# Hosted OpenAI-compatible APIs (e.g. DeepSeek) work too - pass a header:
#
#   export DEEPSEEK_API_KEY=sk-...
#   mix run demo.exs -- --endpoint https://api.deepseek.com/v1 --model deepseek-flash
#   # or explicitly:  --header "Authorization: Bearer sk-..."
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

defmodule Demo.MockClient do
  @moduledoc """
  A toy stand-in for a local SLM so the full Blink pipeline (prompt build,
  JSON parse, changeset validation, confidence math, routing) can be
  exercised WITHOUT any backend.

  Decisions come from keyword heuristics, NOT from a model. Logprobs are
  synthesized to match the heuristic confidence, so the real
  Blink.Confidence math runs end to end.
  """

  @complex ["prove", "proof", "design", "architecture", "distributed", "consensus",
            "algorithm", "trade-off", "compare", "why does", "explain why"]

  @code ["refactor", "function", "implement", "bug", "fix the", "elixir", "python",
         "sql", "code"]

  @unsafe ["delete all", "drop table", "rm -rf", "ignore previous", "bypass",
           "disable safety", "without permission"]

  def complete(_config, messages, _opts \\ []) do
    prompt = List.last(messages)["content"]
    p = String.downcase(prompt)

    intent =
      cond do
        any_keyword?(p, @complex) -> "complex_reasoning"
        any_keyword?(p, @code) -> "code_refactor"
        String.length(p) < 12 -> "unclear"
        true -> "simple_query"
      end

    safe? = not any_keyword?(p, @unsafe)
    requires_system_2 = intent == "complex_reasoning" or intent == "unclear" or not safe?

    # Heuristic "model confidence" in its own classification.
    confidence =
      cond do
        intent == "unclear" -> 0.40
        not safe? -> 0.85
        true -> 0.92
      end

    entities = Regex.scan(~r/"([^"]+)"/, prompt) |> Enum.map(fn {_, e} -> e end)

    params = %{
      "intent" => intent,
      "requires_system_2" => requires_system_2,
      "extracted_entities" => entities,
      "reasoning_summary" => "mock: keyword heuristic (#{intent})",
      "safe" => safe?,
      "reason" => if(safe?, do: "mock: no unsafe keywords", else: "mock: unsafe keywords")
    }

    {:ok, params, synthesize_logprobs(confidence)}
  end

  # 40 token entries whose geometric-mean probability is ~`confidence`.
  defp synthesize_logprobs(confidence) do
    base = :math.log(confidence)

    for i <- 1..40 do
      logprob = base + 0.01 * :math.sin(i)

      %{
        "token" => "tok#{i}",
        "logprob" => logprob,
        "bytes" => ~c("tok#{i}") |> Enum.to_list(),
        "top_logprobs" =>
          for j <- 1..5 do
            %{"token" => "alt#{j}", "logprob" => logprob - 0.3 * j}
          end
      }
    end
  end

  defp any_keyword?(p, keywords) do
    Enum.any?(keywords, &String.contains?(p, &1))
  end
end

defmodule Demo do
  @moduledoc false

  @default_prompts [
    "What is the capital of France?",
    "Refactor this Elixir function to use pattern matching: def double(x), do: x + x",
    "Prove that the square root of 2 is irrational, then design a distributed " <>
      "consensus protocol that uses the proof"
  ]

  def main(argv) do
    endpoint = opt(argv, "--endpoint", "http://localhost:11434/v1")
    model = opt(argv, "--model", "qwen2.5:1.5b")
    prompt = opt(argv, "--prompt", nil)
    interactive? = "--interactive" in argv
    mock? = "--mock" in argv
    headers = collect_headers(argv)

    opts = [
      endpoint: endpoint,
      model: model,
      timeout: 120_000,
      extra_headers: headers,
      client: if(mock?, do: Demo.MockClient, else: Blink.Client)
    ]

    IO.puts("Blink live demo")
    IO.puts("endpoint: #{endpoint}")
    IO.puts("model:    #{model}")

    if mock? do
      IO.puts("client:   Demo.MockClient (MOCK - no network, keyword heuristics)")
    end

    cond do
      is_binary(prompt) ->
        IO.puts("\nYour prompt: #{prompt}\n")
        run_prompt(prompt, opts)
        route_prompt(prompt, opts)

      interactive? ->
        interactive_loop(opts)

      true ->
        IO.puts("\n== Blink.evaluate/3 (single schema) ==")

        for p <- @default_prompts do
          run_prompt(p, opts)
        end

        IO.puts("\n== Blink.route/3 (two schemas, evaluated in parallel) ==")
        route_prompt("Write a SQL query that deletes all rows from the users table", opts)
    end

    IO.puts("\nDone.")
  end

  defp run_prompt(prompt, opts) do
    IO.puts("prompt: #{prompt}")

    case Blink.evaluate(prompt, Demo.TriageSchema, opts) do
      {:ok, result} ->
        IO.puts("  status:     #{result.status}")
        IO.puts("  confidence: #{inspect(result.confidence)}")
        IO.puts("  low_conf?:  #{result.low_confidence?}")
        IO.puts("  intent:     #{result.intent}")
        IO.puts("  entities:   #{inspect(result.data && result.data.extracted_entities)}")
        IO.puts("  reason:     #{inspect(result.reason)}")
        IO.puts("  latency:    #{result.latency_ms} ms")

      {:error, {:client_error, {:transport_error, _}}} ->
        IO.puts("  ERROR: could not reach #{opts[:endpoint]}")
        IO.puts("  Is the backend running? e.g. `ollama serve` and `ollama pull #{opts[:model]}`")

      {:error, reason} ->
        IO.puts("  ERROR: #{inspect(reason)}")
    end

    IO.puts("")
  end

  defp route_prompt(prompt, opts) do
    IO.puts("prompt: #{prompt}")

    case Blink.route(prompt, [Demo.TriageSchema, Demo.SafetySchema], opts) do
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

    IO.puts("")
  end

  defp interactive_loop(opts) do
    IO.puts("\nType a prompt per line (blank line skips). Ctrl-D to finish.\n")
    loop(opts)
  end

  defp loop(opts) do
    case IO.gets("blink> ") do
      nil ->
        :ok

      :eof ->
        :ok

      {:error, _} ->
        :ok

      line ->
        line = String.trim(line)

        if line == "" do
          loop(opts)
        else
          run_prompt(line, opts)
          loop(opts)
        end
    end
  end

  defp opt(argv, flag, default) do
    case Enum.find_index(argv, &(&1 == flag)) do
      nil -> default
      i -> Enum.at(argv, i + 1)
    end
  end

  # Collects repeatable --header "Name: Value" flags. If none sets
  # Authorization and DEEPSEEK_API_KEY is in the environment, it is added
  # automatically (convenience for hosted OpenAI-compatible APIs).
  defp collect_headers(argv) do
    headers =
      for i <- 0..max(length(argv) - 1, 0), Enum.at(argv, i) == "--header" do
        [name, value] = String.split(Enum.at(argv, i + 1), ":", parts: 2)
        {String.trim(name), String.trim(value)}
      end

    ensure_auth(headers)
  end

  defp ensure_auth(headers) do
    if Enum.any?(headers, fn {name, _} -> name == "Authorization" end) do
      headers
    else
      case System.get_env("DEEPSEEK_API_KEY") do
        nil -> headers
        key -> [{"Authorization", "Bearer #{key}"} | headers]
      end
    end
  end
end

Demo.main(System.argv())
