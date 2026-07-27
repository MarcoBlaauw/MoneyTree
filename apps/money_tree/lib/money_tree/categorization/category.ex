defmodule MoneyTree.Categorization.Category do
  @moduledoc """
  User-managed category registry.

  Transactions and budgets still store category names as strings; this registry
  provides a managed list for prompts, forms, and rule authoring.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias MoneyTree.Users.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @kinds ~w(income expense transfer other)
  @sources ~w(manual model import system)

  schema "user_categories" do
    field :name, :string
    field :emoji, :string, default: "🏷️"
    field :kind, :string, default: "expense"
    field :source, :string, default: "manual"
    field :active, :boolean, default: true

    belongs_to :user, User

    timestamps()
  end

  @type t :: %__MODULE__{}

  def changeset(category, attrs) do
    category
    |> cast(attrs, [:user_id, :name, :emoji, :kind, :source, :active])
    |> update_change(:name, &normalize_name/1)
    |> put_default_emoji()
    |> validate_required([:user_id, :name, :emoji, :kind, :source])
    |> validate_length(:name, min: 1, max: 120)
    |> validate_length(:emoji, min: 1, max: 16)
    |> validate_not_reserved_name()
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:source, @sources)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:name, name: :user_categories_user_id_lower_name_index)
  end

  def kinds, do: @kinds

  defp validate_not_reserved_name(changeset) do
    validate_change(changeset, :name, fn :name, name ->
      if is_binary(name) and String.downcase(String.trim(name)) == "uncategorized" do
        [name: "is reserved for uncategorized transactions"]
      else
        []
      end
    end)
  end

  defp normalize_name(name) when is_binary(name), do: String.trim(name)
  defp normalize_name(name), do: name

  defp put_default_emoji(changeset) do
    case get_field(changeset, :emoji) do
      emoji when is_binary(emoji) ->
        emoji = String.trim(emoji)

        if emoji == "",
          do: put_change(changeset, :emoji, "🏷️"),
          else: put_change(changeset, :emoji, emoji)

      _ ->
        put_change(changeset, :emoji, "🏷️")
    end
  end
end
