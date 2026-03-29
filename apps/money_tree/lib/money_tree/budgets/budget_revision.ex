defmodule MoneyTree.Budgets.BudgetRevision do
  @moduledoc """
  Captures user decisions around planner suggestions as an immutable audit trail.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias MoneyTree.Budgets.Budget
  alias MoneyTree.Users.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @statuses ~w(accepted rejected)a

  schema "budget_revisions" do
    field :status, Ecto.Enum, values: @statuses
    field :previous_allocation_amount, :decimal
    field :suggested_allocation_amount, :decimal
    field :explanation, :string

    belongs_to :budget, Budget
    belongs_to :user, User

    timestamps(updated_at: false)
  end

  @doc false
  def changeset(revision, attrs) do
    revision
    |> cast(attrs, [
      :status,
      :previous_allocation_amount,
      :suggested_allocation_amount,
      :explanation,
      :budget_id,
      :user_id
    ])
    |> validate_required([:status, :budget_id, :user_id])
    |> validate_length(:explanation, max: 500)
    |> foreign_key_constraint(:budget_id)
    |> foreign_key_constraint(:user_id)
  end
end
