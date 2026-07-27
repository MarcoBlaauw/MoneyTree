defmodule MoneyTree.ManualImports.XLSXParserTest do
  use ExUnit.Case, async: true

  alias MoneyTree.ManualImports.XLSXParser
  alias MoneyTree.XLSXFixture

  test "parses a well-formed workbook" do
    binary = XLSXFixture.simple_workbook_binary([["Date", "Amount"], ["2026-01-01", 42]])

    assert {:ok, rows} = XLSXParser.rows(binary)
    assert ["Date", "Amount"] = Enum.at(rows, 0)
  end

  test "rejects an archive with an excessive number of internal entries" do
    entries =
      1..500
      |> Enum.map(fn i -> {String.to_charlist("file#{i}.xml"), "<x/>"} end)

    {:ok, {_name, binary}} = :zip.create(~c"bomb.xlsx", entries, [:memory])

    assert {:error, message} = XLSXParser.rows(binary)
    assert message =~ "too many internal entries"
  end
end
