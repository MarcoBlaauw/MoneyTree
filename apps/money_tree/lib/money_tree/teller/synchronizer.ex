defmodule MoneyTree.Teller.Synchronizer do
  @moduledoc """
  Synchronizes Teller accounts and transactions for a specific connection.

  The synchronizer coordinates remote API pagination, normalises Teller payloads into
  MoneyTree schemas, and persists cursor metadata for subsequent incremental runs.
  """

  alias Decimal, as: D
  alias Ecto.Changeset
  alias Jason
  alias MoneyTree.Accounts.Account
  alias MoneyTree.Audit
  alias MoneyTree.Currency
  alias MoneyTree.Institutions
  alias MoneyTree.Institutions.Connection
  alias MoneyTree.Repo
  alias MoneyTree.Transactions.Transaction

  @telemetry_start [:money_tree, :teller, :sync, :start]
  @telemetry_stop [:money_tree, :teller, :sync, :stop]
  @telemetry_exception [:money_tree, :teller, :sync, :exception]

  @type sync_result :: %{
          accounts_synced: non_neg_integer(),
          transactions_synced: non_neg_integer(),
          accounts_cursor: binary() | nil,
          transactions_cursor: binary() | nil,
          connection: Connection.t()
        }

  @spec sync(Connection.t(), keyword()) :: {:ok, sync_result()} | {:error, term()}
  def sync(%Connection{} = connection, opts \\ []) do
    client =
      Keyword.get(
        opts,
        :client,
        Application.get_env(:money_tree, :teller_client, MoneyTree.Teller.Client)
      )

    mode = Keyword.get(opts, :mode, "incremental")

    metadata =
      opts
      |> Keyword.get(:telemetry_metadata, %{})
      |> Map.new()
      |> Map.merge(sync_metadata(connection, mode))

    start_time = System.monotonic_time()

    Audit.log(:teller_sync_started, metadata)
    :telemetry.execute(@telemetry_start, %{system_time: System.system_time()}, metadata)

    case do_sync(connection, client) do
      {:ok, payload} ->
        finalize_success(connection, payload, metadata, start_time)

      {:error, reason} ->
        finalize_failure(connection, reason, metadata, start_time)
    end
  end

  defp do_sync(connection, client) do
    with {:ok, {accounts, accounts_cursor}} <- fetch_accounts(client, connection),
         {:ok, account_records} <- persist_accounts(connection, accounts),
         {:ok, transactions_cursor, transactions_synced} <-
           sync_transactions(client, connection, account_records) do
      {:ok,
       %{
         accounts_synced: map_size(account_records),
         transactions_synced: transactions_synced,
         accounts_cursor: accounts_cursor,
         transactions_cursor: transactions_cursor
       }}
    end
  end

  defp finalize_success(connection, payload, metadata, start_time) do
    now = DateTime.utc_now()

    case Institutions.update_sync_state(connection, %{
           accounts_cursor: payload.accounts_cursor,
           transactions_cursor: payload.transactions_cursor,
           last_synced_at: now,
           last_sync_error: nil,
           last_sync_error_at: nil
         }) do
      {:ok, updated_connection} ->
        duration = System.monotonic_time() - start_time

        success_metadata =
          metadata
          |> Map.put(:accounts_synced, payload.accounts_synced)
          |> Map.put(:transactions_synced, payload.transactions_synced)

        Audit.log(:teller_sync_succeeded, success_metadata)
        :telemetry.execute(@telemetry_stop, %{duration: duration}, success_metadata)

        {:ok,
         %{
           connection: updated_connection,
           accounts_synced: payload.accounts_synced,
           transactions_synced: payload.transactions_synced,
           accounts_cursor: payload.accounts_cursor,
           transactions_cursor: payload.transactions_cursor
         }}

      {:error, %Changeset{} = changeset} ->
        finalize_failure(connection, {:persistence, changeset}, metadata, start_time)
    end
  end

  defp finalize_failure(connection, reason, metadata, start_time) do
    duration = System.monotonic_time() - start_time
    error_info = normalize_error(reason)

    _ =
      Institutions.update_sync_state(connection, %{
        last_sync_error: error_info,
        last_sync_error_at: DateTime.utc_now()
      })

    failure_metadata = Map.put(metadata, :error, error_info)

    Audit.log(:teller_sync_failed, failure_metadata)
    :telemetry.execute(@telemetry_exception, %{duration: duration}, failure_metadata)

    {:error, reason}
  end

  defp fetch_accounts(client, connection) do
    base_params =
      %{
        teller_user_id: connection.teller_user_id,
        enrollment_id: connection.teller_enrollment_id
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    do_fetch_accounts(
      client,
      base_params,
      connection.accounts_cursor,
      connection.accounts_cursor,
      []
    )
  end

  defp do_fetch_accounts(client, params, cursor, latest_cursor, accounts) do
    request_params =
      params
      |> Map.put(:cursor, cursor)
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    case maybe_rate_limited(client.list_accounts(request_params)) do
      {:ok, response} ->
        {page_accounts, next_cursor} = normalize_paged_response(response)
        collected_accounts = accounts ++ page_accounts
        updated_cursor = next_cursor || latest_cursor

        if is_binary(next_cursor) do
          do_fetch_accounts(client, params, next_cursor, updated_cursor, collected_accounts)
        else
          {:ok, {collected_accounts, updated_cursor}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp persist_accounts(connection, accounts) do
    timestamp = DateTime.utc_now()

    accounts
    |> Enum.reduce_while({:ok, %{}}, fn account_payload, {:ok, acc} ->
      case upsert_account(connection, account_payload, timestamp) do
        {:ok, account} ->
          teller_id = get_id(account_payload)
          {:cont, {:ok, Map.put(acc, teller_id, account)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp upsert_account(connection, payload, timestamp) do
    teller_id = get_id(payload)
    currency = account_currency(payload)

    with {:id, true} <- {:id, is_binary(teller_id)},
         {:currency, true} <- {:currency, Currency.valid_code?(currency)},
         attrs <-
           %{
             user_id: connection.user_id,
             institution_id: connection.institution_id,
             institution_connection_id: connection.id,
             external_id: teller_id,
             name: account_name(payload),
             currency: currency,
             type: get_in_any(payload, ["type", :type]) || "account",
             subtype: get_in_any(payload, ["subtype", :subtype]),
             current_balance:
               to_decimal(
                 get_in_any(payload, [
                   ["balances", "current"],
                   ["balances", :current],
                   [:balances, "current"],
                   [:balances, :current]
                 ])
               ),
             available_balance:
               to_decimal(
                 get_in_any(payload, [
                   ["balances", "available"],
                   ["balances", :available],
                   [:balances, "available"],
                   [:balances, :available]
                 ])
               ),
             limit:
               to_decimal(
                 get_in_any(payload, [
                   ["balances", "limit"],
                   ["balances", :limit],
                   [:balances, "limit"],
                   [:balances, :limit]
                 ])
               ),
             last_synced_at: timestamp
           },
         changeset <- Account.changeset(%Account{}, attrs),
         {:ok, account} <-
           Repo.insert(changeset,
             conflict_target: [:user_id, :external_id],
             on_conflict: [
               set:
                 attrs
                 |> Map.take([
                   :name,
                   :currency,
                   :type,
                   :subtype,
                   :current_balance,
                   :available_balance,
                   :limit,
                   :last_synced_at,
                   :institution_id,
                   :institution_connection_id
                 ])
                 |> Map.put(:updated_at, timestamp)
                 |> Enum.into([])
             ],
             returning: true
           ) do
      {:ok, account}
    else
      {:id, _} ->
        {:error,
         {:missing_account_identifier,
          %{connection_id: connection.id, payload: sanitize_payload(payload)}}}

      {:currency, _} ->
        {:error,
         {:invalid_account_currency,
          %{connection_id: connection.id, account_id: teller_id, currency: currency}}}

      {:error, %Changeset{} = changeset} ->
        {:error, {:account_changeset, changeset}}
    end
  end

  @legacy_cursor_key "__legacy__"

  defp sync_transactions(client, connection, account_records) do
    initial_cursors = decode_transaction_cursors(connection.transactions_cursor)

    account_records
    |> Enum.reduce_while({:ok, initial_cursors, 0}, fn
      {_teller_id, %Account{} = account}, {:ok, cursor_map, count} ->
        cursor = account_cursor(cursor_map, account.external_id)

        case process_account_transactions(client, account, cursor) do
          {:ok, latest_cursor, processed_count} ->
            updated_map = put_account_cursor(cursor_map, account.external_id, latest_cursor)
            {:cont, {:ok, updated_map, count + processed_count}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
    end)
    |> case do
      {:ok, cursor_map, count} ->
        {:ok, encode_transaction_cursors(cursor_map), count}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp process_account_transactions(client, %Account{} = account, cursor) do
    teller_id = account.external_id

    do_process_account_transactions(client, account, teller_id, cursor, cursor, 0)
  end

  defp do_process_account_transactions(client, account, teller_id, cursor, latest_cursor, count) do
    params =
      %{cursor: cursor}
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    with {:ok, response} <- maybe_rate_limited(client.list_transactions(teller_id, params)),
         {:ok, {transactions, next_cursor}} <- {:ok, normalize_paged_response(response)},
         {:ok, processed} <- persist_transactions(account, transactions) do
      updated_count = count + processed
      updated_cursor = next_cursor || latest_cursor

      if is_binary(next_cursor) do
        do_process_account_transactions(
          client,
          account,
          teller_id,
          next_cursor,
          updated_cursor,
          updated_count
        )
      else
        {:ok, updated_cursor, updated_count}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_transaction_cursors(nil), do: %{}

  defp decode_transaction_cursors(binary) when is_binary(binary) do
    with {:ok, decoded} <- Jason.decode(binary),
         true <- is_map(decoded) do
      Enum.reduce(decoded, %{}, fn {key, value}, acc ->
        put_account_cursor(acc, key, value)
      end)
    else
      _ ->
        %{@legacy_cursor_key => binary}
    end
  rescue
    Jason.DecodeError -> %{@legacy_cursor_key => binary}
  end

  defp account_cursor(cursor_map, account_key) do
    case normalize_cursor_key(account_key) do
      nil -> Map.get(cursor_map, @legacy_cursor_key)
      normalized -> Map.get(cursor_map, normalized) || Map.get(cursor_map, @legacy_cursor_key)
    end
  end

  defp put_account_cursor(cursor_map, account_key, cursor) do
    case normalize_cursor_key(account_key) do
      nil -> cursor_map
      normalized -> Map.put(cursor_map, normalized, cursor)
    end
  end

  defp encode_transaction_cursors(cursor_map) when is_map(cursor_map) do
    sanitized =
      cursor_map
      |> Map.delete(@legacy_cursor_key)
      |> Enum.reduce(%{}, fn
        {_key, nil}, acc -> acc
        {key, value}, acc when is_binary(key) -> Map.put(acc, key, value)
        {key, value}, acc ->
          case normalize_cursor_key(key) do
            nil -> acc
            normalized -> Map.put(acc, normalized, value)
          end
      end)

    if map_size(sanitized) == 0 do
      nil
    else
      Jason.encode!(sanitized)
    end
  end

  defp encode_transaction_cursors(_other), do: nil

  defp normalize_cursor_key(key) when is_binary(key), do: key
  defp normalize_cursor_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_cursor_key(key) when is_integer(key), do: Integer.to_string(key)
  defp normalize_cursor_key(key) when is_float(key), do: Float.to_string(key)
  defp normalize_cursor_key(key) when is_nil(key), do: nil
  defp normalize_cursor_key(key), do: to_string(key)

  defp persist_transactions(_account, []), do: {:ok, 0}

  defp persist_transactions(account, transactions) do
    timestamp = DateTime.utc_now()

    transactions
    |> Enum.reduce_while({:ok, 0}, fn transaction_payload, {:ok, acc} ->
      case upsert_transaction(account, transaction_payload, timestamp) do
        {:ok, _transaction} ->
          {:cont, {:ok, acc + 1}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp build_transaction_attrs(account, payload, timestamp) do
    external_id = get_id(payload)
    amount = to_decimal(get_in_any(payload, ["amount", :amount]))
    posted_at = parse_datetime(posted_at_value(payload)) || timestamp

    candidate =
      normalize_currency(get_in_any(payload, ["currency", :currency])) || account.currency

    currency =
      if is_binary(candidate) and Currency.valid_code?(candidate), do: candidate, else: nil

    cond do
      not is_binary(external_id) ->
        {:error,
         {:missing_transaction_identifier,
          %{account_id: account.id, payload: sanitize_payload(payload)}}}

      is_nil(amount) ->
        {:error,
         {:invalid_transaction_amount,
          %{
            account_id: account.id,
            transaction_id: external_id,
            payload: sanitize_payload(payload)
          }}}

      is_nil(currency) ->
        {:error,
         {:invalid_transaction_currency,
          %{
            account_id: account.id,
            transaction_id: external_id,
            payload: sanitize_payload(payload)
          }}}

      true ->
        attrs = %{
          account_id: account.id,
          external_id: external_id,
          amount: amount,
          currency: currency,
          type: get_in_any(payload, ["type", :type]),
          posted_at: posted_at,
          settled_at:
            parse_datetime(get_in_any(payload, ["settled_at", :settled_at])) ||
              parse_datetime(
                get_in_any(payload, [
                  ["settled_at", "date"],
                  ["settled_at", :date],
                  [:settled_at, "date"],
                  [:settled_at, :date]
                ])
              ) ||
              parse_datetime(get_in_any(payload, ["date_settled", :date_settled])),
          description: transaction_description(payload),
          category:
            get_in_any(payload, ["category", :category]) ||
              get_in_any(payload, [
                ["details", "category"],
                ["details", :category],
                [:details, "category"],
                [:details, :category]
              ]),
          merchant_name:
            get_in_any(payload, ["merchant_name", :merchant_name]) ||
              get_in_any(payload, [
                ["details", "merchant"],
                ["details", :merchant],
                [:details, "merchant"],
                [:details, :merchant]
              ]),
          status: get_in_any(payload, ["status", :status]) || "posted",
          encrypted_metadata: metadata_payload(payload)
        }

        {:ok, attrs}
    end
  end

  defp upsert_transaction(account, payload, timestamp) do
    with {:ok, attrs} <- build_transaction_attrs(account, payload, timestamp),
         changeset <- Transaction.changeset(%Transaction{}, attrs),
         {:ok, transaction} <-
           Repo.insert(changeset,
             conflict_target: [:account_id, :external_id],
             on_conflict: [
               set:
                 attrs
                 |> Map.delete(:account_id)
                 |> Map.put(:updated_at, timestamp)
                 |> Enum.into([])
             ],
             returning: true
           ) do
      {:ok, transaction}
    else
      {:error, %Changeset{} = changeset} -> {:error, {:transaction_changeset, changeset}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp metadata_payload(payload) do
    case get_in_any(payload, ["details", :details]) do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  defp posted_at_value(payload) do
    get_in_any(payload, ["posted_at", :posted_at]) ||
      get_in_any(payload, ["date_posted", :date_posted]) ||
      get_in_any(payload, ["date", :date])
  end

  defp account_name(payload) do
    get_in_any(payload, ["name", :name]) ||
      get_in_any(payload, ["display_name", :display_name]) ||
      get_in_any(payload, ["type", :type]) ||
      "Account"
  end

  defp account_currency(payload) do
    payload
    |> get_in_any(["currency", :currency])
    |> case do
      nil ->
        get_in_any(payload, [
          ["balances", "currency"],
          ["balances", :currency],
          [:balances, "currency"],
          [:balances, :currency]
        ])

      value ->
        value
    end
    |> normalize_currency()
  end

  defp normalize_currency(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.upcase()
  end

  defp normalize_currency(value) when is_atom(value) do
    value |> Atom.to_string() |> normalize_currency()
  end

  defp normalize_currency(_), do: nil

  defp to_decimal(nil), do: nil
  defp to_decimal(%D{} = decimal), do: decimal

  defp to_decimal(value) do
    case D.cast(value) do
      {:ok, decimal} -> decimal
      :error -> nil
    end
  end

  defp parse_datetime(nil), do: nil
  defp parse_datetime(%DateTime{} = datetime), do: datetime

  defp parse_datetime(%NaiveDateTime{} = naive) do
    DateTime.from_naive!(naive, "Etc/UTC")
  end

  defp parse_datetime(%Date{} = date) do
    {:ok, datetime} = DateTime.new(date, ~T[00:00:00], "Etc/UTC")
    datetime
  end

  defp parse_datetime(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        nil

      match?({:ok, _, _}, DateTime.from_iso8601(value)) ->
        {:ok, datetime, _offset} = DateTime.from_iso8601(value)
        datetime

      match?({:ok, _date}, Date.from_iso8601(value)) ->
        {:ok, date} = Date.from_iso8601(value)
        parse_datetime(date)

      true ->
        nil
    end
  end

  defp parse_datetime(_), do: nil

  defp transaction_description(payload) do
    get_in_any(payload, ["description", :description]) ||
      get_in_any(payload, [
        ["details", "description"],
        ["details", :description],
        [:details, "description"],
        [:details, :description]
      ]) ||
      get_in_any(payload, ["name", :name]) ||
      "Transaction"
  end

  defp get_in_any(payload, paths) when is_list(paths) do
    Enum.reduce_while(List.wrap(paths), nil, fn path, acc ->
      case fetch_path(payload, path) do
        nil -> {:cont, acc}
        value -> {:halt, value}
      end
    end)
  end

  defp fetch_path(payload, path) when is_list(path) do
    Enum.reduce_while(List.wrap(path), payload, fn key, acc ->
      case do_get(acc, key) do
        nil -> {:halt, nil}
        value -> {:cont, value}
      end
    end)
  end

  defp fetch_path(payload, key), do: do_get(payload, key)

  defp do_get(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp do_get(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        case safe_existing_atom(key) do
          nil -> nil
          atom_key -> Map.get(map, atom_key)
        end
    end
  end

  defp do_get(_other, _key), do: nil

  defp safe_existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp get_id(map) do
    get_in_any(map, ["id", :id])
  end

  defp normalize_paged_response(response) when is_list(response), do: {response, nil}

  defp normalize_paged_response(%{} = response) do
    data =
      get_in_any(response, ["data", :data]) ||
        get_in_any(response, ["accounts", :accounts]) ||
        get_in_any(response, ["transactions", :transactions]) ||
        []

    cursor =
      get_in_any(response, ["next_cursor", :next_cursor]) ||
        get_in_any(response, ["next", :next])

    {List.wrap(data), cursor}
  end

  defp maybe_rate_limited({:error, error} = result) when is_map(error) do
    status = Map.get(error, :status) || Map.get(error, "status")
    type = Map.get(error, :type) || Map.get(error, "type")

    if type in [:http, "http"] and to_string(status) == "429" do
      retry_after = extract_retry_after(Map.get(error, :headers) || Map.get(error, "headers"))

      info =
        %{
          type: :http,
          status: 429,
          details: Map.get(error, :details) || Map.get(error, "details"),
          retry_after: retry_after
        }
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Map.new()

      {:error, {:rate_limited, info}}
    else
      result
    end
  end

  defp maybe_rate_limited(other), do: other

  defp extract_retry_after(headers) when is_list(headers) do
    headers
    |> Enum.find_value(fn
      {key, value} ->
        if String.downcase(to_string(key)) == "retry-after" do
          parse_retry_after_value(value)
        else
          nil
        end
    end)
  end

  defp extract_retry_after(_), do: nil

  defp parse_retry_after_value(value) when is_binary(value) do
    value = String.trim(value)

    case Integer.parse(value) do
      {seconds, _rest} -> seconds
      :error -> nil
    end
  end

  defp parse_retry_after_value(value) when is_integer(value), do: value
  defp parse_retry_after_value(_), do: nil

  defp normalize_error({:rate_limited, info}) when is_map(info) do
    info
    |> Map.put(:type, :rate_limited)
    |> Map.put_new(:status, 429)
  end

  defp normalize_error({:persistence, %Changeset{} = changeset}) do
    %{type: :persistence, errors: format_changeset_errors(changeset)}
  end

  defp normalize_error({:account_changeset, %Changeset{} = changeset}) do
    %{type: :account_changeset, errors: format_changeset_errors(changeset)}
  end

  defp normalize_error({:transaction_changeset, %Changeset{} = changeset}) do
    %{type: :transaction_changeset, errors: format_changeset_errors(changeset)}
  end

  defp normalize_error({:invalid_account_currency, info}) do
    %{type: :invalid_account_currency, details: info}
  end

  defp normalize_error({:missing_account_identifier, info}) do
    %{type: :missing_account_identifier, details: info}
  end

  defp normalize_error({:missing_transaction_identifier, info}) do
    %{type: :missing_transaction_identifier, details: info}
  end

  defp normalize_error({:invalid_transaction_amount, info}) do
    %{type: :invalid_transaction_amount, details: info}
  end

  defp normalize_error({:invalid_transaction_currency, info}) do
    %{type: :invalid_transaction_currency, details: info}
  end

  defp normalize_error(%Changeset{} = changeset) do
    %{type: :changeset, errors: format_changeset_errors(changeset)}
  end

  defp normalize_error(%{type: type} = error) when is_atom(type) do
    error |> Map.take([:type, :status, :code, :message, :details, :reason, :retry_after])
  end

  defp normalize_error(other) do
    %{type: :unexpected, message: inspect(other)}
  end

  defp format_changeset_errors(%Changeset{} = changeset) do
    Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp sync_metadata(connection, mode) do
    %{
      connection_id: connection.id,
      user_id: connection.user_id,
      institution_id: connection.institution_id,
      teller_user_id: connection.teller_user_id,
      mode: mode
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp sanitize_payload(payload) when is_map(payload) do
    keys = [
      "id",
      :id,
      "name",
      :name,
      "type",
      :type,
      "currency",
      :currency,
      "amount",
      :amount,
      "status",
      :status
    ]

    keys
    |> Enum.reduce(%{}, fn key, acc ->
      case do_get(payload, key) do
        nil -> acc
        value -> Map.put(acc, to_string(key), value)
      end
    end)
  end

  defp sanitize_payload(_), do: %{}
end
