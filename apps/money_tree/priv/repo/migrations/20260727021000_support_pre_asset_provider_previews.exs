defmodule MoneyTree.Repo.Migrations.SupportPreAssetProviderPreviews do
  use Ecto.Migration

  def change do
    alter table(:valuation_provider_runs) do
      modify :asset_id, :binary_id, null: true, from: {:binary_id, null: false}
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)
      add :request_kind, :string, null: false, default: "valuation"
      add :request_fingerprint, :string
      add :response_data, :map
    end

    create index(:valuation_provider_runs, [:user_id])

    create index(
             :valuation_provider_runs,
             [:user_id, :provider_key, :request_kind, :request_fingerprint, "requested_at DESC"],
             name: :valuation_provider_runs_preview_cache_index
           )

    create constraint(:valuation_provider_runs, :valuation_provider_runs_subject_required,
             check: "asset_id IS NOT NULL OR user_id IS NOT NULL"
           )
  end
end
