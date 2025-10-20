defmodule MoneyTree.Assets do
  @moduledoc """
  Context for managing tangible assets tied to accounts and memberships.
  """

  import Ecto.Query, warn: false

  alias Decimal
  alias Ecto.Changeset
  alias MoneyTree.Accounts
  alias MoneyTree.Accounts.Account
  alias MoneyTree.Assets.Asset
  alias MoneyTree.Repo
  alias MoneyTree.Users.User

  @type asset_result :: {:ok, Asset.t()} | {:error, Changeset.t()} | {:error, :not_found}

  @doc """
  Returns a query for assets accessible to the user based on account memberships.
  """
  @spec accessible_assets_query(User.t() | binary()) :: Ecto.Query.t()
  def accessible_assets_query(user) do
    accessible_accounts = Accounts.accessible_accounts_query(user)

    from asset in Asset,
      join: account in subquery(accessible_accounts),
      on: account.id == asset.account_id,
      preload: [account: account]
  end

  @doc """
  Lists assets for the given account.
  """
  @spec list_assets_for_account(Account.t() | binary(), keyword()) :: [Asset.t()]
  def list_assets_for_account(account, opts \\ [])

  def list_assets_for_account(%Account{id: id}, opts), do: list_assets_for_account(id, opts)

  def list_assets_for_account(account_id, opts) when is_binary(account_id) do
    Asset
    |> where([asset], asset.account_id == ^account_id)
    |> order_by(desc: :updated_at)
    |> maybe_preload(opts)
    |> Repo.all()
  end

  @doc """
  Lists assets accessible to the given user.
  """
  @spec list_accessible_assets(User.t() | binary(), keyword()) :: [Asset.t()]
  def list_accessible_assets(user, opts \\ []) do
    accessible_assets_query(user)
    |> order_by(desc: :updated_at)
    |> maybe_preload(opts)
    |> Repo.all()
  end

  @doc """
  Fetches an asset accessible to the user.
  """
  @spec fetch_accessible_asset(User.t() | binary(), binary(), keyword()) ::
          {:ok, Asset.t()} | {:error, :not_found}
  def fetch_accessible_asset(user, asset_id, opts \\ []) do
    accessible_assets_query(user)
    |> where([asset], asset.id == ^asset_id)
    |> maybe_preload(opts)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      %Asset{} = asset -> {:ok, asset}
    end
  end

  @doc """
  Summarizes accessible assets for dashboard rendering.
  """
  @spec dashboard_summary(User.t() | binary(), keyword()) :: %{assets: list(), totals: list()}
  def dashboard_summary(user, opts \\ []) do
    assets = list_accessible_assets(user, opts)

    summaries = Enum.map(assets, &asset_summary(&1, opts))

    totals =
      summaries
      |> Enum.group_by(& &1.valuation_currency)
      |> Enum.map(fn {currency, grouped} ->
        total_amount =
          grouped
          |> Enum.map(& &1.valuation_amount_decimal)
          |> sum_decimals()

        %{
          currency: currency,
          total_amount: format_money(total_amount, currency, opts),
          total_amount_masked: mask_money(total_amount, currency, opts),
          asset_count: length(grouped)
        }
      end)

    %{assets: summaries, totals: totals}
  end

  @doc """
  Creates an asset scoped to an account accessible to the user.
  """
  @spec create_asset_for_user(User.t() | binary(), map()) :: asset_result()
  def create_asset_for_user(user, attrs) when is_map(attrs) do
    with {:ok, account_id} <- resolve_account_id(user, attrs) do
      params =
        attrs
        |> Map.new()
        |> Map.put(:account_id, account_id)

      %Asset{}
      |> Asset.changeset(params)
      |> Repo.insert()
    end
  end

  @doc """
  Updates an asset when accessible to the user.
  """
  @spec update_asset_for_user(User.t() | binary(), Asset.t(), map()) :: asset_result()
  def update_asset_for_user(user, %Asset{} = asset, attrs) when is_map(attrs) do
    with {:ok, %Asset{} = current} <- fetch_accessible_asset(user, asset.id) do
      current
      |> Asset.changeset(attrs)
      |> Repo.update()
    end
  end

  @doc """
  Deletes an asset accessible to the user.
  """
  @spec delete_asset_for_user(User.t() | binary(), Asset.t()) ::
          {:ok, Asset.t()} | {:error, :not_found}
  def delete_asset_for_user(user, %Asset{} = asset) do
    with {:ok, %Asset{} = current} <- fetch_accessible_asset(user, asset.id) do
      Repo.delete(current)
    end
  end

  @doc """
  Returns an asset changeset for form rendering.
  """
  @spec change_asset(Asset.t(), map()) :: Changeset.t()
  def change_asset(%Asset{} = asset, attrs \\ %{}) do
    Asset.changeset(asset, attrs)
  end

  defp resolve_account_id(user, attrs) do
    account_id = Map.get(attrs, :account_id) || Map.get(attrs, "account_id")

    case account_id do
      nil ->
        {:error, :not_found}

      id when is_binary(id) ->
        case Accounts.fetch_accessible_account(user, id) do
          {:ok, %Account{id: account_id}} -> {:ok, account_id}
          {:error, :not_found} -> {:error, :not_found}
        end

      %Account{id: id} ->
        case Accounts.fetch_accessible_account(user, id) do
          {:ok, %Account{id: account_id}} -> {:ok, account_id}
          {:error, :not_found} -> {:error, :not_found}
        end

      other ->
        raise ArgumentError, "unsupported account reference: #{inspect(other)}"
    end
  end

  defp maybe_preload(query, opts) do
    case Keyword.get(opts, :preload) do
      nil -> query
      preload -> preload(query, ^preload)
    end
  end

  defp asset_summary(%Asset{} = asset, opts) do
    %{
      asset: asset,
      valuation_currency: asset.valuation_currency,
      valuation_amount: format_money(asset.valuation_amount, asset.valuation_currency, opts),
      valuation_amount_masked: mask_money(asset.valuation_amount, asset.valuation_currency, opts),
      valuation_amount_decimal: asset.valuation_amount,
      ownership: asset.ownership,
      location: asset.location,
      type: asset.type
    }
  end

  defp format_money(nil, _currency, _opts), do: nil

  defp format_money(%Decimal{} = amount, currency, _opts) when is_binary(currency) do
    amount
    |> Decimal.round(2)
    |> Decimal.to_string(:normal)
    |> ensure_two_decimals()
    |> prepend_currency(currency)
  end

  defp format_money(amount, currency, opts) when is_binary(currency) do
    case Decimal.cast(amount) do
      {:ok, decimal} -> format_money(decimal, currency, opts)
      :error -> nil
    end
  end

  defp mask_money(amount, currency, opts) do
    mask_character = Keyword.get(opts, :mask_character, "•")

    amount
    |> format_money(currency, opts)
    |> maybe_mask(mask_character)
  end

  defp ensure_two_decimals(amount) do
    case String.split(amount, ".") do
      [_] -> amount <> ".00"
      [int, dec] when byte_size(dec) == 1 -> int <> "." <> dec <> "0"
      [int, dec] when byte_size(dec) >= 2 -> int <> "." <> String.slice(dec, 0, 2)
      _ -> amount
    end
  end

  defp prepend_currency(amount, currency) when is_binary(amount) do
    "#{currency} #{amount}"
  end

  defp maybe_mask(nil, _), do: nil

  defp maybe_mask(value, mask_character) do
    Regex.replace(~r/\d/, value, mask_character)
  end

  defp sum_decimals(values) do
    Enum.reduce(values, Decimal.new("0"), fn
      nil, acc ->
        acc

      %Decimal{} = decimal, acc ->
        Decimal.add(acc, decimal)

      other, acc ->
        case Decimal.cast(other) do
          {:ok, decimal} -> Decimal.add(acc, decimal)
          :error -> acc
        end
    end)
  end
end
