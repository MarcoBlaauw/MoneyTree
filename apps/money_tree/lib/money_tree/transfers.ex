defmodule MoneyTree.Transfers do
  @moduledoc """
  High-level operations for creating and confirming transfers between accounts.
  """

  import Ecto.Query, warn: false

  alias Decimal
  alias Ecto.Changeset
  alias Ecto.Multi
  alias MoneyTree.Accounts
  alias MoneyTree.Accounts.Account
  alias MoneyTree.Repo
  alias MoneyTree.Synchronization
  alias MoneyTree.Transfers.TransferRequest
  alias MoneyTree.Users.User

  @type user_ref :: User.t() | binary()

  @doc """
  Builds a changeset for the transfer form using the provided attributes.
  """
  @spec change_transfer(user_ref(), map()) :: Changeset.t()
  def change_transfer(user, attrs \\ %{}) do
    accounts = Accounts.list_accessible_accounts(user, preload: [:institution_connection])

    %TransferRequest{}
    |> TransferRequest.changeset(attrs, accounts: accounts, action: :validate)
  end

  @doc """
  Confirms and applies the transfer, returning the updated accounts when successful.
  """
  @spec submit_transfer(user_ref(), map()) ::
          {:ok, %{transfer: TransferRequest.t(), source: Account.t(), destination: Account.t()}}
          | {:error, Changeset.t()}
  def submit_transfer(user, attrs) when is_map(attrs) do
    accounts = Accounts.list_accessible_accounts(user, preload: [:institution_connection])

    changeset =
      %TransferRequest{}
      |> TransferRequest.changeset(attrs, accounts: accounts, action: :validate)

    with {:ok, transfer} <- Changeset.apply_action(changeset, :validate) do
      do_submit_transfer(user, transfer)
    else
      {:error, %Changeset{} = invalid_changeset} -> {:error, invalid_changeset}
    end
  end

  defp do_submit_transfer(user, %TransferRequest{} = transfer) do
    Multi.new()
    |> Multi.run(:source, fn _repo, _changes ->
      Accounts.fetch_accessible_account(user, transfer.source_account_id,
        lock: "FOR UPDATE",
        preload: [:institution_connection]
      )
    end)
    |> Multi.run(:destination, fn _repo, _changes ->
      Accounts.fetch_accessible_account(user, transfer.destination_account_id,
        lock: "FOR UPDATE",
        preload: [:institution_connection]
      )
    end)
    |> Multi.run(:validate_balance, fn _repo, %{source: source} ->
      ensure_balance(source, transfer.amount)
    end)
    |> Multi.update(:updated_source, fn %{source: source} ->
      update_account_balance(source, transfer.amount, :debit)
    end)
    |> Multi.update(:updated_destination, fn %{destination: destination} ->
      update_account_balance(destination, transfer.amount, :credit)
    end)
    |> Repo.transaction()
    |> case do
      {:ok,
       %{
         updated_source: source,
         updated_destination: destination
       }} ->
        schedule_synchronization([source, destination])

        {:ok,
         %{
           transfer: transfer,
           source: source,
           destination: destination
         }}

      {:error, _operation, %Changeset{} = changeset, _changes_so_far} ->
        {:error, changeset}

      {:error, _operation, :not_found, _changes_so_far} ->
        {:error, Changeset.change(%TransferRequest{}, %{}) |> add_not_found_error()}
    end
  end

  defp ensure_balance(%Account{} = account, %Decimal{} = amount) do
    available = account.available_balance || account.current_balance || Decimal.new("0")

    if Decimal.compare(available, amount) == :lt do
      error_changeset =
        %TransferRequest{}
        |> Changeset.change(%{})
        |> Changeset.add_error(:amount, "exceeds available balance")
        |> Map.put(:action, :validate)

      {:error, error_changeset}
    else
      {:ok, account}
    end
  end

  defp update_account_balance(%Account{} = account, %Decimal{} = amount, :debit) do
    params =
      account
      |> balance_delta(amount, :debit)

    Account.changeset(account, params)
  end

  defp update_account_balance(%Account{} = account, %Decimal{} = amount, :credit) do
    params =
      account
      |> balance_delta(amount, :credit)

    Account.changeset(account, params)
  end

  defp balance_delta(account, amount, direction) do
    current_balance = normalize_decimal(account.current_balance)
    available_balance = normalize_decimal(account.available_balance || account.current_balance)

    case direction do
      :debit ->
        %{
          current_balance: Decimal.sub(current_balance, amount),
          available_balance: Decimal.sub(available_balance, amount)
        }

      :credit ->
        %{
          current_balance: Decimal.add(current_balance, amount),
          available_balance: Decimal.add(available_balance, amount)
        }
    end
  end

  defp normalize_decimal(nil), do: Decimal.new("0")
  defp normalize_decimal(%Decimal{} = decimal), do: decimal

  defp schedule_synchronization(accounts) do
    Enum.each(accounts, fn
      %Account{institution_connection: %{}} = account ->
        Synchronization.schedule_incremental_sync(account.institution_connection,
          telemetry_metadata: %{reason: "transfer"}
        )

      _ ->
        :ok
    end)
  end

  defp add_not_found_error(changeset) do
    changeset
    |> Changeset.add_error(:source_account_id, "could not verify accounts")
    |> Map.put(:action, :validate)
  end
end
