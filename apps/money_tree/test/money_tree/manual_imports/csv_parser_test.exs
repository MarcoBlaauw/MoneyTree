defmodule MoneyTree.ManualImports.CSVParserTest do
  use ExUnit.Case, async: true

  alias MoneyTree.ManualImports.CSVParser

  test "parses signed amount csv with required mapping" do
    csv = """
    Date,Description,Amount
    2026-04-20,Coffee,-4.25
    04/21/2026,Payroll,2000.00
    """

    assert {:ok, %{rows: [expense, income], headers: ["Date", "Description", "Amount"]}} =
             CSVParser.parse(csv, %{
               "columns" => %{
                 "posted_at" => "Date",
                 "description" => "Description",
                 "amount" => "Amount"
               }
             })

    assert expense.parse_status == "parsed"
    assert expense.direction == "expense"
    assert income.direction == "income"
  end

  test "parses debit and credit columns into signed amount" do
    csv = """
    Date,Description,Debit,Credit
    2026-04-20,Groceries,120.35,
    2026-04-22,Refund,,19.99
    """

    assert {:ok, %{rows: [expense, income]}} =
             CSVParser.parse(csv, %{
               "columns" => %{
                 "posted_at" => "Date",
                 "description" => "Description",
                 "debit" => "Debit",
                 "credit" => "Credit"
               }
             })

    assert expense.direction == "expense"
    assert income.direction == "income"
  end

  test "returns error for missing required mapping" do
    assert {:error, "posted_at mapping is required"} =
             CSVParser.parse("Date,Description,Amount\n2026-04-20,Coffee,-5.00\n", %{
               "columns" => %{
                 "description" => "Description",
                 "amount" => "Amount"
               }
             })
  end
end
