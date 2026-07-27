defmodule MoneyTree.Repo.Migrations.CreateVehicleAssetFoundation do
  use Ecto.Migration

  def up do
    alter table(:assets) do
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)
      add :linked_loan_id, references(:loans, type: :binary_id, on_delete: :nilify_all)
      add :linked_mortgage_id, references(:mortgages, type: :binary_id, on_delete: :nilify_all)
      add :acquisition_cost, :decimal, precision: 18, scale: 2
    end

    execute("""
    UPDATE assets
    SET user_id = accounts.user_id
    FROM accounts
    WHERE assets.account_id = accounts.id
    """)

    alter table(:assets) do
      modify :user_id, :binary_id, null: false

      modify :account_id,
             references(:accounts, type: :binary_id, on_delete: :nilify_all),
             from: references(:accounts, type: :binary_id, on_delete: :delete_all),
             null: true
    end

    create index(:assets, [:user_id])
    create index(:assets, [:linked_loan_id])
    create index(:assets, [:linked_mortgage_id])

    create table(:vehicle_profiles, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :asset_id, references(:assets, type: :binary_id, on_delete: :delete_all), null: false
      add :encrypted_vin, :binary
      add :year, :integer
      add :make, :string
      add :model, :string
      add :trim, :string
      add :body_style, :string
      add :mileage, :integer
      add :mileage_as_of, :date
      add :condition, :string
      add :market_region, :string
      add :encrypted_license_plate, :binary
      add :license_plate_state, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:vehicle_profiles, [:asset_id])

    create table(:asset_valuations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :asset_id, references(:assets, type: :binary_id, on_delete: :delete_all), null: false
      add :amount, :decimal, precision: 18, scale: 2, null: false
      add :currency, :string, size: 3, null: false
      add :source, :string, null: false
      add :provider_key, :string
      add :valued_on, :date, null: false
      add :confidence, :string
      add :manually_overridden, :boolean, null: false, default: false
      add :mileage, :integer
      add :value_low, :decimal, precision: 18, scale: 2
      add :value_high, :decimal, precision: 18, scale: 2
      add :raw_response, :map

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:asset_valuations, [:asset_id, "valued_on DESC", "inserted_at DESC"],
             name: :asset_valuations_asset_latest_index
           )

    execute("""
    INSERT INTO asset_valuations (
      id,
      asset_id,
      amount,
      currency,
      source,
      valued_on,
      manually_overridden,
      inserted_at
    )
    SELECT
      gen_random_uuid(),
      id,
      valuation_amount,
      valuation_currency,
      'manual',
      COALESCE(last_valued_on, inserted_at::date),
      false,
      inserted_at
    FROM assets
    WHERE valuation_amount IS NOT NULL
    """)
  end

  def down do
    drop table(:asset_valuations)
    drop table(:vehicle_profiles)

    drop index(:assets, [:linked_mortgage_id])
    drop index(:assets, [:linked_loan_id])
    drop index(:assets, [:user_id])

    execute("""
    UPDATE assets
    SET account_id = accounts.id
    FROM accounts
    WHERE assets.account_id IS NULL
      AND accounts.user_id = assets.user_id
      AND accounts.id = (
        SELECT account.id
        FROM accounts AS account
        WHERE account.user_id = assets.user_id
        ORDER BY account.inserted_at
        LIMIT 1
      )
    """)

    execute("""
    DELETE FROM assets
    WHERE account_id IS NULL
    """)

    alter table(:assets) do
      modify :account_id,
             references(:accounts, type: :binary_id, on_delete: :delete_all),
             from: references(:accounts, type: :binary_id, on_delete: :nilify_all),
             null: false

      remove :acquisition_cost
      remove :linked_mortgage_id
      remove :linked_loan_id
      remove :user_id
    end
  end
end
