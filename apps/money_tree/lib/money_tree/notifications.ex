defmodule MoneyTree.Notifications do
  @moduledoc """
  Lightweight notification rules surfaced on the user dashboard.
  """

  alias Decimal
  alias MoneyTree.Accounts
  alias MoneyTree.Budgets
  alias MoneyTree.Loans
  alias MoneyTree.Recurring
  alias MoneyTree.Subscriptions
  alias MoneyTree.Users.User

  @type notification :: %{
          id: String.t(),
          severity: :info | :warning | :critical,
          message: String.t(),
          action: String.t() | nil
        }

  @doc """
  Computes pending notification items for the given user.
  """
  @spec pending(User.t() | binary(), keyword()) :: [notification()]
  def pending(user, opts \\ []) do
    card_balances = Accounts.running_card_balances(user, opts)
    budgets = Budgets.aggregate_totals(user, opts)
    loans = Loans.overview(user, opts)
    subscription = Subscriptions.spend_summary(user, opts)
    recurring_anomalies = Recurring.list_open_anomalies(resolve_user_id(user))

    []
    |> add_utilization_alerts(card_balances)
    |> add_budget_alerts(budgets)
    |> add_autopay_alerts(loans)
    |> add_subscription_digest(subscription)
    |> add_recurring_anomalies(recurring_anomalies)
    |> ensure_fallback()
  end

  defp add_utilization_alerts(notifications, card_balances) do
    Enum.reduce(card_balances, notifications, fn balance, acc ->
      utilization = Map.get(balance, :utilization_percent)

      identifier =
        balance.account.id ||
          balance.account.name ||
          "card"

      cond do
        is_nil(utilization) ->
          acc

        Decimal.compare(utilization, Decimal.new("95")) == :gt ->
          [
            %{
              id: "utilization-critical-" <> to_string(identifier),
              severity: :critical,
              message: "#{balance.account.name} utilisation is above 95%.",
              action: "Review spending"
            }
            | acc
          ]

        Decimal.compare(utilization, Decimal.new("80")) == :gt ->
          [
            %{
              id: "utilization-" <> to_string(identifier),
              severity: :warning,
              message:
                "#{balance.account.name} utilisation is above 80%. Consider a payment soon.",
              action: "Make a payment"
            }
            | acc
          ]

        true ->
          acc
      end
    end)
  end

  defp add_budget_alerts(notifications, budgets) do
    Enum.reduce(budgets, notifications, fn budget, acc ->
      case budget.status do
        :over ->
          [
            %{
              id: "budget-over-" <> budget.name,
              severity: :warning,
              message: "#{budget.name} budget exceeded for this #{budget.period}.",
              action: "Adjust spending"
            }
            | acc
          ]

        :approaching ->
          [
            %{
              id: "budget-approaching-" <> budget.name,
              severity: :info,
              message: "#{budget.name} budget is nearing its limit.",
              action: nil
            }
            | acc
          ]

        _ ->
          acc
      end
    end)
  end

  defp add_autopay_alerts(notifications, loans) do
    Enum.reduce(loans, notifications, fn loan, acc ->
      autopay = loan.autopay

      identifier = loan.account.id || loan.account.name || "loan"

      if autopay.enabled? do
        acc
      else
        [
          %{
            id: "loan-autopay-" <> to_string(identifier),
            severity: :warning,
            message: "Autopay is disabled for #{loan.account.name}.",
            action: "Enable autopay"
          }
          | acc
        ]
      end
    end)
  end

  defp add_subscription_digest(notifications, %{monthly_total_decimal: total} = summary) do
    if Decimal.compare(total, Decimal.new("0")) == :gt do
      [
        %{
          id: "subscription-digest",
          severity: :info,
          message:
            "Subscription spend this month: #{summary.monthly_total} (annualised #{summary.annual_projection}).",
          action: nil
        }
        | notifications
      ]
    else
      notifications
    end
  end

  defp add_subscription_digest(notifications, _summary), do: notifications


  defp add_recurring_anomalies(notifications, anomalies) do
    Enum.reduce(anomalies, notifications, fn anomaly, acc ->
      severity =
        case anomaly.severity do
          "critical" -> :critical
          "warning" -> :warning
          _ -> :info
        end

      [
        %{
          id: "recurring-#{anomaly.id}",
          severity: severity,
          message: recurring_message(anomaly),
          action: "Review recurring spend"
        }
        | acc
      ]
    end)
  end

  defp recurring_message(%{anomaly_type: "missing_cycle", series: series}) do
    "Expected recurring transaction is missing for #{series.fingerprint}."
  end

  defp recurring_message(%{anomaly_type: "late_cycle", series: series}) do
    "Recurring transaction appears late for #{series.fingerprint}."
  end

  defp recurring_message(%{anomaly_type: "unusual_amount", series: series}) do
    "Recurring transaction amount is unusual for #{series.fingerprint}."
  end

  defp recurring_message(_), do: "Recurring transaction anomaly detected."

  defp resolve_user_id(%{id: id}) when is_binary(id), do: id
  defp resolve_user_id(user_id) when is_binary(user_id), do: user_id

  defp ensure_fallback([]),
    do: [%{id: "all-clear", severity: :info, message: "You're all caught up!", action: nil}]

  defp ensure_fallback(notifications), do: Enum.reverse(notifications)
end
