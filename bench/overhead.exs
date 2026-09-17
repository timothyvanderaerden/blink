#
# Blink gate overhead benchmark.
#
# Measures the NON-inference cost of the gate pipeline on a realistic
# 120-token completion payload:
#
#   * full response-body JSON decode
#   * assistant-content JSON parse (Client.decode_content/1)
#   * changeset validation (Blink.Schema.cast/2)
#   * logprob confidence math (Blink.Confidence.from_logprobs/2)
#   * the whole pipeline, and Gate.run/3 end-to-end with a fake client
#
# and demonstrates the parallel multi-check path:
#
#   * 4 x 50ms checks: sequential wall time vs Blink.Parallel.run/2
#   * stream/2 returning immediately while the calling process keeps
#     working (non-blocking guarantee)
#
# Run with:
#
#     mix run bench/overhead.exs
#
# Exits 0 when the p95 pipeline overhead is below 10ms, 1 otherwise.

defmodule Bench.TriageSchema do
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

defmodule Bench.FakeClient do
  @moduledoc false

  # Returns a pre-decoded completion without any network I/O, so
  # Blink.Gate.run/3 measures orchestration + parse + validation +
  # confidence only.
  def complete(_config, _messages, _opts \\ []) do
    {:ok, Application.fetch_env!(:bench, :params), Application.fetch_env!(:bench, :entries)}
  end
end

defmodule Bench do
  @moduledoc false

  alias Blink.{Client, Confidence, Gate, Parallel, Schema}

  @iterations 1_000
  @warmup 100
  @p95_budget_ms 10.0

  def main do
    {raw, content, entries, params} = build_payload(120)
    schema = Bench.TriageSchema

    Application.put_env(:bench, :params, params)
    Application.put_env(:bench, :entries, entries)

    IO.puts("Blink gate overhead benchmark")
    IO.puts("==============================")
    IO.puts("payload: 120 content tokens x 5 top_logprobs (#{byte_size(raw)} bytes)")
    IO.puts("iterations: #{@iterations} (after #{@warmup} warmup)\n")

    for _ <- 1..@warmup, do: pipeline(raw, schema)

    body_decode = time_it(fn -> Jason.decode(raw) end)
    content_parse = time_it(fn -> Client.decode_content(content) end)
    schema_cast = time_it(fn -> Schema.cast(schema, params) end)
    confidence = time_it(fn -> Confidence.from_logprobs(entries, threshold: 0.75) end)
    pipeline_all = time_it(fn -> pipeline(raw, schema) end)
    gate_all =
      time_it(fn ->
        Gate.run("bench prompt", schema, %{client: Bench.FakeClient, min_confidence: 0.75})
      end)

    report("Jason.decode (full response body)", body_decode)
    report("Client.decode_content (assistant JSON)", content_parse)
    report("Schema.cast (changeset validation)", schema_cast)
    report("Confidence.from_logprobs (120 tokens)", confidence)
    pipeline_stats = report("pipeline total (no inference)", pipeline_all)
    report("Gate.run end-to-end (fake client)", gate_all)

    parallel_demo()

    p95_ms = pipeline_stats.p95 / 1000

    IO.puts("\nVerdict: pipeline p95 = #{:erlang.float_to_binary(p95_ms, decimals: 3)} ms " <>
            "(budget < #{@p95_budget_ms} ms)")

    if p95_ms < @p95_budget_ms do
      IO.puts("PASS")
      :ok
    else
      IO.puts("FAIL")
      System.halt(1)
    end
  end

  # The exact non-network work done by Client.complete + Gate.run,
  # starting from the raw response body.
  defp pipeline(raw, schema) do
    {:ok, body} = Jason.decode(raw)
    choice = hd(body["choices"])
    logprobs = choice["logprobs"]["content"]
    {:ok, p} = Client.decode_content(choice["message"]["content"])
    {:ok, _data} = Schema.cast(schema, p)
    Confidence.from_logprobs(logprobs, threshold: 0.75)
  end

  defp time_it(fun) do
    for _ <- 1..@iterations do
      t0 = System.monotonic_time(:microsecond)
      fun.()
      System.monotonic_time(:microsecond) - t0
    end
  end

  defp report(label, samples_us) do
    sorted = Enum.sort(samples_us)
    n = length(sorted)
    mean = Enum.sum(sorted) / n

    stats = %{
      mean: mean,
      p50: pct(sorted, 0.50),
      p95: pct(sorted, 0.95),
      p99: pct(sorted, 0.99),
      max: Enum.max(sorted)
    }

    fmt = fn us -> :erlang.float_to_binary(us / 1000, decimals: 3) end

    IO.puts(
      "#{String.pad_trailing(label, 38)} " <>
        "mean #{String.pad_trailing(fmt.(stats.mean), 8)} " <>
        "p50 #{String.pad_trailing(fmt.(stats.p50), 8)} " <>
        "p95 #{String.pad_trailing(fmt.(stats.p95), 8)} " <>
        "p99 #{String.pad_trailing(fmt.(stats.p99), 8)} " <>
        "max #{fmt.(stats.max)} ms"
    )

    stats
  end

  defp pct(sorted, fraction) do
    n = length(sorted)
    idx = max(0, min(n - 1, round(fraction * n) - 1))
    Enum.at(sorted, idx)
  end

  defp parallel_demo do
    IO.puts("\nParallel multi-check demo (4 checks x 50ms)")

    checks =
      for i <- 1..4 do
        fun = fn ->
          Process.sleep(50)
          i
        end

        {:"check_#{i}", fun}
      end

    t0 = System.monotonic_time(:millisecond)
    for {_name, fun} <- checks, do: fun.()
    seq_ms = System.monotonic_time(:millisecond) - t0

    t0 = System.monotonic_time(:millisecond)
    results = Parallel.run(checks, timeout: 2_000)
    par_ms = System.monotonic_time(:millisecond) - t0

    IO.puts("sequential:        #{seq_ms} ms (sum of 4 checks)")
    IO.puts("Parallel.run:      #{par_ms} ms (wall time, #{length(results)} results in input order)")

    # Non-blocking guarantee: stream/2 returns immediately, the calling
    # process does other work while checks run, then collects.
    t_start = System.monotonic_time(:millisecond)
    stream = Parallel.stream(checks, timeout: 2_000)
    start_ms = System.monotonic_time(:millisecond) - t_start

    Process.sleep(100)
    main_work_ms = 100

    t0 = System.monotonic_time(:millisecond)
    results = Parallel.collect(stream)
    collect_ms = System.monotonic_time(:millisecond) - t0
    total_ms = System.monotonic_time(:millisecond) - t_start

    IO.puts("stream/2 returned in #{start_ms} ms; main process then did #{main_work_ms} ms of work")
    IO.puts("collect after work: #{collect_ms} ms (#{length(results)} results); total wall: #{total_ms} ms " <>
            "(would be #{seq_ms + main_work_ms} ms if checks blocked the caller)")

    if par_ms >= seq_ms or total_ms > seq_ms do
      IO.puts("FAIL: parallel path is not faster than sequential")
      System.halt(1)
    end

    :ok
  end

  defp build_payload(token_count) do
    content =
      ~s({"intent": "simple_query", "requires_system_2": false, "extracted_entities": ["Paris", "Eiffel Tower"], "reasoning_summary": "clear factual question, no planning needed"})

    entries =
      for i <- 1..token_count do
        base = -0.02 - 0.001 * :math.log(i + 1)

        %{
          "token" => "tok#{i}",
          "logprob" => base,
          "bytes" => ~c("tok#{i}") |> Enum.to_list(),
          "top_logprobs" =>
            for j <- 1..5 do
              %{"token" => "alt#{j}", "logprob" => base - 0.3 * j}
            end
        }
      end

    body = %{
      "id" => "bench-0001",
      "object" => "chat.completion",
      "created" => 1_700_000_000,
      "model" => "qwen2.5:1.5b",
      "choices" => [
        %{
          "index" => 0,
          "message" => %{"role" => "assistant", "content" => content},
          "logprobs" => %{"content" => entries},
          "finish_reason" => "stop"
        }
      ],
      "usage" => %{
        "prompt_tokens" => 42,
        "completion_tokens" => token_count,
        "total_tokens" => 42 + token_count
      }
    }

    raw = Jason.encode_to_iodata!(body) |> IO.iodata_to_binary()
    params = Jason.decode!(content)
    {raw, content, entries, params}
  end
end

Bench.main()
