defmodule MoneyTree.Transfers.TransferRequest do
  @moduledoc """
  Embedded schema used for validating transfer requests before applying changes.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Decimal
  alias MoneyTree.Accounts.Account

  @primary_key false

  embedded_schema do
    field :source_account_id, :binary_id
    field :destination_account_id, :binary_id
    field :amount, :decimal
    field :currency, :string
    field :memo, :string

    field :source_account, :any, virtual: true
    field :destination_account, :any, virtual: true
  end

  @doc false
  def changeset(transfer, attrs, opts \\ []) do
    accounts = Keyword.get(opts, :accounts, [])

    transfer
    |> cast(attrs, [:source_account_id, :destination_account_id, :amount, :currency, :memo])
    |> validate_required([:source_account_id, :destination_account_id, :amount])
    |> validate_number(:amount, greater_than: Decimal.new("0"))
    |> validate_length(:memo, max: 280)
    |> normalize_currency(accounts)
    |> put_accounts(accounts)
    |> validate_account_access()
    |> validate_account_difference()
    |> validate_currency_match()
    |> validate_available_balance(Keyword.get(opts, :validate_balance, true))
    |> maybe_put_action(Keyword.get(opts, :action))
  end

  defp normalize_currency(changeset, accounts) do
    case fetch_source_account(changeset, accounts) do
      %Account{currency: currency} -> put_change(changeset, :currency, currency)
      _ -> changeset
    end
  end

  defp put_accounts(changeset, accounts) do
    changeset
    |> put_change(:source_account, fetch_source_account(changeset, accounts))
    |> put_change(:destination_account, fetch_destination_account(changeset, accounts))
  end

  defp validate_account_access(%Changeset{} = changeset) do
    changeset
    |> validate_change(:source_account_id, fn :source_account_id, _value ->
      if get_change(changeset, :source_account) do
        []
      else
        [source_account_id: "is not accessible"]
      end
    end)
    |> validate_change(:destination_account_id, fn :destination_account_id, _value ->
      if get_change(changeset, :destination_account) do
        []
      else
        [destination_account_id: "is not accessible"]
      end
    end)
  end

  defp validate_account_difference(%Changeset{} = changeset) do
    source_id = get_field(changeset, :source_account_id)
    destination_id = get_field(changeset, :destination_account_id)

    if source_id && destination_id && source_id == destination_id do
      add_error(changeset, :destination_account_id, "must be different from source account")
    else
      changeset
    end
  end

  defp validate_currency_match(%Changeset{} = changeset) do
    source = get_change(changeset, :source_account)
    destination = get_change(changeset, :destination_account)

    cond do
      !source || !destination -> changeset
      source.currency == destination.currency -> changeset
      true -> add_error(changeset, :destination_account_id, "must match source account currency")
    end
  end

  defp validate_available_balance(changeset, false), do: changeset

  defp validate_available_balance(changeset, true) do
    with %Account{} = source <- get_change(changeset, :source_account),
         %Decimal{} = amount <- get_field(changeset, :amount) do
      available = source.available_balance || source.current_balance || Decimal.new("0")

      if Decimal.cmp(available, amount) in [:lt] do
        add_error(changeset, :amount, "exceeds available balance")
      else
        changeset
      end
    else
      _ -> changeset
    end
  end

  defp maybe_put_action(changeset, nil), do: changeset
  defp maybe_put_action(changeset, action), do: Map.put(changeset, :action, action)

  defp fetch_source_account(changeset, accounts) do
    find_account(accounts, get_field(changeset, :source_account_id))
  end

  defp fetch_destination_account(changeset, accounts) do
    find_account(accounts, get_field(changeset, :destination_account_id))
  end

  defp find_account(accounts, nil), do: nil

  defp find_account(accounts, id) do
    Enum.find(accounts, fn
      %Account{id: account_id} -> account_id == id
      _ -> false
    end)
  end
end
