defmodule MoneyTree.Categorization.UserOverride do
  @moduledoc """
  Manual transaction-level category overrides.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias MoneyTree.Transactions.Transaction

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @valid_sources ~w(provider rule manual model)

  schema "user_category_overrides" do
    field :category, :string
    field :confidence, :decimal
    field :source, :string, default: "manual"

    belongs_to :transaction, Transaction

    timestamps()
  end

  def changeset(override, attrs) do
    override
    |> cast(attrs, [:transaction_id, :category, :confidence, :source])
    |> validate_required([:transaction_id, :category, :source])
    |> validate_length(:category, min: 1, max: 120)
    |> validate_inclusion(:source, @valid_sources)
    |> unique_constraint(:transaction_id)
    |> foreign_key_constraint(:transaction_id)
  end
end
