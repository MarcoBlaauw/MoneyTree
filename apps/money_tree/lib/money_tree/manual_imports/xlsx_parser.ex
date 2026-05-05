defmodule MoneyTree.ManualImports.XLSXParser do
  @moduledoc """
  Minimal XLSX parser for manual import staging.

  Extracts text/number values from the first worksheet and returns tabular rows.
  """

  @type parse_result :: {:ok, [[String.t()]]} | {:error, String.t()}

  @spec rows(binary()) :: parse_result()
  def rows(content) when is_binary(content) do
    with {:ok, files} <- unzip(content),
         {:ok, shared_strings} <- parse_shared_strings(files),
         {:ok, worksheet_xml} <- first_worksheet_xml(files),
         {:ok, rows} <- parse_rows(worksheet_xml, shared_strings) do
      {:ok, rows}
    end
  end

  defp unzip(content) do
    case :zip.unzip(content, [:memory]) do
      {:ok, files} ->
        normalized =
          Enum.map(files, fn {path, data} ->
            {path |> List.to_string(), data}
          end)

        {:ok, normalized}

      {:error, _reason} ->
        {:error, "xlsx file could not be read"}
    end
  end

  defp parse_shared_strings(files) do
    case Enum.find(files, fn {path, _data} -> path == "xl/sharedStrings.xml" end) do
      nil ->
        {:ok, []}

      {_path, xml} ->
        case parse_xml(xml) do
          {:ok, doc} ->
            strings =
              xpath(~c"//*[local-name()='si']", doc)
              |> Enum.map(fn si ->
                xpath(~c".//*[local-name()='t']/text()", si)
                |> text_nodes_to_string()
              end)

            {:ok, strings}

          {:error, _reason} ->
            {:ok, parse_shared_strings_fallback(xml)}
        end
    end
  end

  defp first_worksheet_xml(files) do
    worksheet_paths =
      files
      |> Enum.map(fn {path, _data} -> path end)
      |> Enum.filter(&String.starts_with?(&1, "xl/worksheets/sheet"))
      |> Enum.sort()

    case worksheet_paths do
      [first | _] ->
        case Enum.find(files, fn {path, _data} -> path == first end) do
          {_path, xml} -> {:ok, xml}
          nil -> {:error, "xlsx worksheet could not be loaded"}
        end

      [] ->
        {:error, "xlsx worksheet was not found"}
    end
  end

  defp parse_rows(worksheet_xml, shared_strings) do
    case parse_xml(worksheet_xml) do
      {:ok, doc} ->
        parsed_rows =
          xpath(~c"//*[local-name()='sheetData']/*[local-name()='row']", doc)
          |> Enum.map(fn row -> parse_row_cells(row, shared_strings) end)
          |> Enum.reject(&(&1 == []))

        if parsed_rows == [] do
          {:error, "xlsx worksheet is empty"}
        else
          {:ok, parsed_rows}
        end

      {:error, _reason} ->
        rows = parse_rows_fallback(worksheet_xml, shared_strings)

        if rows == [] do
          {:error, "xlsx worksheet is empty"}
        else
          {:ok, rows}
        end
    end
  end

  defp parse_row_cells(row_node, shared_strings) do
    cells =
      xpath(~c"./*[local-name()='c']", row_node)
      |> Enum.map(fn cell -> parse_cell(cell, shared_strings) end)

    max_column =
      cells
      |> Enum.map(& &1.column)
      |> Enum.max(fn -> 0 end)

    Enum.reduce(1..max_column, [], fn column, acc ->
      value =
        cells
        |> Enum.find(&(&1.column == column))
        |> case do
          nil -> ""
          cell -> cell.value
        end

      [value | acc]
    end)
    |> Enum.reverse()
    |> trim_trailing_empty_values()
  end

  defp parse_cell(cell_node, shared_strings) do
    reference = attribute_value(cell_node, :r)
    type = attribute_value(cell_node, :t)
    column = reference |> to_string_safe() |> reference_column_index()

    value =
      cond do
        type == "s" ->
          index =
            xpath(~c"./*[local-name()='v']/text()", cell_node)
            |> text_nodes_to_string()
            |> Integer.parse()
            |> case do
              {value, _rest} -> value
              :error -> -1
            end

          case Enum.at(shared_strings, index) do
            text when is_binary(text) -> text
            _ -> ""
          end

        type == "inlineStr" ->
          xpath(~c"./*[local-name()='is']//*[local-name()='t']/text()", cell_node)
          |> text_nodes_to_string()

        type == "b" ->
          case xpath(~c"./*[local-name()='v']/text()", cell_node) |> text_nodes_to_string() do
            "1" -> "true"
            "0" -> "false"
            other -> other
          end

        true ->
          xpath(~c"./*[local-name()='v']/text()", cell_node)
          |> text_nodes_to_string()
      end

    %{column: column, value: value}
  end

  defp parse_xml(content) do
    xml = content |> to_string_safe() |> String.to_charlist()

    try do
      {doc, _rest} = :xmerl_scan.string(xml, quiet: true)
      {:ok, doc}
    rescue
      _ -> {:error, "xlsx xml could not be parsed"}
    catch
      :exit, _reason -> {:error, "xlsx xml could not be parsed"}
      :throw, _reason -> {:error, "xlsx xml could not be parsed"}
    end
  end

  defp xpath(path, node) do
    :xmerl_xpath.string(path, node)
  rescue
    _ -> []
  end

  defp text_nodes_to_string(nodes) when is_list(nodes) do
    nodes
    |> Enum.map(fn
      {:xmlText, _parents, _pos, _language, value, _type} -> List.to_string(value)
      other -> to_string_safe(other)
    end)
    |> Enum.join("")
    |> String.trim()
    |> xml_unescape()
  end

  defp attribute_value(
         {:xmlElement, _n, _e, _ns, _namespace, _parents, _pos, attributes, _content, _, _, _},
         key
       )
       when is_atom(key) do
    attributes
    |> Enum.find(fn
      {:xmlAttribute, name, _, _, _, _, _, _, _, _} -> name == key
      _ -> false
    end)
    |> case do
      {:xmlAttribute, _name, _, _, _, _, _, _, value, _} -> List.to_string(value)
      _ -> nil
    end
  end

  defp attribute_value(_node, _key), do: nil

  defp reference_column_index(reference) when is_binary(reference) do
    letters = String.replace(reference, ~r/\d/, "")

    if letters == "" do
      1
    else
      letters
      |> String.upcase()
      |> String.to_charlist()
      |> Enum.reduce(0, fn char, acc ->
        acc * 26 + (char - ?A + 1)
      end)
    end
  end

  defp reference_column_index(_), do: 1

  defp trim_trailing_empty_values(values) do
    values
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 == ""))
    |> Enum.reverse()
  end

  defp xml_unescape(value) when is_binary(value) do
    value
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&#xA;", "\n")
    |> String.replace("&#xD;", "\r")
  end

  defp to_string_safe(value) when is_binary(value), do: value
  defp to_string_safe(value) when is_list(value), do: List.to_string(value)
  defp to_string_safe(value), do: to_string(value)

  defp parse_shared_strings_fallback(xml) do
    source = normalize_xml_source(xml)

    ~r/<(?:\w+:)?si\b[^>]*>(.*?)<\/(?:\w+:)?si>/s
    |> Regex.scan(source, capture: :all_but_first)
    |> Enum.map(fn [si_body] ->
      ~r/<(?:\w+:)?t\b[^>]*>(.*?)<\/(?:\w+:)?t>/s
      |> Regex.scan(si_body, capture: :all_but_first)
      |> Enum.map(fn [text] -> xml_unescape(String.trim(text)) end)
      |> Enum.join("")
    end)
  end

  defp parse_rows_fallback(xml, shared_strings) do
    source = normalize_xml_source(xml)

    ~r/<(?:\w+:)?row\b[^>]*>(.*?)<\/(?:\w+:)?row>/s
    |> Regex.scan(source, capture: :all_but_first)
    |> Enum.map(fn [row_body] ->
      parse_row_cells_fallback(row_body, shared_strings)
    end)
    |> Enum.reject(&(&1 == []))
  end

  defp parse_row_cells_fallback(row_body, shared_strings) do
    cells =
      ~r/<(?:\w+:)?c\b([^>]*)>(.*?)<\/(?:\w+:)?c>|<(?:\w+:)?c\b([^>]*)\/>/s
      |> Regex.scan(row_body)
      |> Enum.map(fn captures ->
        parse_cell_fallback(captures, shared_strings)
      end)

    max_column =
      cells
      |> Enum.map(& &1.column)
      |> Enum.max(fn -> 0 end)

    Enum.reduce(1..max_column, [], fn column, acc ->
      value =
        cells
        |> Enum.find(&(&1.column == column))
        |> case do
          nil -> ""
          cell -> cell.value
        end

      [value | acc]
    end)
    |> Enum.reverse()
    |> trim_trailing_empty_values()
  end

  defp parse_cell_fallback([_whole, attrs1, body, attrs2], shared_strings) do
    attrs = attrs1 || attrs2 || ""
    reference = attr_value(attrs, "r")
    type = attr_value(attrs, "t")
    column = reference |> to_string_safe() |> reference_column_index()

    value =
      cond do
        type == "s" ->
          index =
            ~r/<(?:\w+:)?v>(.*?)<\/(?:\w+:)?v>/s
            |> Regex.run(body || "", capture: :all_but_first)
            |> case do
              [raw] ->
                raw
                |> String.trim()
                |> Integer.parse()
                |> case do
                  {value, _rest} -> value
                  :error -> -1
                end

              _ ->
                -1
            end

          case Enum.at(shared_strings, index) do
            text when is_binary(text) -> text
            _ -> ""
          end

        type == "inlineStr" ->
          ~r/<(?:\w+:)?t\b[^>]*>(.*?)<\/(?:\w+:)?t>/s
          |> Regex.scan(body || "", capture: :all_but_first)
          |> Enum.map(fn [text] -> xml_unescape(String.trim(text)) end)
          |> Enum.join("")

        true ->
          ~r/<(?:\w+:)?v>(.*?)<\/(?:\w+:)?v>/s
          |> Regex.run(body || "", capture: :all_but_first)
          |> case do
            [raw] -> xml_unescape(String.trim(raw))
            _ -> ""
          end
      end

    %{column: column, value: value}
  end

  defp parse_cell_fallback(_captures, _shared_strings), do: %{column: 1, value: ""}

  defp normalize_xml_source(xml) do
    source = to_string_safe(xml)

    if String.valid?(source) do
      source
    else
      :unicode.characters_to_binary(source, :latin1, :utf8)
    end
  end

  defp attr_value(attrs, name) when is_binary(attrs) and is_binary(name) do
    pattern = ~r/\b#{Regex.escape(name)}="([^"]*)"/

    case Regex.run(pattern, attrs, capture: :all_but_first) do
      [value] -> value
      _ -> nil
    end
  end
end
