defmodule MoneyTree.Institutions.Institution do
  @moduledoc """
  Financial institution metadata and encrypted credentials for upstream aggregators.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias MoneyTree.Accounts.Account
  alias MoneyTree.Encrypted.Binary
  alias MoneyTree.Institutions.Connection

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "institutions" do
    field :name, :string
    field :slug, :string
    field :external_id, :string
    field :website_url, :string
    field :encrypted_credentials, Binary
    field :metadata, :map, default: %{}

    has_many :connections, Connection, on_delete: :delete_all
    has_many :accounts, Account

    timestamps()
  end

  @doc false
  def changeset(institution, attrs) do
    institution
    |> cast(attrs, [
      :name,
      :slug,
      :external_id,
      :website_url,
      :encrypted_credentials,
      :metadata
    ])
    |> validate_required([:name, :slug, :external_id])
    |> update_change(:slug, &normalize_slug/1)
    |> validate_format(:slug, ~r/^[a-z0-9-]+$/,
      message: "must contain lowercase letters, numbers, or hyphens"
    )
    |> validate_length(:name, min: 2, max: 160)
    |> validate_website_url()
    |> unique_constraint(:slug)
    |> unique_constraint(:external_id)
  end

  defp normalize_slug(slug) when is_binary(slug) do
    slug
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9-]+/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
  end

  defp normalize_slug(other), do: other

  defp validate_website_url(changeset) do
    validate_change(changeset, :website_url, fn :website_url, url ->
      case valid_url?(url) do
        true -> []
        false -> [website_url: "must be a valid http or https URL"]
      end
    end)
  end

  defp valid_url?(nil), do: true

  defp valid_url?(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme}} when scheme in ["http", "https"] -> true
      _ -> false
    end
  end

  defp valid_url?(_), do: false
end
