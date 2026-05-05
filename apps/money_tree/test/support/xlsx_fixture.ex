defmodule MoneyTree.XLSXFixture do
  @moduledoc false

  @spec simple_workbook_binary([[String.t() | number()]]) :: binary()
  def simple_workbook_binary(rows) when is_list(rows) do
    sheet_rows_xml =
      rows
      |> Enum.with_index(1)
      |> Enum.map(fn {row_values, row_index} ->
        cells_xml =
          row_values
          |> Enum.with_index(1)
          |> Enum.map(fn {value, column_index} ->
            reference = excel_reference(column_index, row_index)

            case value do
              number when is_integer(number) or is_float(number) ->
                ~s(<c r="#{reference}"><v>#{number}</v></c>)

              other ->
                escaped = xml_escape(to_string(other))
                ~s(<c r="#{reference}" t="inlineStr"><is><t>#{escaped}</t></is></c>)
            end
          end)
          |> Enum.join("")

        ~s(<row r="#{row_index}">#{cells_xml}</row>)
      end)
      |> Enum.join("")

    worksheet_xml = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
      <sheetData>#{sheet_rows_xml}</sheetData>
    </worksheet>
    """

    workbook_xml = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
      xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
      <sheets>
        <sheet name="Sheet1" sheetId="1" r:id="rId1"/>
      </sheets>
    </workbook>
    """

    workbook_rels_xml = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1"
        Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"
        Target="worksheets/sheet1.xml"/>
    </Relationships>
    """

    root_rels_xml = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1"
        Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"
        Target="xl/workbook.xml"/>
    </Relationships>
    """

    content_types_xml = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
      <Default Extension="xml" ContentType="application/xml"/>
      <Override PartName="/xl/workbook.xml"
        ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
      <Override PartName="/xl/worksheets/sheet1.xml"
        ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
    </Types>
    """

    entries = [
      {~c"[Content_Types].xml", content_types_xml},
      {~c"_rels/.rels", root_rels_xml},
      {~c"xl/workbook.xml", workbook_xml},
      {~c"xl/_rels/workbook.xml.rels", workbook_rels_xml},
      {~c"xl/worksheets/sheet1.xml", worksheet_xml}
    ]

    {:ok, {_name, binary}} = :zip.create(~c"fixture.xlsx", entries, [:memory])
    binary
  end

  defp excel_reference(column_index, row_index) do
    "#{excel_column(column_index)}#{row_index}"
  end

  defp excel_column(index) when index > 0 do
    do_excel_column(index, "")
  end

  defp do_excel_column(0, acc), do: acc

  defp do_excel_column(index, acc) do
    remainder = rem(index - 1, 26)
    character = <<?A + remainder>>
    do_excel_column(div(index - 1, 26), character <> acc)
  end

  defp xml_escape(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end
end
