defmodule MoneyTree.Repo.Migrations.AddEmojiToUserCategories do
  use Ecto.Migration

  def change do
    alter table(:user_categories) do
      add :emoji, :string, null: false, default: "🏷️"
    end
  end
end
