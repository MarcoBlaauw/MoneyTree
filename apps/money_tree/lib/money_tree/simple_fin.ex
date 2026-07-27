defmodule MoneyTree.SimpleFin do
  @moduledoc """
  SimpleFIN Bridge import-review state shared by the synchronizer and the claim/confirm UI.

  A SimpleFIN connection only ever syncs accounts the user has explicitly approved
  (`import_review.account_ids`). Approving new accounts must never drop accounts approved
  earlier, so `confirm_import/2` merges rather than replaces the confirmed set.
  """

  alias Ecto.Changeset
  alias MoneyTree.Institutions.Connection
  alias MoneyTree.Repo

  @doc """
  Returns the confirmed SimpleFIN account ids for a connection, or `nil` if the
  user has never completed an import review (in which case nothing is filtered).
  """
  @spec selected_account_ids(Connection.t()) :: MapSet.t(String.t()) | nil
  def selected_account_ids(%Connection{} = connection) do
    connection
    |> import_review()
    |> Map.get("account_ids")
    |> case do
      ids when is_list(ids) -> ids |> Enum.filter(&is_binary/1) |> MapSet.new()
      _ -> nil
    end
  end

  @doc """
  Records SimpleFIN accounts seen in a sync response that are not yet part of the
  confirmed selection, without changing what is already confirmed or already synced.
  """
  @spec note_new_accounts(Connection.t(), [map()]) ::
          {:ok, Connection.t()} | {:error, Changeset.t()}
  def note_new_accounts(%Connection{} = connection, []), do: {:ok, connection}

  def note_new_accounts(%Connection{} = connection, discovered_accounts) do
    review = import_review(connection)
    existing_pending = review |> Map.get("pending_new_accounts") |> List.wrap()
    merged_pending = merge_by_id(existing_pending, discovered_accounts)

    if merged_pending == existing_pending do
      {:ok, connection}
    else
      persist_review(connection, Map.put(review, "pending_new_accounts", merged_pending))
    end
  end

  @doc """
  Confirms accounts for import, merging with any previously confirmed accounts so a
  later confirmation (e.g. approving newly discovered accounts) never drops accounts
  approved earlier. Confirmed ids are removed from the pending-new-accounts list.
  """
  @spec confirm_import(Connection.t(), [String.t()]) ::
          {:ok, Connection.t()} | {:error, Changeset.t()}
  def confirm_import(%Connection{} = connection, account_ids) when is_list(account_ids) do
    account_ids = account_ids |> Enum.filter(&is_binary/1)
    review = import_review(connection)

    confirmed_ids =
      (Map.get(review, "account_ids", []) ++ account_ids)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    remaining_pending =
      review
      |> Map.get("pending_new_accounts")
      |> List.wrap()
      |> Enum.reject(&(&1["id"] in account_ids))

    updated_review =
      review
      |> Map.put("status", "confirmed")
      |> Map.put("account_ids", confirmed_ids)
      |> Map.put("selected_count", length(confirmed_ids))
      |> Map.put("confirmed_at", DateTime.to_iso8601(DateTime.utc_now()))
      |> Map.put("pending_new_accounts", remaining_pending)

    persist_review(connection, updated_review)
  end

  @doc """
  Returns the current `import_review` metadata map for a connection.
  """
  @spec import_review(Connection.t()) :: map()
  def import_review(%Connection{provider_metadata: metadata}) do
    metadata
    |> normalize_map()
    |> Map.get("simplefin", %{})
    |> normalize_map()
    |> Map.get("import_review", %{})
    |> normalize_map()
  end

  defp persist_review(%Connection{provider_metadata: metadata} = connection, updated_review) do
    metadata = normalize_map(metadata)
    simplefin = metadata |> Map.get("simplefin", %{}) |> normalize_map()

    provider_metadata =
      Map.put(metadata, "simplefin", Map.put(simplefin, "import_review", updated_review))

    connection
    |> Connection.changeset(%{provider_metadata: provider_metadata})
    |> Repo.update()
  end

  defp merge_by_id(existing, new_accounts) do
    existing
    |> Enum.into(%{}, &{&1["id"], &1})
    |> then(
      &Enum.reduce(new_accounts, &1, fn account, acc -> Map.put(acc, account["id"], account) end)
    )
    |> Map.values()
  end

  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(_value), do: %{}
end
