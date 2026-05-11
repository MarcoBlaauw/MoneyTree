defmodule MoneyTree.Repo.Migrations.CreateLoanFeeSubsystem do
  use Ecto.Migration

  def change do
    create table(:loan_fee_types, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :loan_type, :string, null: false
      add :transaction_type, :string, null: false
      add :code, :string, null: false
      add :display_name, :string, null: false
      add :description, :text
      add :aliases, {:array, :string}, null: false, default: []
      add :trid_section, :string, null: false, default: "not_applicable"
      add :tolerance_bucket, :string, null: false, default: "unknown"
      add :finance_charge_treatment, :string, null: false, default: "unknown"
      add :apr_affecting, :boolean, null: false, default: false
      add :points_and_fees_included, :boolean, null: false, default: false
      add :high_cost_included, :boolean, null: false, default: false
      add :is_true_cost, :boolean, null: false, default: true
      add :is_timing_cost, :boolean, null: false, default: false
      add :is_offset, :boolean, null: false, default: false
      add :is_required, :boolean, null: false, default: false
      add :is_optional, :boolean, null: false, default: false
      add :is_shoppable, :boolean, null: false, default: false
      add :is_lender_controlled, :boolean, null: false, default: false
      add :is_third_party, :boolean, null: false, default: false
      add :is_government_fee, :boolean, null: false, default: false
      add :is_state_localized, :boolean, null: false, default: false
      add :requires_local_verification, :boolean, null: false, default: false
      add :credit_score_sensitive, :boolean, null: false, default: false
      add :amount_calculation_method, :string, null: false
      add :fixed_low_amount, :decimal, precision: 18, scale: 2
      add :fixed_expected_amount, :decimal, precision: 18, scale: 2
      add :fixed_high_amount, :decimal, precision: 18, scale: 2
      add :percent_low, :decimal, precision: 9, scale: 6
      add :percent_expected, :decimal, precision: 9, scale: 6
      add :percent_high, :decimal, precision: 9, scale: 6
      add :minimum_amount, :decimal, precision: 18, scale: 2
      add :maximum_amount, :decimal, precision: 18, scale: 2
      add :warning_low_threshold_amount, :decimal, precision: 18, scale: 2
      add :warning_high_threshold_amount, :decimal, precision: 18, scale: 2
      add :extreme_high_threshold_amount, :decimal, precision: 18, scale: 2
      add :warning_low_threshold_percent, :decimal, precision: 9, scale: 6
      add :warning_high_threshold_percent, :decimal, precision: 9, scale: 6
      add :extreme_high_threshold_percent, :decimal, precision: 9, scale: 6
      add :confidence_level, :string, null: false, default: "low"
      add :source_label, :string
      add :source_url, :string
      add :last_verified_at, :utc_datetime_usec
      add :enabled, :boolean, null: false, default: true
      add :sort_order, :integer, null: false, default: 0
      add :notes, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:loan_fee_types, [:loan_type, :transaction_type, :code])
    create index(:loan_fee_types, [:loan_type, :transaction_type, :enabled])

    create table(:loan_fee_jurisdiction_profiles, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :country_code, :string, null: false, size: 2
      add :state_code, :string
      add :county_or_parish, :string
      add :municipality, :string
      add :loan_type, :string, null: false
      add :transaction_type, :string, null: false
      add :confidence_level, :string, null: false, default: "low"
      add :confidence_score, :decimal, precision: 5, scale: 4
      add :source_label, :string
      add :source_url, :string
      add :last_verified_at, :utc_datetime_usec
      add :notes, :text
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create index(:loan_fee_jurisdiction_profiles, [:loan_type, :transaction_type, :enabled])
    create index(:loan_fee_jurisdiction_profiles, [:country_code, :state_code, :county_or_parish])

    create table(:loan_fee_jurisdiction_rules, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :jurisdiction_profile_id,
          references(:loan_fee_jurisdiction_profiles, type: :binary_id, on_delete: :delete_all),
          null: false

      add :loan_fee_type_id,
          references(:loan_fee_types, type: :binary_id, on_delete: :delete_all),
          null: false

      add :amount_calculation_method, :string
      add :fixed_low_amount, :decimal, precision: 18, scale: 2
      add :fixed_expected_amount, :decimal, precision: 18, scale: 2
      add :fixed_high_amount, :decimal, precision: 18, scale: 2
      add :percent_low, :decimal, precision: 9, scale: 6
      add :percent_expected, :decimal, precision: 9, scale: 6
      add :percent_high, :decimal, precision: 9, scale: 6
      add :minimum_amount, :decimal, precision: 18, scale: 2
      add :maximum_amount, :decimal, precision: 18, scale: 2
      add :requires_local_verification, :boolean
      add :source_label, :string
      add :source_url, :string
      add :last_verified_at, :utc_datetime_usec
      add :notes, :text
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:loan_fee_jurisdiction_rules, [
             :jurisdiction_profile_id,
             :loan_fee_type_id
           ])

    create index(:loan_fee_jurisdiction_rules, [:loan_fee_type_id])

    create table(:loan_lender_quote_fee_lines, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :lender_quote_id,
          references(:loan_lender_quotes, type: :binary_id, on_delete: :delete_all),
          null: false

      add :loan_fee_type_id,
          references(:loan_fee_types, type: :binary_id, on_delete: :nilify_all)

      add :original_label, :string, null: false
      add :normalized_label, :string
      add :amount, :decimal, precision: 18, scale: 2, null: false
      add :classification, :string, null: false, default: "unknown_fee_type"
      add :confidence_level, :string, null: false, default: "low"
      add :confidence_score, :decimal, precision: 5, scale: 4
      add :required, :boolean, null: false, default: false
      add :requires_review, :boolean, null: false, default: true
      add :review_note, :text
      add :raw_payload, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:loan_lender_quote_fee_lines, [:lender_quote_id])
    create index(:loan_lender_quote_fee_lines, [:loan_fee_type_id])
    create index(:loan_lender_quote_fee_lines, [:classification])
  end
end
