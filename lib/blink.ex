defmodule Blink do
  @moduledoc """
  Blink - an ultra-fast, local-first System 1 decision gate and type-safe
  router.

  Blink evaluates a prompt against one or more Ecto decision schemas using a
  lightweight local SLM (Qwen 2.5, Llama 3.2, ...) served by Ollama, vLLM or
  oMLX. It guarantees schema compliance via Ecto changesets, calibrates a
  confidence score from raw token logprobs (geometric mean over decision
  tokens), and decides whether the request can be handled locally or must be
  escalated to a heavier System 2 reasoning pipeline.

  ## Quick start

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

  ## Routing across multiple schemas

      {:ok, result} =
        Blink.route(
          prompt,
          [MyApp.Routers.TriageSchema, MyApp.Routers.SafetySchema],
          endpoint: "http://localhost:11434/v1",
          min_confidence: 0.70,
          prefer: [:safety]
        )

      result.winner #=> :triage
      result.checks #=> [{:triage, %Blink.Result{}}, {:safety, %Blink.Result{}}]

  The gate pipeline (prompt build, JSON parse, changeset validation,
  confidence math) adds only single-digit milliseconds of overhead on top of
  raw local inference time - see `bench/overhead.exs`.

  ## Configuration

  The default endpoint can be overridden project-wide:

      config :blink, default_endpoint: "http://localhost:8000/v1"
  """

  alias Blink.{Gate, Parallel, Result}

  @default_endpoint "http://localhost:11434/v1"
  @default_model "qwen2.5:1.5b"
  @default_min_confidence 0.70
  @default_timeout 30_000

  @type opts :: keyword()

  @doc """
  Evaluates `prompt` against a single decision `schema`.

  Returns `{:ok, %Blink.Result{}}` when the endpoint answered (check
  `result.status`), or `{:error, {:client_error, reason}}` on transport or
  payload errors.

  Options: `:endpoint`, `:model`, `:min_confidence`, `:timeout`,
  `:temperature`, `:top_logprobs`, `:extra_body`, `:extra_headers`, `:client`.
  """
  def evaluate(prompt, schema, opts \\ []) do
    Gate.run(prompt, schema, gate_config(opts))
  end

  @doc """
  Routes `prompt` across multiple decision schemas, evaluated concurrently
  by `Blink.Parallel`.

  `schemas` is a list of schema modules or `{name, module}` tuples.
  `rules` accepts the same options as `evaluate/3` plus:

    * `:prefer` - an ordered list of check names to prefer when several
      checks are equally qualified.

  The winner is the best `:handled_locally` check in preference order,
  broken by confidence; when nothing is handled locally, the highest
  confidence escalation candidate wins. The winning `%Blink.Result{}` is
  returned with `:winner` and `:checks` populated. Returns
  `{:error, {:all_checks_failed, checks}}` when every check errored.
  """
  def route(prompt, schemas, rules \\ []) do
    unless is_list(schemas) and schemas != [] do
      raise ArgumentError,
            "schemas must be a non-empty list of Ecto schema modules or {name, module} tuples"
    end

    config = gate_config(rules)
    prefer = Keyword.get(rules, :prefer, [])
    checks = to_checks(prompt, schemas, config)
    results = Parallel.run(checks, timeout: config[:timeout])
    pick(results, prefer)
  end

  defp gate_config(opts) do
    %{
      endpoint:
        Keyword.get(opts, :endpoint,
          Application.get_env(:blink, :default_endpoint, @default_endpoint)
        ),
      model: Keyword.get(opts, :model, @default_model),
      min_confidence: Keyword.get(opts, :min_confidence, @default_min_confidence),
      timeout: Keyword.get(opts, :timeout, @default_timeout),
      temperature: Keyword.get(opts, :temperature, 0),
      top_logprobs: Keyword.get(opts, :top_logprobs, 5),
      extra_body: Keyword.get(opts, :extra_body, %{}),
      extra_headers: Keyword.get(opts, :extra_headers, []),
      client: Keyword.get(opts, :client, Blink.Client)
    }
  end

  defp to_checks(prompt, schemas, config) do
    schemas
    |> Enum.with_index()
    |> Enum.map(fn {entry, idx} ->
      {name, schema} = normalize_entry(entry, idx)
      {name, fn -> Gate.run(prompt, schema, config) end}
    end)
  end

  defp normalize_entry({name, schema}, _idx) when is_atom(name) and not is_nil(name) and
         is_atom(schema) do
    {name, schema}
  end

  defp normalize_entry({name, schema}, _idx) when is_binary(name) and is_atom(schema) do
    {String.to_atom(name), schema}
  end

  defp normalize_entry(schema, idx) when is_atom(schema) do
    {default_check_name(schema, idx), schema}
  end

  defp default_check_name(schema, idx) do
    base =
      schema
      |> Module.split()
      |> List.last()
      |> String.replace(~r/Schema$/, "")
      |> Macro.underscore()

    if base == "" do
      :"check_#{idx}"
    else
      String.to_atom(base)
    end
  end

  defp pick(results, prefer) do
    # Parallel wraps every completed check in {:ok, value}; the check funs
    # return Gate.run's own tagged result, hence the double layer.
    ok =
      for {name, {:ok, {:ok, %Result{} = result}}} <- results, do: {name, result}

    winner =
      if ok == [] do
        nil
      else
        handled =
          for {name, %Result{status: :handled_locally} = result} <- ok, do: {name, result}

        candidates = if handled == [], do: ok, else: handled
        best(candidates, prefer)
      end

    checks =
      for {name, outcome} <- results do
        case outcome do
          {:ok, {:ok, %Result{} = result}} -> {name, result}
          {:ok, {:error, reason}} -> {name, {:error, reason}}
          {:error, reason} -> {name, {:error, reason}}
        end
      end

    case winner do
      nil ->
        {:error, {:all_checks_failed, checks}}

      {name, result} ->
        {:ok, %{result | winner: name, checks: checks}}
    end
  end

  defp best(candidates, prefer) do
    candidates
    |> Enum.sort_by(fn {name, result} ->
      {prefer_index(prefer, name), -(result.confidence || 0.0), name}
    end)
    |> hd()
  end

  defp prefer_index(prefer, name) do
    case Enum.find_index(prefer, &(&1 == name)) do
      nil -> length(prefer)
      idx -> idx
    end
  end
end
