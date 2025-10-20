defmodule MoneyTree.Assets do
  @moduledoc """
  Tools for managing tangible assets and aggregations for the dashboard.
  """

  import Ecto.Query, warn: false

  alias Decimal
  alias MoneyTree.Accounts
  alias MoneyTree.Accounts.Account
  alias MoneyTree.Assets.Asset
  alias MoneyTree.Repo
  alias MoneyTree.Users.User

  @type asset_params :: map()
  @type summary :: %{
          assets: [map()],
          totals: [map()],
          total_count: non_neg_integer()
        }

  @default_preload [:account]

  @doc """
  Lists assets the user can access.
  """
  @spec list_assets(User.t() | binary(), keyword()) :: [Asset.t()]
  def list_assets(user, opts \\ []) do
    preload = Keyword.get(opts, :preload, @default_preload)

    user
    |> accessible_assets_query(opts)
    |> maybe_preload_query(preload)
    |> Repo.all()
  end

  @doc """
  Fetches a single asset accessible to the user.
  """
  @spec fetch_asset(User.t() | binary(), binary(), keyword()) ::
          {:ok, Asset.t()} | {:error, :not_found}
  def fetch_asset(user, asset_id, opts \\ []) do
    preload = Keyword.get(opts, :preload, @default_preload)

    user
    |> accessible_assets_query(id: asset_id)
    |> maybe_preload_query(preload)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      %Asset{} = asset -> {:ok, asset}
    end
  end

  @doc """
  Returns an asset, raising if not found or inaccessible.
  """
  @spec get_asset!(User.t() | binary(), binary(), keyword()) :: Asset.t()
  def get_asset!(user, asset_id, opts \\ []) do
    case fetch_asset(user, asset_id, opts) do
      {:ok, asset} -> asset
      {:error, :not_found} -> raise Ecto.NoResultsError, queryable: Asset
    end
  end

  @doc """
  Creates a new asset scoped to an accessible account.
  """
  @spec create_asset(User.t() | binary(), asset_params(), keyword()) ::
          {:ok, Asset.t()} | {:error, Ecto.Changeset.t()} | {:error, :unauthorized}
  def create_asset(user, attrs, opts \\ []) do
    attrs = Map.new(attrs)
    preload = Keyword.get(opts, :preload, @default_preload)

    case extract_account_id(attrs) do
      nil ->
        changeset =
          %Asset{}
          |> Asset.changeset(attrs)
          |> Map.put(:action, :insert)

        {:error, changeset}

      account_id ->
        changeset = Asset.changeset(%Asset{}, attrs)

        with {:ok, _account} <- ensure_access_to_account(user, account_id),
             {:ok, asset} <- Repo.insert(changeset) do
          {:ok, maybe_preload(asset, preload)}
        else
          {:error, :unauthorized} -> {:error, :unauthorized}
          {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
        end
    end
  end

  @doc """
  Updates an accessible asset, optionally moving it between accessible accounts.
  """
  @spec update_asset(User.t() | binary(), Asset.t(), asset_params(), keyword()) ::
          {:ok, Asset.t()} | {:error, Ecto.Changeset.t()} | {:error, :unauthorized}
  def update_asset(user, %Asset{} = asset, attrs, opts \\ []) do
    attrs = Map.new(attrs)
    preload = Keyword.get(opts, :preload, @default_preload)

    current_account_id = asset.account_id
    target_account_id = extract_account_id(attrs) || current_account_id

    with {:ok, _} <- ensure_access_to_account(user, current_account_id),
         {:ok, _} <- ensure_access_to_account(user, target_account_id),
         changeset <- Asset.changeset(asset, attrs),
         {:ok, updated} <- Repo.update(changeset) do
      {:ok, maybe_preload(updated, preload)}
    else
      {:error, :unauthorized} -> {:error, :unauthorized}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
    end
  end

  @doc """
  Deletes an accessible asset.
  """
  @spec delete_asset(User.t() | binary(), Asset.t()) ::
          {:ok, Asset.t()} | {:error, :unauthorized} | {:error, Ecto.Changeset.t()}
  def delete_asset(user, %Asset{} = asset) do
    with {:ok, _} <- ensure_access_to_account(user, asset.account_id),
         {:ok, deleted} <- Repo.delete(asset) do
      {:ok, deleted}
    else
      {:error, :unauthorized} -> {:error, :unauthorized}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
    end
  end

  @doc """
  Returns a changeset for tracking asset changes in forms.
  """
  @spec change_asset(Asset.t(), asset_params()) :: Ecto.Changeset.t()
  def change_asset(%Asset{} = asset, attrs \\ %{}) do
    Asset.changeset(asset, attrs)
  end

  @doc """
  Builds formatted summaries for dashboard consumption.
  """
  @spec dashboard_summary(User.t() | binary(), keyword()) :: summary()
  def dashboard_summary(user, opts \\ []) do
    assets = list_assets(user, opts)

    summaries = Enum.map(assets, &build_asset_summary(&1, opts))

    totals =
      summaries
      |> Enum.group_by(& &1.asset.valuation_currency)
      |> Enum.map(fn {currency, items} ->
        total =
          Enum.reduce(items, Decimal.new("0"), fn item, acc ->
            cond do
              is_nil(item.asset.valuation_amount) -> acc
              match?(%Decimal{}, item.asset.valuation_amount) ->
                Decimal.add(acc, item.asset.valuation_amount)

              true ->
                case Decimal.cast(item.asset.valuation_amount) do
                  {:ok, decimal} -> Decimal.add(acc, decimal)
                  :error -> acc
                end
            end
          end)

        %{
          currency: currency,
          asset_count: length(items),
          valuation: Accounts.format_money(total, currency, opts),
          valuation_masked: Accounts.mask_money(total, currency, opts)
        }
      end)
      |> Enum.sort_by(& &1.currency)

    %{
      assets: summaries,
      totals: totals,
      total_count: length(summaries)
    }
  end

  defp accessible_assets_query(user, opts) do
    account_subquery = Accounts.accessible_accounts_query(user)

    Asset
    |> join(:inner, [asset], account in subquery(account_subquery),
      on: asset.account_id == account.id
    )
    |> maybe_filter_account(opts)
    |> maybe_filter_id(opts)
    |> order_by([asset], desc: asset.updated_at)
  end

  defp maybe_filter_account(query, opts) do
    case Keyword.get(opts, :account_id) do
      nil -> query
      %Account{id: account_id} -> where(query, [asset], asset.account_id == ^account_id)
      account_id -> where(query, [asset], asset.account_id == ^account_id)
    end
  end

  defp maybe_filter_id(query, opts) do
    case Keyword.get(opts, :id) do
      nil -> query
      id -> where(query, [asset], asset.id == ^id)
    end
  end

  defp maybe_preload_query(query, preload) when is_list(preload) and preload != [] do
    preload(query, ^preload)
  end

  defp maybe_preload_query(query, _), do: query

  defp ensure_access_to_account(_user, nil), do: {:error, :unauthorized}

  defp ensure_access_to_account(user, %Account{id: id}), do: ensure_access_to_account(user, id)

  defp ensure_access_to_account(user, account_id) when is_binary(account_id) do
    case Accounts.fetch_accessible_account(user, account_id) do
      {:ok, account} -> {:ok, account}
      {:error, :not_found} -> {:error, :unauthorized}
    end
  end

  defp ensure_access_to_account(_user, _other), do: {:error, :unauthorized}

  defp extract_account_id(attrs) do
    cond do
      Map.has_key?(attrs, :account_id) -> normalize_account_id(Map.get(attrs, :account_id))
      Map.has_key?(attrs, "account_id") -> normalize_account_id(Map.get(attrs, "account_id"))
      true -> nil
    end
  end

  defp normalize_account_id(%Account{id: id}), do: id
  defp normalize_account_id(id) when is_binary(id), do: id
  defp normalize_account_id(_), do: nil

  defp maybe_preload(asset, preload) when is_list(preload) and preload != [] do
    Repo.preload(asset, preload)
  end

  defp maybe_preload(asset, _), do: asset

  defp build_asset_summary(%Asset{} = asset, opts) do
    %{
      asset: asset,
      valuation: Accounts.format_money(asset.valuation_amount, asset.valuation_currency, opts),
      valuation_masked: Accounts.mask_money(asset.valuation_amount, asset.valuation_currency, opts)
    }
  end
end
