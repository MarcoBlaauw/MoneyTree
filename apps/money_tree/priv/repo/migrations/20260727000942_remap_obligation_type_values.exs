defmodule MoneyTree.Repo.Migrations.RemapObligationTypeValues do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE obligations
    SET obligation_type = CASE obligation_type
      WHEN 'bill' THEN 'other'
      WHEN 'recurring_payment' THEN 'other'
      WHEN 'loan_payment' THEN 'debt_payment'
      WHEN 'credit_card_payment' THEN 'debt_payment'
      ELSE obligation_type
    END
    """)

    execute("ALTER TABLE obligations ALTER COLUMN obligation_type SET DEFAULT 'other'")
  end

  def down do
    execute("ALTER TABLE obligations ALTER COLUMN obligation_type SET DEFAULT 'bill'")
  end
end
