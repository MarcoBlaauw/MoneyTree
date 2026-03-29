defmodule MoneyTree.Categorization.CategoryRule do
  @moduledoc """
  User and system categorization rules.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias MoneyTree.Users.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @valid_sources ~w(provider rule manual model)

  schema "category_rules" do
    field :category, :string
    field :merchant_regex, :string
    field :description_keywords, {:array, :string}, default: []
    field :min_amount, :decimal
    field :max_amount, :decimal
    field :account_types, {:array, :string}, default: []
    field :priority, :integer, default: 0
    field :confidence, :decimal
    field :source, :string, default: "rule"

    belongs_to :user, User

    timestamps()
  end

  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [
      :user_id,
      :category,
      :merchant_regex,
      :description_keywords,
      :min_amount,
      :max_amount,
      :account_types,
      :priority,
      :confidence,
      :source
    ])
    |> validate_required([:category, :priority])
    |> validate_length(:category, min: 1, max: 120)
    |> validate_length(:merchant_regex, max: 300)
    |> validate_inclusion(:source, @valid_sources)
    |> validate_number(:priority, greater_than_or_equal_to: -1000, less_than_or_equal_to: 100_000)
    |> validate_change(:merchant_regex, fn :merchant_regex, regex ->
      case Regex.compile(regex || "") do
        {:ok, _} -> []
        {:error, _} -> [merchant_regex: "must be a valid regex"]
      end
    end)
    |> foreign_key_constraint(:user_id)
  end
end
