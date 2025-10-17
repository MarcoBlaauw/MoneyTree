defmodule MoneyTree.InstitutionsFixtures do
  @moduledoc """
  Helpers for creating institutions and connections in tests.
  """

  alias MoneyTree.Institutions.Connection
  alias MoneyTree.Institutions.Institution
  alias MoneyTree.Repo

  def institution_fixture(attrs \\ %{}) do
    default = %{
      name: "Fixture Bank",
      slug: unique_slug(),
      external_id: unique_slug("ext"),
      website_url: "https://fixture-bank.example",
      encrypted_credentials: "fixture-key"
    }

    attrs = Map.merge(default, Map.new(attrs))

    %Institution{}
    |> Institution.changeset(attrs)
    |> Repo.insert!()
  end

  def connection_fixture(user, attrs \\ %{}) do
    institution =
      Map.get(attrs, :institution) || Map.get(attrs, "institution") || institution_fixture()

    attrs = Map.drop(Map.new(attrs), [:institution])

    default = %{
      encrypted_credentials: "{}",
      metadata: %{"status" => "active"},
      teller_enrollment_id: unique_identifier("enroll"),
      teller_user_id: unique_identifier("teller-user")
    }

    params =
      default
      |> Map.merge(attrs)
      |> Map.put(:user_id, user.id)
      |> Map.put(:institution_id, institution.id)

    %Connection{}
    |> Connection.changeset(params)
    |> Repo.insert!()
  end

  defp unique_slug(prefix \\ "inst") do
    unique_identifier(prefix)
  end

  defp unique_identifier(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end
end
