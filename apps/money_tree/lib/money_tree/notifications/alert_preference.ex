defmodule MoneyTree.Notifications.AlertPreference do
  @moduledoc """
  User-level defaults for durable notification delivery and resend behavior.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias MoneyTree.Users.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "alert_preferences" do
    field :email_enabled, :boolean, default: true
    field :sms_enabled, :boolean, default: false
    field :push_enabled, :boolean, default: false
    field :dashboard_enabled, :boolean, default: true
    field :upcoming_enabled, :boolean, default: true
    field :due_today_enabled, :boolean, default: true
    field :overdue_enabled, :boolean, default: true
    field :recovered_enabled, :boolean, default: true
    field :upcoming_lead_days, :integer, default: 3
    field :resend_interval_hours, :integer, default: 24
    field :max_resends, :integer, default: 2

    belongs_to :user, User

    timestamps()
  end

  @doc false
  def changeset(preference, attrs) do
    preference
    |> cast(attrs, [
      :email_enabled,
      :sms_enabled,
      :push_enabled,
      :dashboard_enabled,
      :upcoming_enabled,
      :due_today_enabled,
      :overdue_enabled,
      :recovered_enabled,
      :upcoming_lead_days,
      :resend_interval_hours,
      :max_resends,
      :user_id
    ])
    |> validate_required([
      :email_enabled,
      :sms_enabled,
      :push_enabled,
      :dashboard_enabled,
      :upcoming_enabled,
      :due_today_enabled,
      :overdue_enabled,
      :recovered_enabled,
      :upcoming_lead_days,
      :resend_interval_hours,
      :max_resends,
      :user_id
    ])
    |> validate_number(:upcoming_lead_days,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 14
    )
    |> validate_number(:resend_interval_hours,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 168
    )
    |> validate_number(:max_resends, greater_than_or_equal_to: 0, less_than_or_equal_to: 10)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:user_id)
  end
end
