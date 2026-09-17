defmodule Blink.Gate do
  @moduledoc """
  The core System 1 routing engine.

  `run/3` orchestrates the full gate pipeline for a single decision schema:

  1. builds a strict JSON-only system prompt from the schema's fields,
  2. calls the local SLM through `Blink.Client` (with `logprobs` enabled),
  3. decodes the JSON object out of the assistant message,
  4. validates it against the schema with an Ecto changeset,
  5. calibrates confidence from the token logprobs
     (`Blink.Confidence.from_logprobs/2`),
  6. decides `:handled_locally` vs `:escalate_to_system_2`.

  Returns `{:ok, %Blink.Result{}}` whenever the endpoint answered (check
  `result.status`), and `{:error, {:client_error, reason}}` on transport or
  payload errors.
  """

  alias Blink.{Client, Confidence, Result, Schema}

  @default_min_confidence 0.75

  @type config :: map()

  @doc """
  Runs the full gate pipeline for `prompt` against `schema`.

  `config` is a map; see `Blink.Client.complete/3` for transport options
  (`:endpoint`, `:model`, `:timeout`, ...) plus:

    * `:min_confidence` - confidence threshold (default #{@default_min_confidence})
    * `:client` - client module implementing `complete/3`
      (default `Blink.Client`)
  """
  def run(prompt, schema, config) when is_binary(prompt) and is_atom(schema) and is_map(config) do
    config = Map.put_new(config, :min_confidence, @default_min_confidence)
    client = Map.get(config, :client, Client)
    messages = build_messages(prompt, schema)

    t0 = System.monotonic_time(:millisecond)

    case client.complete(config, messages) do
      {:ok, params, logprob_entries} ->
        latency = System.monotonic_time(:millisecond) - t0
        finish(schema, config, params, logprob_entries, latency)

      {:error, reason} ->
        {:error, {:client_error, reason}}
    end
  end

  @doc "Builds the `[system, user]` message list for a prompt and schema."
  def build_messages(prompt, schema) do
    [
      %{"role" => "system", "content" => system_prompt(schema)},
      %{"role" => "user", "content" => prompt}
    ]
  end

  @doc "The strict JSON-only system prompt derived from a schema's fields."
  def system_prompt(schema) do
    fields = Schema.fields(schema)

    """
    You are a precise, terse classifier running on a small local model.
    Respond with ONLY one JSON object - no markdown, no code fences, no commentary.
    Use exactly these keys: #{Enum.join(fields, ", ")}.
    """
  end

  defp finish(schema, config, params, logprob_entries, latency) do
    min_confidence = config[:min_confidence]
    report = Confidence.from_logprobs(logprob_entries, threshold: min_confidence)

    case Schema.cast(schema, params) do
      {:ok, data} ->
        status = if report.low_confidence?, do: :escalate_to_system_2, else: :handled_locally

        {:ok,
         %Result{
           status: status,
           data: data,
           confidence: report.confidence,
           low_confidence?: report.low_confidence?,
           intent: field_value(data, :intent),
           requires_system_2: requires_system_2?(data, status),
           reason: if(status == :handled_locally, do: nil, else: :low_confidence),
           schema: schema,
           model: config[:model],
           latency_ms: latency
         }}

      {:error, changeset} ->
        {:ok,
         %Result{
           status: :escalate_to_system_2,
           data: nil,
           confidence: report.confidence,
           low_confidence?: report.low_confidence?,
           intent: nil,
           requires_system_2: true,
           reason: {:schema_invalid, changeset.errors},
           schema: schema,
           model: config[:model],
           latency_ms: latency
         }}
    end
  end

  defp requires_system_2?(data, status) do
    case field_value(data, :requires_system_2) do
      value when is_boolean(value) -> value
      _ -> status == :escalate_to_system_2
    end
  end

  defp field_value(struct, field) when is_struct(struct) do
    if Map.has_key?(struct, field), do: Map.get(struct, field), else: nil
  end
end
