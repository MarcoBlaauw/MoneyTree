defmodule MoneyTree.ManualImports.ImportParserTest do
  use ExUnit.Case, async: true

  alias MoneyTree.ManualImports.ImportParser
  alias MoneyTree.XLSXFixture

  test "parses xlsx content through csv mapping flow" do
    content =
      XLSXFixture.simple_workbook_binary([
        ["Date", "Description", "Amount", "Status"],
        ["2026-04-20", "Coffee", -5.25, "Posted"],
        ["2026-04-21", "Payroll", 2000.00, "Posted"]
      ])

    assert {:ok, %{rows: [expense, income], headers: ["Date", "Description", "Amount", "Status"]}} =
             ImportParser.parse(
               content,
               %{
                 "columns" => %{
                   "posted_at" => "Date",
                   "description" => "Description",
                   "amount" => "Amount",
                   "status" => "Status"
                 }
               },
               file_name: "sample.xlsx"
             )

    assert expense.direction == "expense"
    assert income.direction == "income"
    assert expense.description == "Coffee"
    assert income.description == "Payroll"
  end

  test "detects header row in xlsx with preface row and posting-date style headers" do
    content =
      XLSXFixture.simple_workbook_binary([
        ["Checking Account Export", "", "", ""],
        ["Posting Date", "Transaction Description", "Amount", "Status"],
        ["2026-04-20", "Coffee", -5.25, "Posted"]
      ])

    assert {:ok, headers} = ImportParser.headers(content, file_name: "bank-export.xlsx")
    assert headers == ["Posting Date", "Transaction Description", "Amount", "Status"]

    assert {:ok, %{rows: [expense]}} =
             ImportParser.parse(
               content,
               %{
                 "columns" => %{
                   "posted_at" => "Posting Date",
                   "description" => "Transaction Description",
                   "amount" => "Amount",
                   "status" => "Status"
                 }
               },
               file_name: "bank-export.xlsx"
             )

    assert expense.description == "Coffee"
    assert expense.direction == "expense"
  end
end
