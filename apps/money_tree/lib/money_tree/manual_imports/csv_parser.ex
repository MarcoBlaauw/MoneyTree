defmodule MoneyTree.ManualImports.CSVParser do
  @moduledoc """
  Parses generic CSV files into staged manual import row attrs.
  """

  alias Decimal

  @supported_delimiters [",", ";", "\t", "|"]

  @type parse_result :: {:ok, %{rows: [map()], headers: [String.t()]}} | {:error, String.t()}

  @spec parse(binary(), map()) :: parse_result()
  def parse(content, mapping_config \\ %{}) when is_binary(content) and is_map(mapping_config) do
    normalized_content = strip_bom(content)
    delimiter = configured_delimiter(mapping_config, normalized_content)

    with {:ok, csv_rows} <- parse_csv_rows(normalized_content, delimiter),
         {:ok, headers, data_rows} <- split_header(csv_rows, mapping_config),
         {:ok, mapping} <- build_mapping(headers, mapping_config),
         {:ok, rows} <- build_rows(data_rows, headers, mapping) do
      {:ok, %{rows: rows, headers: headers}}
    end
  end

  defp split_header([], _mapping_config), do: {:error, "csv file is empty"}

  defp split_header(csv_rows, mapping_config) do
    header_row_index =
      mapping_config
      |> map_get("header_row_index")
      |> to_integer()
      |> case do
        nil -> 1
        value when value >= 1 -> value
        _ -> 1
      end

    case Enum.drop(csv_rows, header_row_index - 1) do
      [] ->
        {:error, "header row not found"}

      [header_row | data_rows] ->
        headers =
          header_row
          |> Enum.map(&String.trim/1)

        if Enum.any?(headers, &(&1 != "")) do
          {:ok, headers, data_rows}
        else
          {:error, "header row is empty"}
        end
    end
  end

  defp build_mapping(headers, mapping_config) do
    raw_mapping = map_get(mapping_config, "columns") || %{}

    amount_column = map_get(raw_mapping, "amount")
    debit_column = map_get(raw_mapping, "debit")
    credit_column = map_get(raw_mapping, "credit")

    cond do
      is_nil(resolve_header(headers, map_get(raw_mapping, "posted_at"))) ->
        {:error, "posted_at mapping is required"}

      is_nil(resolve_header(headers, map_get(raw_mapping, "description"))) ->
        {:error, "description mapping is required"}

      is_nil(resolve_header(headers, amount_column)) and
        is_nil(resolve_header(headers, debit_column)) and
          is_nil(resolve_header(headers, credit_column)) ->
        {:error, "amount mapping is required (amount or debit/credit)"}

      true ->
        {:ok,
         %{
           posted_at: resolve_header(headers, map_get(raw_mapping, "posted_at")),
           description: resolve_header(headers, map_get(raw_mapping, "description")),
           original_description:
             resolve_header(headers, map_get(raw_mapping, "original_description")),
           merchant_name: resolve_header(headers, map_get(raw_mapping, "merchant_name")),
           amount: resolve_header(headers, amount_column),
           debit: resolve_header(headers, debit_column),
           credit: resolve_header(headers, credit_column),
           currency: resolve_header(headers, map_get(raw_mapping, "currency")),
           external_transaction_id:
             resolve_header(headers, map_get(raw_mapping, "external_transaction_id")),
           source_reference: resolve_header(headers, map_get(raw_mapping, "source_reference")),
           check_number: resolve_header(headers, map_get(raw_mapping, "check_number")),
           category_name_snapshot:
             resolve_header(headers, map_get(raw_mapping, "category_name_snapshot")),
           status: resolve_header(headers, map_get(raw_mapping, "status"))
         }}
    end
  end

  defp build_rows(data_rows, headers, mapping) do
    rows =
      data_rows
      |> Enum.with_index(1)
      |> Enum.map(fn {values, index} ->
        build_row(values, index, headers, mapping)
      end)

    {:ok, rows}
  end

  defp build_row(values, index, headers, mapping) do
    value_map =
      headers
      |> Enum.zip(values)
      |> Enum.into(%{})

    parse_errors = %{}

    {posted_at, parse_errors} =
      parse_posted_at(map_get(value_map, mapping.posted_at), parse_errors)

    {amount, direction, parse_errors} =
      parse_amount(value_map, mapping, parse_errors)

    {parse_status, parse_errors} =
      parse_status(value_map, mapping, parse_errors)

    description =
      map_get(value_map, mapping.description)
      |> normalize_string()

    review_decision = if parse_status == "error", do: "needs_review", else: "accept"

    %{
      row_index: index,
      raw_row: value_map,
      parse_status: parse_status,
      parse_errors: parse_errors,
      posted_at: posted_at,
      description: description,
      original_description: normalize_string(map_get(value_map, mapping.original_description)),
      merchant_name: normalize_string(map_get(value_map, mapping.merchant_name)),
      amount: amount,
      currency: parse_currency(map_get(value_map, mapping.currency)),
      direction: direction,
      external_transaction_id:
        normalize_string(map_get(value_map, mapping.external_transaction_id)),
      source_reference: normalize_string(map_get(value_map, mapping.source_reference)),
      check_number: normalize_string(map_get(value_map, mapping.check_number)),
      category_name_snapshot:
        normalize_string(map_get(value_map, mapping.category_name_snapshot)),
      review_decision: review_decision
    }
  end

  defp parse_status(value_map, mapping, parse_errors) do
    case normalize_string(map_get(value_map, mapping.status)) do
      nil ->
        if map_size(parse_errors) > 0, do: {"error", parse_errors}, else: {"parsed", parse_errors}

      status_value ->
        if String.downcase(status_value) == "posted" do
          if map_size(parse_errors) > 0,
            do: {"error", parse_errors},
            else: {"parsed", parse_errors}
        else
          errors = Map.put(parse_errors, "status", "row status is #{status_value}")
          if map_size(parse_errors) > 0, do: {"error", errors}, else: {"warning", errors}
        end
    end
  end

  defp parse_posted_at(nil, parse_errors),
    do: {nil, Map.put(parse_errors, "posted_at", "missing posted_at")}

  defp parse_posted_at(value, parse_errors) do
    case parse_date(value) do
      {:ok, datetime} -> {datetime, parse_errors}
      {:error, _} -> {nil, Map.put(parse_errors, "posted_at", "invalid posted_at")}
    end
  end

  defp parse_amount(value_map, mapping, parse_errors) do
    amount_value = map_get(value_map, mapping.amount)
    debit_value = map_get(value_map, mapping.debit)
    credit_value = map_get(value_map, mapping.credit)

    cond do
      amount_value not in [nil, ""] ->
        case parse_decimal(amount_value) do
          {:ok, amount} ->
            {amount, infer_direction(amount), parse_errors}

          :error ->
            {nil, nil, Map.put(parse_errors, "amount", "invalid amount")}
        end

      debit_value not in [nil, ""] or credit_value not in [nil, ""] ->
        parse_split_amount(debit_value, credit_value, parse_errors)

      true ->
        {nil, nil, Map.put(parse_errors, "amount", "missing amount")}
    end
  end

  defp parse_split_amount(debit_value, credit_value, parse_errors) do
    with {:ok, debit} <- parse_optional_decimal(debit_value),
         {:ok, credit} <- parse_optional_decimal(credit_value) do
      cond do
        is_nil(debit) and is_nil(credit) ->
          {nil, nil, Map.put(parse_errors, "amount", "missing debit/credit")}

        not is_nil(debit) and not is_nil(credit) ->
          {nil, nil, Map.put(parse_errors, "amount", "both debit and credit provided")}

        not is_nil(debit) ->
          {Decimal.negate(debit), "expense", parse_errors}

        true ->
          {credit, "income", parse_errors}
      end
    else
      :error ->
        {nil, nil, Map.put(parse_errors, "amount", "invalid debit/credit")}
    end
  end

  defp parse_optional_decimal(value) when value in [nil, ""], do: {:ok, nil}

  defp parse_optional_decimal(value), do: parse_decimal(value)

  defp parse_decimal(value) do
    value
    |> normalize_number_string()
    |> Decimal.cast()
    |> case do
      {:ok, decimal} -> {:ok, decimal}
      :error -> :error
    end
  end

  defp parse_currency(nil), do: "USD"

  defp parse_currency(value) do
    value
    |> normalize_string()
    |> case do
      nil -> "USD"
      currency -> String.upcase(currency)
    end
  end

  defp parse_date(nil), do: {:error, :invalid}

  defp parse_date(value) do
    trimmed = String.trim(to_string(value))

    cond do
      trimmed == "" ->
        {:error, :invalid}

      String.match?(trimmed, ~r/^\d{4}-\d{1,2}-\d{1,2}$/) ->
        parse_date_with_format(trimmed, :iso_dash)

      String.match?(trimmed, ~r/^\d{4}\/\d{1,2}\/\d{1,2}$/) ->
        parse_date_with_format(trimmed, :iso_slash)

      String.match?(trimmed, ~r/^\d{1,2}\/\d{1,2}\/\d{2,4}$/) ->
        parse_date_with_format(trimmed, :us_slash)

      true ->
        {:error, :invalid}
    end
  end

  defp parse_date_with_format(value, :iso_dash) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, to_utc_datetime(date)}
      _ -> {:error, :invalid}
    end
  end

  defp parse_date_with_format(value, :iso_slash) do
    case String.split(value, "/", parts: 3) do
      [year, month, day] -> parse_ymd(year, month, day)
      _ -> {:error, :invalid}
    end
  end

  defp parse_date_with_format(value, :us_slash) do
    case String.split(value, "/", parts: 3) do
      [month, day, year] -> parse_mdy(month, day, year)
      _ -> {:error, :invalid}
    end
  end

  defp parse_ymd(year, month, day) do
    with {year_int, ""} <- Integer.parse(year),
         {month_int, ""} <- Integer.parse(month),
         {day_int, ""} <- Integer.parse(day),
         {:ok, date} <- Date.new(year_int, month_int, day_int) do
      {:ok, to_utc_datetime(date)}
    else
      _ -> {:error, :invalid}
    end
  end

  defp parse_mdy(month, day, year) do
    with {month_int, ""} <- Integer.parse(month),
         {day_int, ""} <- Integer.parse(day),
         {year_int, ""} <- parse_year(year),
         {:ok, date} <- Date.new(year_int, month_int, day_int) do
      {:ok, to_utc_datetime(date)}
    else
      _ -> {:error, :invalid}
    end
  end

  defp parse_year(value) do
    case Integer.parse(value) do
      {year, ""} when year >= 1000 -> {year, ""}
      {year, ""} when year >= 0 -> {2000 + year, ""}
      _ -> :error
    end
  end

  defp to_utc_datetime(date) do
    {:ok, datetime} = DateTime.new(date, ~T[00:00:00], "Etc/UTC")
    DateTime.truncate(datetime, :second)
  end

  defp infer_direction(decimal) do
    case Decimal.compare(decimal, Decimal.new("0")) do
      :lt -> "expense"
      :gt -> "income"
      :eq -> nil
    end
  end

  defp configured_delimiter(mapping_config, content) do
    configured = map_get(mapping_config, "delimiter")

    cond do
      is_binary(configured) and configured in @supported_delimiters ->
        configured

      true ->
        detect_delimiter(content)
    end
  end

  defp detect_delimiter(content) do
    first_line =
      content
      |> String.split(~r/\r\n|\n|\r/, parts: 2)
      |> List.first()
      |> to_string()

    Enum.max_by(@supported_delimiters, fn delimiter ->
      first_line
      |> String.split(delimiter)
      |> length()
    end)
  end

  defp parse_csv_rows(content, delimiter) when is_binary(delimiter) do
    {rows, current_row, current_field, in_quotes} =
      parse_csv(content, delimiter, [], [], "", false)

    cond do
      in_quotes ->
        {:error, "csv contains unterminated quoted value"}

      current_field != "" or current_row != [] ->
        final_row = finalize_row(current_row, current_field)
        {:ok, finalize_rows(rows, final_row)}

      true ->
        {:ok, finalize_rows(rows, nil)}
    end
  end

  defp parse_csv(<<>>, _delimiter, rows, current_row, current_field, in_quotes) do
    {rows, current_row, current_field, in_quotes}
  end

  defp parse_csv(<<"\"", rest::binary>>, delimiter, rows, current_row, current_field, false) do
    parse_csv(rest, delimiter, rows, current_row, current_field, true)
  end

  defp parse_csv(<<"\"\"", rest::binary>>, delimiter, rows, current_row, current_field, true) do
    parse_csv(rest, delimiter, rows, current_row, current_field <> "\"", true)
  end

  defp parse_csv(<<"\"", rest::binary>>, delimiter, rows, current_row, current_field, true) do
    parse_csv(rest, delimiter, rows, current_row, current_field, false)
  end

  defp parse_csv(
         <<delimiter_char::utf8, rest::binary>>,
         <<delimiter_char::utf8>>,
         rows,
         current_row,
         current_field,
         false
       ) do
    parse_csv(rest, <<delimiter_char::utf8>>, rows, current_row ++ [current_field], "", false)
  end

  defp parse_csv(<<"\n", rest::binary>>, delimiter, rows, current_row, current_field, false) do
    next_row = finalize_row(current_row, current_field)
    parse_csv(rest, delimiter, [next_row | rows], [], "", false)
  end

  defp parse_csv(<<"\r\n", rest::binary>>, delimiter, rows, current_row, current_field, false) do
    next_row = finalize_row(current_row, current_field)
    parse_csv(rest, delimiter, [next_row | rows], [], "", false)
  end

  defp parse_csv(<<"\r", rest::binary>>, delimiter, rows, current_row, current_field, false) do
    next_row = finalize_row(current_row, current_field)
    parse_csv(rest, delimiter, [next_row | rows], [], "", false)
  end

  defp parse_csv(
         <<char::utf8, rest::binary>>,
         delimiter,
         rows,
         current_row,
         current_field,
         in_quotes
       ) do
    parse_csv(
      rest,
      delimiter,
      rows,
      current_row,
      current_field <> <<char::utf8>>,
      in_quotes
    )
  end

  defp finalize_row(current_row, current_field), do: current_row ++ [current_field]

  defp finalize_rows(rows, nil), do: rows |> Enum.reverse() |> Enum.reject(&blank_row?/1)

  defp finalize_rows(rows, final_row),
    do: [final_row | rows] |> Enum.reverse() |> Enum.reject(&blank_row?/1)

  defp blank_row?(row),
    do: Enum.all?(row, fn value -> String.trim(to_string(value || "")) == "" end)

  defp resolve_header(_headers, nil), do: nil

  defp resolve_header(headers, value) do
    trimmed = normalize_string(value)

    Enum.find(headers, fn header ->
      String.downcase(header) == String.downcase(trimmed || "")
    end)
  end

  defp map_get(nil, _key), do: nil
  defp map_get(_map, nil), do: nil

  defp map_get(map, key) when is_binary(key) do
    Map.get(map, key)
  end

  defp map_get(map, key) when is_atom(key) do
    atom_key = Atom.to_string(key)
    Map.get(map, key) || Map.get(map, atom_key)
  end

  defp map_get(map, key), do: Map.get(map, key)

  defp normalize_string(nil), do: nil

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(value), do: normalize_string(to_string(value))

  defp normalize_number_string(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.replace(",", "")
    |> String.replace("$", "")
  end

  defp to_integer(nil), do: nil

  defp to_integer(value) when is_integer(value), do: value

  defp to_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp to_integer(_), do: nil

  defp strip_bom(<<"\uFEFF", rest::binary>>), do: rest
  defp strip_bom(content), do: content
end
