defmodule MoneyTree.Mortgages.Mortgage do
  @moduledoc """
  Persisted user mortgage baseline used by Mortgage Center.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Decimal
  alias MoneyTree.Obligations.Obligation
  alias MoneyTree.Users.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @statuses ~w(active paid_off inactive archived)

  schema "mortgages" do
    field :nickname, :string
    field :property_name, :string
    field :street_line_1, :string
    field :street_line_2, :string
    field :city, :string
    field :state_region, :string
    field :postal_code, :string
    field :country_code, :string, default: "US"
    field :occupancy_type, :string
    field :loan_type, :string
    field :servicer_name, :string
    field :lender_name, :string
    field :original_loan_amount, :decimal
    field :current_balance, :decimal
    field :original_interest_rate, :decimal
    field :current_interest_rate, :decimal
    field :original_term_months, :integer
    field :remaining_term_months, :integer
    field :monthly_principal_interest, :decimal
    field :monthly_payment_total, :decimal
    field :home_value_estimate, :decimal
    field :pmi_mip_monthly, :decimal
    field :hoa_monthly, :decimal
    field :flood_insurance_monthly, :decimal
    field :has_escrow, :boolean, default: false
    field :escrow_included_in_payment, :boolean, default: false
    field :status, :string, default: "active"
    field :source, :string
    field :last_reviewed_at, :utc_datetime_usec

    belongs_to :user, User
    belongs_to :linked_obligation, Obligation
    has_one :escrow_profile, MoneyTree.Mortgages.EscrowProfile

    timestamps()
  end

  @doc false
  def changeset(mortgage, attrs) do
    mortgage
    |> cast(attrs, [
      :user_id,
      :nickname,
      :property_name,
      :street_line_1,
      :street_line_2,
      :city,
      :state_region,
      :postal_code,
      :country_code,
      :occupancy_type,
      :loan_type,
      :servicer_name,
      :lender_name,
      :original_loan_amount,
      :current_balance,
      :original_interest_rate,
      :current_interest_rate,
      :original_term_months,
      :remaining_term_months,
      :monthly_principal_interest,
      :monthly_payment_total,
      :home_value_estimate,
      :pmi_mip_monthly,
      :hoa_monthly,
      :flood_insurance_monthly,
      :has_escrow,
      :escrow_included_in_payment,
      :linked_obligation_id,
      :status,
      :source,
      :last_reviewed_at
    ])
    |> validate_required([
      :user_id,
      :property_name,
      :loan_type,
      :current_balance,
      :current_interest_rate,
      :remaining_term_months,
      :monthly_payment_total,
      :status
    ])
    |> update_change(:country_code, &normalize_country_code/1)
    |> update_change(:status, &normalize_status/1)
    |> validate_length(:property_name, min: 1, max: 160)
    |> validate_length(:nickname, max: 120)
    |> validate_length(:street_line_1, max: 255)
    |> validate_length(:street_line_2, max: 255)
    |> validate_length(:city, max: 120)
    |> validate_length(:state_region, max: 120)
    |> validate_length(:postal_code, max: 20)
    |> validate_length(:country_code, is: 2)
    |> validate_length(:occupancy_type, max: 120)
    |> validate_length(:loan_type, max: 120)
    |> validate_length(:servicer_name, max: 160)
    |> validate_length(:lender_name, max: 160)
    |> validate_length(:source, max: 120)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:original_term_months, greater_than: 0)
    |> validate_number(:remaining_term_months, greater_than: 0)
    |> validate_non_negative_decimal(:original_loan_amount)
    |> validate_non_negative_decimal(:current_balance)
    |> validate_non_negative_decimal(:original_interest_rate)
    |> validate_non_negative_decimal(:current_interest_rate)
    |> validate_non_negative_decimal(:monthly_principal_interest)
    |> validate_non_negative_decimal(:monthly_payment_total)
    |> validate_non_negative_decimal(:home_value_estimate)
    |> validate_non_negative_decimal(:pmi_mip_monthly)
    |> validate_non_negative_decimal(:hoa_monthly)
    |> validate_non_negative_decimal(:flood_insurance_monthly)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:linked_obligation_id)
  end

  def statuses, do: @statuses

  defp normalize_country_code(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.upcase()
  end

  defp normalize_country_code(value), do: value

  defp normalize_status(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_status(value), do: value

  defp validate_non_negative_decimal(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case cast_decimal(value) do
        {:ok, decimal} ->
          if Decimal.compare(decimal, Decimal.new("0")) == :lt do
            [{field, "must be greater than or equal to 0"}]
          else
            []
          end

        :error ->
          [{field, "must be a valid decimal number"}]
      end
    end)
  end

  defp cast_decimal(nil), do: {:ok, nil}
  defp cast_decimal(%Decimal{} = decimal), do: {:ok, decimal}

  defp cast_decimal(value) when is_binary(value) or is_number(value) do
    Decimal.cast(value)
  end

  defp cast_decimal(_value), do: :error
end
