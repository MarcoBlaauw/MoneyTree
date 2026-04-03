defmodule MoneyTree.Obligations do
  @moduledoc """
  Payment obligation management and due-state evaluation.
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias MoneyTree.Accounts
  alias MoneyTree.Accounts.Account
  alias MoneyTree.Obligations.CheckWorker
  alias MoneyTree.Obligations.Evaluator
  alias MoneyTree.Obligations.Obligation
  alias MoneyTree.Repo
  alias MoneyTree.Users.User
  alias Oban

  @type result :: {:ok, Obligation.t()} | {:error, Changeset.t() | atom()}

  @doc """
  Lists obligations accessible to the user.
  """
  @spec list_obligations(User.t() | binary(), keyword()) :: [Obligation.t()]
  def list_obligations(user, opts \\ []) do
    preload = Keyword.get(opts, :preload, [:linked_funding_account])

    Obligation
    |> where([obligation], obligation.user_id == ^normalize_user_id(user))
    |> order_by([obligation], asc: obligation.creditor_payee)
    |> Repo.all()
    |> Repo.preload(preload)
  end

  @doc """
  Fetches a single obligation scoped to the provided user.
  """
  @spec fetch_obligation(User.t() | binary(), binary(), keyword()) ::
          {:ok, Obligation.t()} | {:error, :not_found}
  def fetch_obligation(user, obligation_id, opts \\ [])

  def fetch_obligation(user, obligation_id, opts) when is_binary(obligation_id) do
    preload = Keyword.get(opts, :preload, [:linked_funding_account])

    Obligation
    |> where(
      [obligation],
      obligation.id == ^obligation_id and obligation.user_id == ^normalize_user_id(user)
    )
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      %Obligation{} = obligation -> {:ok, Repo.preload(obligation, preload)}
    end
  end

  def fetch_obligation(_user, _obligation_id, _opts), do: {:error, :not_found}

  @doc """
  Returns a changeset for an obligation.
  """
  @spec change_obligation(Obligation.t(), map()) :: Changeset.t()
  def change_obligation(%Obligation{} = obligation, attrs \\ %{}) do
    Obligation.changeset(obligation, attrs)
  end

  @doc """
  Creates a new obligation for the user after validating funding-account access.
  """
  @spec create_obligation(User.t() | binary(), map()) :: result()
  def create_obligation(user, attrs) when is_map(attrs) do
    attrs = normalize_attr_map(attrs)
    user_id = normalize_user_id(user)

    with {:ok, account_id} <- fetch_funding_account_id(attrs),
         :ok <- authorize_account(user, account_id) do
      %Obligation{}
      |> Obligation.changeset(
        attrs
        |> Map.put("user_id", user_id)
        |> Map.put_new("currency", funding_account_currency(account_id))
      )
      |> Repo.insert()
    end
  end

  @doc """
  Updates an obligation after validating ownership and any funding-account change.
  """
  @spec update_obligation(User.t() | binary(), Obligation.t() | binary(), map()) :: result()
  def update_obligation(user, %Obligation{} = obligation, attrs) when is_map(attrs) do
    attrs = normalize_attr_map(attrs)

    with :ok <- authorize_obligation(user, obligation),
         {:ok, attrs} <- maybe_prepare_funding_account_attrs(user, attrs, obligation) do
      obligation
      |> Obligation.changeset(attrs)
      |> Repo.update()
    end
  end

  def update_obligation(user, obligation_id, attrs)
      when is_binary(obligation_id) and is_map(attrs) do
    with {:ok, %Obligation{} = obligation} <- fetch_obligation(user, obligation_id),
         {:ok, %Obligation{} = updated} <- update_obligation(user, obligation, attrs) do
      {:ok, updated}
    end
  end

  @doc """
  Deletes an obligation owned by the supplied user.
  """
  @spec delete_obligation(User.t() | binary(), Obligation.t() | binary()) ::
          {:ok, Obligation.t()} | {:error, :not_found}
  def delete_obligation(user, %Obligation{} = obligation) do
    with :ok <- authorize_obligation(user, obligation),
         {:ok, %Obligation{} = deleted} <- Repo.delete(obligation) do
      {:ok, deleted}
    end
  end

  def delete_obligation(user, obligation_id) when is_binary(obligation_id) do
    with {:ok, %Obligation{} = obligation} <- fetch_obligation(user, obligation_id) do
      delete_obligation(user, obligation)
    end
  end

  @doc """
  Evaluates all active obligations for the provided day.
  """
  @spec check_all(Date.t()) :: :ok | {:error, term()}
  def check_all(%Date{} = date) do
    Obligation
    |> where([obligation], obligation.active == true)
    |> preload([:user, :linked_funding_account])
    |> Repo.all()
    |> Enum.each(fn obligation ->
      {:ok, _result} = Evaluator.evaluate(obligation, date)
    end)

    :ok
  end

  @doc """
  Enqueues a daily obligation check for the supplied date.
  """
  @spec enqueue_check(Date.t()) :: :ok | {:error, term()}
  def enqueue_check(%Date{} = date) do
    %{"date" => Date.to_iso8601(date)}
    |> CheckWorker.new(unique: [keys: [:date], period: 120])
    |> Oban.insert()
    |> case do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns user-facing obligation data for dashboard or forms.
  """
  @spec summary(User.t() | binary()) :: [map()]
  def summary(user) do
    list_obligations(user, preload: [:linked_funding_account])
    |> Enum.map(fn obligation ->
      %{
        id: obligation.id,
        creditor_payee: obligation.creditor_payee,
        due_rule: obligation.due_rule,
        due_day: obligation.due_day,
        minimum_due_amount:
          Accounts.format_money(obligation.minimum_due_amount, obligation.currency, []),
        grace_period_days: obligation.grace_period_days,
        linked_funding_account_name:
          obligation.linked_funding_account && obligation.linked_funding_account.name,
        active: obligation.active
      }
    end)
  end

  defp authorize_account(user, account_id) do
    case Repo.one(
           from(account in subquery(Accounts.accessible_accounts_query(user)),
             where: account.id == ^account_id,
             select: account.id
           )
         ) do
      nil -> {:error, :unauthorized}
      _account_id -> :ok
    end
  end

  defp fetch_funding_account_id(attrs) do
    case Map.get(attrs, :linked_funding_account_id) || Map.get(attrs, "linked_funding_account_id") do
      account_id when is_binary(account_id) and account_id != "" -> {:ok, account_id}
      _ -> {:error, :linked_funding_account_required}
    end
  end

  defp funding_account_currency(account_id) do
    case Repo.get(Account, account_id) do
      %Account{currency: currency} -> currency
      _ -> "USD"
    end
  end

  defp authorize_obligation(user, %Obligation{user_id: user_id}) do
    if user_id == normalize_user_id(user), do: :ok, else: {:error, :not_found}
  end

  defp maybe_prepare_funding_account_attrs(user, attrs, obligation) do
    case Map.get(attrs, :linked_funding_account_id) || Map.get(attrs, "linked_funding_account_id") do
      account_id when is_binary(account_id) and account_id != "" ->
        with :ok <- authorize_account(user, account_id) do
          {:ok, Map.put_new(attrs, "currency", funding_account_currency(account_id))}
        end

      _ ->
        {:ok,
         attrs
         |> Map.drop(["linked_funding_account_id"])
         |> Map.put_new("currency", obligation.currency)}
    end
  end

  defp normalize_attr_map(attrs) do
    attrs
    |> Map.new()
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      Map.put(acc, normalize_key(key), value)
    end)
  end

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: key

  defp normalize_user_id(%User{id: user_id}), do: user_id
  defp normalize_user_id(user_id) when is_binary(user_id), do: user_id
end
