defmodule Blink.Parallel do
  @moduledoc """
  Concurrent multi-check evaluator built on `Task.async_stream/3`.

  Runs a list of lightweight checks (safety, intent, entity presence, ...)
  concurrently, so total gate latency is bounded by the slowest check
  rather than the sum of all checks. The calling process is never blocked
  while checks are in flight: `stream/2` returns immediately and the
  results are materialized lazily when the stream is enumerated.

  Each check is a `{name, fun}` tuple; `fun` is a zero-arity function.
  Results are returned in input order as `{name, {:ok, value} | {:error, reason}}`.
  """

  @default_timeout 2_000

  @type check_name :: atom()
  @type check :: {check_name(), (-> term())}
  @type outcome :: {check_name() | nil, {:ok, term()} | {:error, term()}}

  @doc """
  Runs all checks concurrently and waits for every outcome.

  A check that exceeds `:timeout` is killed and reported as
  `{nil, {:error, {:timeout, :task_killed}}}`; the remaining checks are
  unaffected.

  Options:

    * `:timeout` - per-check timeout in ms (default #{@default_timeout})
    * `:max_concurrency` - concurrency cap (default: number of checks)
  """
  def run(checks, opts \\ []) when is_list(checks) do
    stream(checks, opts)
    |> collect()
  end

  @doc """
  Starts all checks concurrently and returns a lazy stream of outcomes.

  The caller stays free to do other work until it enumerates the stream.
  """
  def stream(checks, opts \\ []) when is_list(checks) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    max_concurrency = Keyword.get(opts, :max_concurrency, max(1, length(checks)))

    Task.async_stream(
      checks,
      fn {name, fun} -> {name, protect(fun)} end,
      timeout: timeout,
      on_timeout: :kill_task,
      max_concurrency: max_concurrency
    )
  end

  @doc "Materializes a stream returned by `stream/2` into a list of outcomes."
  def collect(stream) do
    Enum.map(stream, &normalize/1)
  end

  defp protect(fun) do
    try do
      {:ok, fun.()}
    rescue
      e -> {:error, {:crash, Exception.message(e)}}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp normalize({:ok, {name, result}}), do: {name, result}

  defp normalize({:exit, reason}) do
    error = if reason == :timeout, do: {:timeout, :task_killed}, else: {:crash, reason}
    {nil, {:error, error}}
  end
end
