defmodule MoneyTree.Notifications.EmailAdapter do
  @moduledoc """
  Email delivery adapter for durable notification events.
  """

  @behaviour MoneyTree.Notifications.Adapter

  alias MoneyTree.Mailer
  alias MoneyTree.Notifications.Event
  alias MoneyTree.Users.User
  alias Swoosh.Email

  @impl true
  def channel, do: :email

  @impl true
  def deliver(%Event{} = event, %User{} = user, opts \\ []) do
    sender =
      Keyword.get(
        opts,
        :sender,
        Application.get_env(
          :money_tree,
          :notification_sender,
          {"MoneyTree", "no-reply@moneytree.app"}
        )
      )

    email =
      Email.new()
      |> Email.to(user.email)
      |> Email.from(sender)
      |> Email.subject(event.title)
      |> Email.text_body(email_body(event))
      |> Email.header("x-idempotency-key", Keyword.fetch!(opts, :idempotency_key))

    case Mailer.deliver(email) do
      {:ok, response} -> {:ok, %{provider_reference: inspect(response)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp email_body(%Event{} = event) do
    [event.message, event.action && "Next step: #{event.action}"]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end
end
