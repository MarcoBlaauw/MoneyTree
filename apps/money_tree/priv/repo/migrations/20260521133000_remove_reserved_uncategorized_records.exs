defmodule MoneyTree.Repo.Migrations.RemoveReservedUncategorizedRecords do
  use Ecto.Migration

  def up do
    execute("""
    DELETE FROM user_categories
    WHERE lower(name) = 'uncategorized'
    """)

    execute("""
    DELETE FROM category_rules
    WHERE lower(category) = 'uncategorized'
    """)

    execute("""
    DELETE FROM user_category_overrides
    WHERE lower(category) = 'uncategorized'
    """)

    execute("""
    UPDATE transactions
    SET category = NULL,
        categorization_source = NULL,
        categorization_confidence = NULL,
        updated_at = now()
    WHERE lower(category) = 'uncategorized'
    """)
  end

  def down do
    :ok
  end
end
