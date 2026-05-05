defmodule MoneyTree.ManualImports.ImportParser do
  @moduledoc """
  Detects supported import file formats and returns parsed staged rows.
  """

  alias MoneyTree.ManualImports.CSVParser
  alias MoneyTree.ManualImports.XLSXParser

  @xlsx_mime "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

  @type parse_result :: {:ok, %{rows: [map()], headers: [String.t()]}} | {:error, String.t()}
  @type headers_result :: {:ok, [String.t()]} | {:error, String.t()}

  @spec parse(binary(), map(), keyword()) :: parse_result()
  def parse(content, mapping_config \\ %{}, opts \\ [])
      when is_binary(content) and is_map(mapping_config) and is_list(opts) do
    file_name = Keyword.get(opts, :file_name)
    file_mime_type = Keyword.get(opts, :file_mime_type)

    if xlsx_file?(file_name, file_mime_type) do
      parse_xlsx(content, mapping_config)
    else
      CSVParser.parse(content, mapping_config)
    end
  end

  @spec headers(binary(), keyword()) :: headers_result()
  def headers(content, opts \\ []) when is_binary(content) and is_list(opts) do
    file_name = Keyword.get(opts, :file_name)
    file_mime_type = Keyword.get(opts, :file_mime_type)

    if xlsx_file?(file_name, file_mime_type) do
      with {:ok, rows} <- XLSXParser.rows(content),
           detected_rows <- trim_to_detected_header_row(rows),
           [header_row | _] <- detected_rows do
        {:ok, normalize_headers(header_row)}
      else
        [] -> {:error, "xlsx worksheet is empty"}
        {:error, message} -> {:error, message}
      end
    else
      header =
        content
        |> String.split(~r/\r\n|\n|\r/)
        |> Enum.find("", fn line -> String.trim(line) != "" end)

      case header do
        "" ->
          {:error, "csv file is empty"}

        header_line ->
          headers =
            header_line
            |> String.split(",")
            |> normalize_headers()
            |> Enum.reject(&(&1 == ""))

          {:ok, headers}
      end
    end
  end

  defp parse_xlsx(content, mapping_config) do
    with {:ok, tabular_rows} <- XLSXParser.rows(content),
         detected_rows <- trim_to_detected_header_row(tabular_rows),
         csv <- tabular_rows_to_csv(detected_rows) do
      CSVParser.parse(csv, mapping_config)
    end
  end

  defp xlsx_file?(file_name, file_mime_type) do
    file_name_xlsx? =
      case file_name do
        name when is_binary(name) -> String.downcase(name) |> String.ends_with?(".xlsx")
        _ -> false
      end

    file_mime_type == @xlsx_mime or file_name_xlsx?
  end

  defp tabular_rows_to_csv(rows) do
    rows
    |> Enum.map(fn row -> row |> Enum.map(&csv_escape/1) |> Enum.join(",") end)
    |> Enum.join("\n")
  end

  defp trim_to_detected_header_row(rows) when is_list(rows) do
    normalized_rows =
      Enum.map(rows, fn row ->
        row
        |> Enum.map(&normalize_header_value/1)
        |> trim_trailing_empty_values()
      end)

    case detect_header_row_index(normalized_rows) do
      nil -> rows
      index when is_integer(index) and index > 0 -> Enum.drop(rows, index - 1)
      _ -> rows
    end
  end

  defp detect_header_row_index(rows) do
    header_tokens = [
      "date",
      "posted",
      "posting",
      "description",
      "memo",
      "details",
      "merchant",
      "payee",
      "amount",
      "debit",
      "credit",
      "status"
    ]

    rows
    |> Enum.with_index(1)
    |> Enum.find_value(fn {row, index} ->
      non_empty = Enum.reject(row, &(&1 == ""))

      score =
        Enum.count(non_empty, fn cell ->
          normalized = cell |> String.downcase() |> String.replace(~r/[^a-z0-9]+/u, " ")
          Enum.any?(header_tokens, &String.contains?(normalized, &1))
        end)

      cond do
        length(non_empty) < 2 ->
          false

        score >= 2 ->
          index

        score >= 1 and length(non_empty) >= 3 ->
          index

        true ->
          false
      end
    end) ||
      rows
      |> Enum.with_index(1)
      |> Enum.find_value(fn {row, index} ->
        if Enum.any?(row, &(&1 != "")), do: index, else: false
      end)
  end

  defp normalize_headers(values) when is_list(values) do
    Enum.map(values, &normalize_header_value/1)
  end

  defp normalize_header_value(value) do
    value
    |> to_string()
    |> String.replace_prefix("\uFEFF", "")
    |> replace_header_spaces()
    |> remove_zero_width_chars()
    |> String.trim()
  end

  defp trim_trailing_empty_values(values) do
    values
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 == ""))
    |> Enum.reverse()
  end

  defp replace_header_spaces(value) when is_binary(value) do
    value
    |> String.replace("\u00A0", " ")
    |> String.replace("\u2007", " ")
    |> String.replace("\u202F", " ")
  end

  defp remove_zero_width_chars(value) when is_binary(value) do
    value
    |> String.replace("\u200B", "")
    |> String.replace("\u200C", "")
    |> String.replace("\u200D", "")
    |> String.replace("\u2060", "")
  end

  defp csv_escape(value) when value in [nil, ""], do: ""

  defp csv_escape(value) do
    value = to_string(value)

    if String.contains?(value, [",", "\"", "\n", "\r"]) do
      "\"" <> String.replace(value, "\"", "\"\"") <> "\""
    else
      value
    end
  end
end
