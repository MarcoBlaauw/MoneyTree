defmodule MoneyTree.AI.UserPreference do
  @moduledoc """
  User-scoped AI preferences for provider settings and feature toggles.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias MoneyTree.Users.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @providers ~w(ollama)

  schema "ai_user_preferences" do
    field :local_ai_enabled, :boolean, default: false
    field :provider, :string, default: "ollama"
    field :ollama_base_url, :string
    field :default_model, :string
    field :allow_ai_for_categorization, :boolean, default: true
    field :allow_ai_for_budget_recommendations, :boolean, default: false
    field :allow_ai_pattern_detection, :boolean, default: false
    field :store_prompt_debug_data, :boolean, default: false

    belongs_to :user, User

    timestamps()
  end

  @doc false
  def changeset(preference, attrs) do
    preference
    |> cast(attrs, [
      :user_id,
      :local_ai_enabled,
      :provider,
      :ollama_base_url,
      :default_model,
      :allow_ai_for_categorization,
      :allow_ai_for_budget_recommendations,
      :allow_ai_pattern_detection,
      :store_prompt_debug_data
    ])
    |> validate_required([:user_id, :provider])
    |> validate_length(:provider, max: 60)
    |> validate_length(:ollama_base_url, max: 500)
    |> validate_length(:default_model, max: 120)
    |> validate_inclusion(:provider, @providers)
    |> unique_constraint(:user_id)
    |> foreign_key_constraint(:user_id)
  end
end
