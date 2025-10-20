defmodule MoneyTree.Loans do
  @moduledoc """
  Loan portfolio helpers used by the Phoenix LiveView dashboard.
  """

  alias Decimal
  alias MoneyTree.Accounts
  alias MoneyTree.Transactions
  alias MoneyTree.Users.User

  @type autopay_info :: %{
          enabled?: boolean(),
          cadence: :monthly,
          funding_account: String.t(),
          next_run_on: Date.t(),
          payment_amount: String.t(),
          payment_amount_masked: String.t()
        }

  @type loan_overview :: %{
          account: map(),
          current_balance: String.t(),
          current_balance_masked: String.t(),
          next_due_date: Date.t(),
          autopay: autopay_info(),
          last_payment: String.t(),
          last_payment_masked: String.t()
        }

  @doc """
  Returns human-friendly loan summaries, including autopay details.
  """
  @spec overview(User.t() | binary(), keyword()) :: [loan_overview()]
  def overview(user, opts \\ []) do
    lookback_days = Keyword.get(opts, :lookback_days, 45)
    funding_account = Keyword.get(opts, :default_funding_account, "Primary Checking")

    Accounts.list_accessible_accounts(user, preload: Keyword.get(opts, :preload, []))
    |> Enum.filter(&loan_account?/1)
    |> Enum.map(fn account ->
      balance_decimal = normalize_decimal(account.current_balance)
      currency = account.currency || "USD"

      autopay = autopay_details(account, funding_account, opts)
      next_due_date = autopay.next_run_on

      recent_activity = Transactions.net_activity_for_account(account, days: lookback_days)
      last_payment = Decimal.abs(recent_activity)

      %{
        account: %{
          id: account.id,
          name: account.name,
          currency: currency,
          type: account.type
        },
        current_balance: Accounts.format_money(balance_decimal, currency, opts),
        current_balance_masked: Accounts.mask_money(balance_decimal, currency, opts),
        next_due_date: next_due_date,
        autopay: autopay,
        last_payment: Accounts.format_money(last_payment, currency, opts),
        last_payment_masked: Accounts.mask_money(last_payment, currency, opts)
      }
    end)
  end

  defp autopay_details(account, funding_account, opts) do
    currency = account.currency || "USD"
    balance = normalize_decimal(account.current_balance)

    payment_amount =
      Keyword.get_lazy(opts, :payment_amount_fn, fn -> default_payment_amount(balance) end)
      |> apply_payment_amount(balance)

    next_run_on = compute_next_run(account, opts)
    enabled? = Decimal.compare(balance, Decimal.new("0")) == :gt

    %{
      enabled?: enabled?,
      cadence: :monthly,
      funding_account: Keyword.get(opts, :funding_account, funding_account),
      next_run_on: next_run_on,
      payment_amount: Accounts.format_money(payment_amount, currency, opts),
      payment_amount_masked: Accounts.mask_money(payment_amount, currency, opts)
    }
  end

  defp apply_payment_amount(fun, balance) when is_function(fun, 1), do: fun.(balance)
  defp apply_payment_amount(value, _balance), do: normalize_decimal(value)

  defp compute_next_run(account, opts) do
    base_date = Keyword.get(opts, :reference_date, Date.utc_today())
    cycle_day = Keyword.get(opts, :cycle_day, preferred_cycle_day(account))

    if cycle_day <= base_date.day do
      base_date
      |> Date.beginning_of_month()
      |> Date.add(32)
      |> Date.beginning_of_month()
      |> Date.add(cycle_day - 1)
    else
      base_date
      |> Date.beginning_of_month()
      |> Date.add(cycle_day - 1)
    end
  end

  defp preferred_cycle_day(account) do
    seed = account.id || account.external_id || account.name || "loan"
    rem(:erlang.phash2(seed), 27) + 1
  end

  defp default_payment_amount(balance) do
    balance
    |> Decimal.min(Decimal.new("750"))
    |> Decimal.max(Decimal.new("50"))
  end

  defp loan_account?(account) do
    type = account.type |> to_string() |> String.downcase()
    subtype = account.subtype |> to_string() |> String.downcase()

    String.contains?(type, "loan") or subtype in ["mortgage", "student", "auto", "loan"]
  end

  defp normalize_decimal(%Decimal{} = value), do: value

  defp normalize_decimal(value) do
    case Decimal.cast(value) do
      {:ok, decimal} -> decimal
      :error -> Decimal.new("0")
    end
  end
end
