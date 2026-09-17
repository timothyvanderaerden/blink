defmodule Blink.Confidence do
  @moduledoc """
  Calibrated logprob analysis for System 1 decisions.

  Rather than trusting a score the model reports about itself, Blink derives
  confidence from the raw token logprobs returned by the local endpoint.
  The confidence of a decision is the geometric mean of the probabilities
  of the model's decision tokens:

      confidence = exp( (1 / N) * Σᵢ ln P(tᵢ) ) = exp( (1 / N) * Σᵢ logprobᵢ )

  Structural tokens (JSON punctuation such as `{`, `}`, `"`, `,`, `:` and
  whitespace) carry no semantic weight, so they are excluded from the mean
  by default. Entries without a numeric `logprob` are excluded as well.
  """

  @default_threshold 0.75
  @structural ~r/^[{}[\]",:\s]+$/

  defstruct [
    :confidence,
    :low_confidence?,
    :tokens_used,
    :tokens_total,
    :threshold,
    :excluded
  ]

  @type t :: %__MODULE__{
          confidence: float() | nil,
          low_confidence?: boolean(),
          tokens_used: non_neg_integer(),
          tokens_total: non_neg_integer(),
          threshold: float(),
          excluded: non_neg_integer()
        }

  @doc """
  Computes a calibrated confidence report from token logprob entries.

  Each entry is a map as found in the `logprobs.content` array of an
  OpenAI-compatible chat completion, e.g.
  `%{"token" => "yes", "logprob" => -0.02}`. Both string and atom keys are
  accepted.

  ## Options

    * `:threshold` - confidence strictly below this value is flagged
      `low_confidence?` (default `#{@default_threshold}`).
    * `:include_structural` - when `true`, punctuation/whitespace tokens are
      included in the geometric mean (default `false`).
  """
  def from_logprobs(entries, opts \\ []) when is_list(entries) do
    threshold = Keyword.get(opts, :threshold, @default_threshold)
    include_structural = Keyword.get(opts, :include_structural, false)

    kept =
      entries
      |> Enum.filter(&has_logprob?/1)
      |> then(fn list ->
        if include_structural do
          list
        else
          Enum.reject(list, fn entry -> structural_token?(entry_token(entry)) end)
        end
      end)

    tokens_total = length(entries)
    tokens_used = length(kept)

    confidence =
      if tokens_used == 0 do
        nil
      else
        kept
        |> Enum.reduce(0.0, fn entry, acc -> acc + entry_logprob(entry) end)
        |> Kernel./(tokens_used)
        |> :math.exp()
      end

    %__MODULE__{
      confidence: confidence,
      low_confidence?: confidence == nil or confidence < threshold,
      tokens_used: tokens_used,
      tokens_total: tokens_total,
      threshold: threshold,
      excluded: tokens_total - tokens_used
    }
  end

  @doc "True when the token is pure JSON scaffolding or whitespace."
  def structural_token?(token) when is_binary(token), do: Regex.match?(@structural, token)
  def structural_token?(_token), do: false

  defp has_logprob?(%{"logprob" => logprob}) when is_number(logprob), do: true
  defp has_logprob?(%{logprob: logprob}) when is_number(logprob), do: true
  defp has_logprob?(_entry), do: false

  defp entry_token(%{"token" => token}), do: token
  defp entry_token(%{token: token}), do: token
  defp entry_token(_entry), do: nil

  defp entry_logprob(%{"logprob" => logprob}) when is_number(logprob), do: logprob
  defp entry_logprob(%{logprob: logprob}) when is_number(logprob), do: logprob
end
