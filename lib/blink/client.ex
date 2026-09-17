defmodule Blink.Client do
  @moduledoc """
  Req-based adapter for OpenAI-compatible local inference endpoints.

  Works with any server exposing `/v1/chat/completions`:

    * Ollama - `http://localhost:11434/v1`
    * vLLM   - `http://localhost:8000/v1`
    * oMLX   - `http://localhost:8080/v1`

  Every completion request asks for raw token probabilities
  (`logprobs: true`, `top_logprobs: 5`) so that `Blink.Confidence` can
  calibrate the decision from the model's own token distribution rather
  than from a self-reported score.
  """

  @default_endpoint "http://localhost:11434/v1"
  @default_model "qwen2.5:1.5b"
  @default_timeout 30_000
  @default_top_logprobs 5

  @type config :: map()
  @type message :: %{required(:role) => String.t(), required(:content) => String.t()}
  @type token_entry :: map()
  @type completion ::
          {:ok, params :: map(), logprob_entries :: [token_entry()]}
          | {:error, reason :: term()}

  @doc """
  Sends a chat completion request to the local endpoint.

  `config` is a map that may contain:

    * `:endpoint` - base URL (default `"#{@default_endpoint}"`)
    * `:model` - model name (default `"#{@default_model}"`)
    * `:timeout` - receive timeout in ms (default #{@default_timeout})
    * `:temperature`, `:top_logprobs`, `:extra_body` - payload overrides

  Returns `{:ok, params, logprob_entries}` where `params` is the decoded
  JSON object from the assistant message and `logprob_entries` is the raw
  `logprobs.content` array.
  """
  def complete(config, messages, opts \\ []) when is_map(config) and is_list(messages) do
    endpoint = Map.get(config, :endpoint, @default_endpoint)
    model = Map.get(config, :model, @default_model)
    timeout = Keyword.get(opts, :timeout, Map.get(config, :timeout, @default_timeout))
    temperature = Keyword.get(opts, :temperature, Map.get(config, :temperature, 0))
    top_logprobs =
      Keyword.get(opts, :top_logprobs, Map.get(config, :top_logprobs, @default_top_logprobs))

    extra_body = Keyword.get(opts, :extra_body, Map.get(config, :extra_body, %{}))

    payload =
      %{
        "model" => model,
        "messages" => messages,
        "temperature" => temperature,
        "logprobs" => true,
        "top_logprobs" => top_logprobs,
        "response_format" => %{"type" => "json_object"}
      }
      |> Map.merge(extra_body)

    url = "#{String.trim_trailing(endpoint, "/")}/chat/completions"

    case Req.post(url,
           json: payload,
           receive_timeout: timeout,
           connect_options: [timeout: 5_000]
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        decode(body)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, {:transport_error, reason}}

      {:error, other} ->
        {:error, {:request_error, other}}
    end
  end

  @doc """
  Decodes an assistant message content string into a JSON object map.

  Markdown code fences are stripped before decoding, so models that wrap
  their JSON in ```json blocks are handled transparently.
  """
  def decode_content(nil), do: {:error, :empty_content}

  def decode_content(content) when is_binary(content) do
    case Jason.decode(strip_code_fences(content)) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, other} -> {:error, {:unexpected_json, other}}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  def decode_content(_other), do: {:error, :empty_content}

  defp decode(body) when is_map(body), do: extract(body)

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) -> extract(map)
      _ -> {:error, :invalid_json}
    end
  end

  defp extract(body) do
    case List.first(body["choices"] || []) do
      nil ->
        {:error, :no_choices}

      choice ->
        message = choice["message"] || %{}
        logprobs = (choice["logprobs"] || %{})["content"] || []

        case decode_content(message["content"]) do
          {:ok, params} -> {:ok, params, logprobs}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp strip_code_fences(content) do
    trimmed = String.trim(content)

    case Regex.run(~r/^```[a-zA-Z0-9_-]*\s*(.*?)\s*```$/s, trimmed) do
      [_, inner] -> String.trim(inner)
      nil -> trimmed
    end
  end
end
