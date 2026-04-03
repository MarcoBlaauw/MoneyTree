defmodule MoneyTreeWeb.AccountController do
  use MoneyTreeWeb, :controller

  alias MoneyTree.Accounts
  alias MoneyTree.Accounts.Account

  def index(%{assigns: %{current_user: current_user}} = conn, _params) do
    accounts =
      current_user
      |> Accounts.list_accessible_accounts(order_by: {:asc, :name})
      |> Enum.map(&serialize_account/1)

    json(conn, %{data: accounts})
  end

  defp serialize_account(%Account{} = account) do
    %{
      id: account.id,
      name: account.name,
      currency: account.currency,
      type: account.type,
      subtype: account.subtype
    }
  end
end
