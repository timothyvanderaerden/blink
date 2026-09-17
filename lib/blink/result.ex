defmodule Blink.Result do
  @moduledoc """
  The outcome of a single Blink gate evaluation.

  A result is always produced when the local endpoint answers: the `status`
  field tells you whether the System 1 model handled the request
  (`:handled_locally`) or the request must be escalated to a heavier
  System 2 reasoning pipeline (`:escalate_to_system_2`).
  """

  @type status :: :handled_locally | :escalate_to_system_2

  defstruct [
    :status,
    :data,
    :confidence,
    :low_confidence?,
    :intent,
    :requires_system_2,
    :reason,
    :schema,
    :model,
    :latency_ms,
    :winner,
    :checks
  ]

  @type t :: %__MODULE__{
          status: status() | nil,
          data: struct() | nil,
          confidence: float() | nil,
          low_confidence?: boolean() | nil,
          intent: String.t() | nil,
          requires_system_2: boolean() | nil,
          reason: atom() | {atom(), term()} | nil,
          schema: module() | nil,
          model: String.t() | nil,
          latency_ms: number() | nil,
          winner: atom() | nil,
          checks: [{atom(), t() | {:error, term()}}] | nil
        }

  @doc "True when the local System 1 model handled the request."
  def handled_locally?(%__MODULE__{status: :handled_locally}), do: true
  def handled_locally?(%__MODULE__{}), do: false
end
