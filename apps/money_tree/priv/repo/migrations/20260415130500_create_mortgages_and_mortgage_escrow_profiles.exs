defmodule MoneyTree.Repo.Migrations.CreateMortgagesAndMortgageEscrowProfiles do
  use Ecto.Migration

  def change do
    create table(:mortgages, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :nickname, :string
      add :property_name, :string
      add :street_line_1, :string
      add :street_line_2, :string
      add :city, :string
      add :state_region, :string
      add :postal_code, :string
      add :country_code, :string, size: 2
      add :occupancy_type, :string
      add :loan_type, :string
      add :servicer_name, :string
      add :lender_name, :string
      add :original_loan_amount, :decimal, precision: 18, scale: 2
      add :current_balance, :decimal, precision: 18, scale: 2
      add :original_interest_rate, :decimal, precision: 9, scale: 6
      add :current_interest_rate, :decimal, precision: 9, scale: 6
      add :original_term_months, :integer
      add :remaining_term_months, :integer
      add :monthly_principal_interest, :decimal, precision: 18, scale: 2
      add :monthly_payment_total, :decimal, precision: 18, scale: 2
      add :home_value_estimate, :decimal, precision: 18, scale: 2
      add :pmi_mip_monthly, :decimal, precision: 18, scale: 2
      add :hoa_monthly, :decimal, precision: 18, scale: 2
      add :flood_insurance_monthly, :decimal, precision: 18, scale: 2
      add :has_escrow, :boolean, null: false, default: false
      add :escrow_included_in_payment, :boolean, null: false, default: false

      add :linked_obligation_id,
          references(:obligations, type: :binary_id, on_delete: :nilify_all)

      add :status, :string, null: false, default: "active"
      add :source, :string
      add :last_reviewed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:mortgages, [:user_id])
    create index(:mortgages, [:linked_obligation_id])
    create index(:mortgages, [:status])

    create table(:mortgage_escrow_profiles, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :mortgage_id,
          references(:mortgages, type: :binary_id, on_delete: :delete_all),
          null: false

      add :property_tax_monthly, :decimal, precision: 18, scale: 2
      add :homeowners_insurance_monthly, :decimal, precision: 18, scale: 2
      add :flood_insurance_monthly, :decimal, precision: 18, scale: 2
      add :other_escrow_monthly, :decimal, precision: 18, scale: 2
      add :escrow_cushion_months, :decimal, precision: 9, scale: 4
      add :expected_old_escrow_refund, :decimal, precision: 18, scale: 2
      add :annual_tax_growth_rate, :decimal, precision: 9, scale: 6
      add :annual_insurance_growth_rate, :decimal, precision: 9, scale: 6
      add :source, :string
      add :confidence_score, :decimal, precision: 5, scale: 4

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:mortgage_escrow_profiles, [:mortgage_id])
  end
end
