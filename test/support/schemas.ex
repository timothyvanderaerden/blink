defmodule Blink.Test.Schemas.Triage do
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

defmodule Blink.Test.Schemas.Safety do
  @moduledoc false

  use Blink.Schema

  decision_schema do
    field :safe, :boolean, required: true
    field :flags, {:array, :string}, default: []
  end
end

defmodule Blink.Test.Schemas.Loose do
  @moduledoc false

  use Blink.Schema

  decision_schema do
    field :score, :integer
    field :note, :string
  end
end

defmodule Blink.Test.Schemas.PlainEcto do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    field :intent, :string
    field :requires_system_2, :boolean
    field :extracted_entities, {:array, :string}, default: []
    field :reasoning_summary, :string
  end

  def changeset(schema, params) do
    schema
    |> cast(params, [:intent, :requires_system_2, :extracted_entities, :reasoning_summary])
    |> validate_required([:intent, :requires_system_2])
    |> validate_inclusion(
      :intent,
      ["simple_query", "code_refactor", "complex_reasoning", "unclear"]
    )
  end
end

# A schema whose module name is exactly "Schema": the default check-name
# derivation has nothing left after stripping the "Schema" suffix, so the
# facade must fall back to :check_<idx>.
defmodule Blink.Test.Schemas.Schema do
  @moduledoc false

  use Blink.Schema

  decision_schema do
    field :ok, :boolean
  end
end
