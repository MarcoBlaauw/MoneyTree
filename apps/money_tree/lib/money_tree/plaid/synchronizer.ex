defmodule MoneyTree.Plaid.Synchronizer do
  @moduledoc """
  Synchronizes Plaid accounts and transactions for a specific connection.
  """

  alias Decimal, as: D
  alias Ecto.Changeset
  alias MoneyTree.Accounts.Account
  alias MoneyTree.Audit
  alias MoneyTree.Categorization
  alias MoneyTree.Currency
  alias MoneyTree.Institutions
  alias MoneyTree.Institutions.Connection
  alias MoneyTree.Recurring
  alias MoneyTree.Repo
  alias MoneyTree.Transactions.Transaction

  @telemetry_start [:money_tree, :plaid, :sync, :start]
  @telemetry_stop [:money_tree, :plaid, :sync, :stop]
  @telemetry_exception [:money_tree, :plaid, :sync, :exception]

  @type sync_result :: %{
          accounts_synced: non_neg_integer(),
          transactions_synced: non_neg_integer(),
          accounts_cursor: binary() | nil,
          transactions_cursor: binary() | nil,
          connection: Connection.t()
        }

  @spec sync(Connection.t(), keyword()) :: {:ok, sync_result()} | {:error, term()}
  def sync(%Connection{} = connection, opts \\ []) do
    client_module =
      Keyword.get(
        opts,
        :client,
        Application.get_env(:money_tree, :plaid_client, MoneyTree.Plaid.Client)
      )

    mode = Keyword.get(opts, :mode, "incremental")
    access_token = access_token(connection)

    metadata =
      opts
      |> Keyword.get(:telemetry_metadata, %{})
      |> Map.new()
      |> Map.merge(sync_metadata(connection, mode))

    start_time = System.monotonic_time()

    Audit.log(:plaid_sync_started, metadata)
    :telemetry.execute(@telemetry_start, %{system_time: System.system_time()}, metadata)

    with {:ok, token} <- ensure_access_token(access_token, connection.id),
         {:ok, client} <- build_client(client_module),
         {:ok, payload} <- do_sync(connection, client, token) do
      finalize_success(connection, payload, metadata, start_time)
    else
      {:error, reason} ->
        finalize_failure(connection, reason, metadata, start_time)
    end
  end

  defp do_sync(connection, client, access_token) do
    with {:ok, accounts} <- fetch_accounts(client, access_token),
         {:ok, account_records} <- persist_accounts(connection, accounts),
         {:ok, transactions_cursor, transactions_synced} <-
           sync_transactions(client, access_token, connection, account_records) do
      {:ok,
       %{
         accounts_synced: map_size(account_records),
         transactions_synced: transactions_synced,
         accounts_cursor: nil,
         transactions_cursor: transactions_cursor
       }}
    end
  end

  defp fetch_accounts(client, access_token) do
    case maybe_rate_limited(list_accounts(client, %{"access_token" => access_token})) do
      {:ok, response} ->
        {accounts, _cursor} = normalize_paged_response(response)
        {:ok, accounts}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sync_transactions(client, access_token, connection, account_records) do
    do_sync_transactions(
      client,
      access_token,
      account_records,
      connection.transactions_cursor,
      connection.transactions_cursor,
      0
    )
  end

  defp do_sync_transactions(client, access_token, account_records, cursor, latest_cursor, count) do
    params =
      %{"access_token" => access_token, "cursor" => cursor, "count" => 500}
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.into(%{})

    with {:ok, response} <- maybe_rate_limited(list_transactions(client, params)),
         {:ok, {transactions, next_cursor, has_more}} <- {:ok, normalize_sync_response(response)},
         {:ok, processed} <- persist_transactions(account_records, transactions) do
      updated_cursor = next_cursor || latest_cursor
      updated_count = count + processed

      if has_more do
        do_sync_transactions(
          client,
          access_token,
          account_records,
          next_cursor,
          updated_cursor,
          updated_count
        )
      else
        {:ok, updated_cursor, updated_count}
      end
    else
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
          plaid_account_id = get_in_any(account_payload, ["account_id", :account_id, "id", :id])
          {:cont, {:ok, Map.put(acc, plaid_account_id, account)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp upsert_account(connection, payload, timestamp) do
    plaid_account_id = get_in_any(payload, ["account_id", :account_id, "id", :id])
    currency = account_currency(payload)

    with {:id, true} <- {:id, is_binary(plaid_account_id)},
         {:currency, true} <- {:currency, Currency.valid_code?(currency)},
         attrs <-
           %{
             user_id: connection.user_id,
             institution_id: connection.institution_id,
             institution_connection_id: connection.id,
             external_id: plaid_account_id,
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
               ) || D.new("0"),
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
          %{connection_id: connection.id, account_id: plaid_account_id, currency: currency}}}

      {:error, %Changeset{} = changeset} ->
        {:error, {:account_changeset, changeset}}
    end
  end

  defp persist_transactions(_account_records, []), do: {:ok, 0}

  defp persist_transactions(account_records, transactions) do
    timestamp = DateTime.utc_now()

    transactions
    |> Enum.reduce_while({:ok, 0}, fn payload, {:ok, acc} ->
      plaid_account_id = get_in_any(payload, ["account_id", :account_id])

      case Map.get(account_records, plaid_account_id) do
        %Account{} = account ->
          with {:ok, transaction} <- upsert_transaction(account, payload, timestamp),
               {:ok, _categorized} <- Categorization.apply_to_transaction(transaction) do
            {:cont, {:ok, acc + 1}}
          else
            {:error, reason} ->
              {:halt, {:error, reason}}
          end

        _ ->
          {:cont, {:ok, acc}}
      end
    end)
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

  defp build_transaction_attrs(account, payload, timestamp) do
    external_id = get_in_any(payload, ["transaction_id", :transaction_id, "id", :id])
    amount = to_decimal(get_in_any(payload, ["amount", :amount]))
    posted_at = parse_datetime(posted_at_value(payload)) || timestamp

    candidate =
      normalize_currency(
        get_in_any(payload, ["iso_currency_code", :iso_currency_code, "currency", :currency])
      ) ||
        account.currency

    currency =
      if is_binary(candidate) and Currency.valid_code?(candidate), do: candidate, else: nil

    status = if truthy?(get_in_any(payload, ["pending", :pending])), do: "pending", else: "posted"

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
          type:
            get_in_any(payload, [
              "payment_channel",
              :payment_channel,
              "transaction_type",
              :transaction_type
            ]),
          posted_at: posted_at,
          settled_at:
            parse_datetime(get_in_any(payload, ["authorized_datetime", :authorized_datetime])),
          description: transaction_description(payload),
          category:
            get_in_any(payload, ["category", :category]) ||
              get_in_any(payload, [
                ["personal_finance_category", "primary"],
                [:personal_finance_category, :primary]
              ]),
          merchant_name: get_in_any(payload, ["merchant_name", :merchant_name]),
          status: status,
          encrypted_metadata: metadata_payload(payload)
        }

        {:ok, attrs}
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

        Audit.log(:plaid_sync_succeeded, success_metadata)
        :telemetry.execute(@telemetry_stop, %{duration: duration}, success_metadata)

        _ = Recurring.schedule_detection(updated_connection)

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

    Audit.log(:plaid_sync_failed, failure_metadata)
    :telemetry.execute(@telemetry_exception, %{duration: duration}, failure_metadata)

    {:error, reason}
  end

  defp build_client(client_module) when is_atom(client_module) do
    if function_exported?(client_module, :new, 1) do
      {:ok, client_module.new()}
    else
      {:ok, client_module}
    end
  end

  defp build_client(client), do: {:ok, client}

  defp list_accounts(%MoneyTree.Plaid.Client{} = client, params) do
    access_token = params["access_token"] || params[:access_token]
    MoneyTree.Plaid.Client.list_accounts(client, access_token, params)
  end

  defp list_accounts(client, params) when is_atom(client), do: client.list_accounts(params)

  defp list_transactions(%MoneyTree.Plaid.Client{} = client, params) do
    access_token = params["access_token"] || params[:access_token]
    MoneyTree.Plaid.Client.sync_transactions(client, access_token, params)
  end

  defp list_transactions(client, params) when is_atom(client),
    do: client.list_transactions(params)

  defp normalize_sync_response(%{} = response) do
    data =
      get_in_any(response, ["data", :data]) ||
        get_in_any(response, ["transactions", :transactions]) ||
        []

    next_cursor = get_in_any(response, ["next_cursor", :next_cursor])
    has_more = truthy?(get_in_any(response, ["has_more", :has_more]))

    {List.wrap(data), next_cursor, has_more}
  end

  defp normalize_sync_response(response) do
    {List.wrap(response), nil, false}
  end

  defp normalize_paged_response(response) when is_list(response), do: {response, nil}

  defp normalize_paged_response(%{} = response) do
    data =
      get_in_any(response, ["data", :data]) ||
        get_in_any(response, ["accounts", :accounts]) ||
        []

    cursor = get_in_any(response, ["next_cursor", :next_cursor])

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

  defp ensure_access_token(nil, connection_id),
    do: {:error, {:missing_access_token, %{connection_id: connection_id}}}

  defp ensure_access_token("", connection_id),
    do: {:error, {:missing_access_token, %{connection_id: connection_id}}}

  defp ensure_access_token(access_token, _connection_id), do: {:ok, access_token}

  defp access_token(%Connection{encrypted_credentials: credentials})
       when is_binary(credentials) do
    case Jason.decode(credentials) do
      {:ok, payload} when is_map(payload) ->
        payload["access_token"] || payload["token"] || payload["accessToken"]

      _ ->
        nil
    end
  end

  defp access_token(_connection), do: nil

  defp account_name(payload) do
    get_in_any(payload, ["name", :name]) ||
      get_in_any(payload, ["official_name", :official_name]) ||
      get_in_any(payload, ["type", :type]) ||
      "Account"
  end

  defp account_currency(payload) do
    payload
    |> get_in_any(["iso_currency_code", :iso_currency_code, "currency", :currency])
    |> case do
      nil ->
        get_in_any(payload, [
          ["balances", "iso_currency_code"],
          ["balances", :iso_currency_code],
          [:balances, "iso_currency_code"],
          [:balances, :iso_currency_code]
        ])

      value ->
        value
    end
    |> normalize_currency()
  end

  defp posted_at_value(payload) do
    get_in_any(payload, ["datetime", :datetime]) ||
      get_in_any(payload, ["authorized_datetime", :authorized_datetime]) ||
      get_in_any(payload, ["date", :date])
  end

  defp transaction_description(payload) do
    get_in_any(payload, ["name", :name]) ||
      get_in_any(payload, ["merchant_name", :merchant_name]) ||
      "Transaction"
  end

  defp metadata_payload(payload) when is_map(payload) do
    %{
      "payment_channel" => get_in_any(payload, ["payment_channel", :payment_channel]),
      "personal_finance_category" =>
        get_in_any(payload, ["personal_finance_category", :personal_finance_category]),
      "pending_transaction_id" =>
        get_in_any(payload, ["pending_transaction_id", :pending_transaction_id])
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp metadata_payload(_), do: %{}

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

  defp normalize_currency(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.upcase()
  end

  defp normalize_currency(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_currency()

  defp normalize_currency(_), do: nil

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
    case Integer.parse(String.trim(value)) do
      {seconds, _rest} -> seconds
      :error -> nil
    end
  end

  defp parse_retry_after_value(value) when is_integer(value), do: value
  defp parse_retry_after_value(_), do: nil

  defp truthy?(value), do: value in [true, "true", 1, "1"]

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

  defp normalize_error({:invalid_account_currency, info}),
    do: %{type: :invalid_account_currency, details: info}

  defp normalize_error({:missing_account_identifier, info}),
    do: %{type: :missing_account_identifier, details: info}

  defp normalize_error({:missing_transaction_identifier, info}),
    do: %{type: :missing_transaction_identifier, details: info}

  defp normalize_error({:invalid_transaction_amount, info}),
    do: %{type: :invalid_transaction_amount, details: info}

  defp normalize_error({:invalid_transaction_currency, info}),
    do: %{type: :invalid_transaction_currency, details: info}

  defp normalize_error({:missing_access_token, info}),
    do: %{type: :missing_access_token, details: info}

  defp normalize_error(%Changeset{} = changeset) do
    %{type: :changeset, errors: format_changeset_errors(changeset)}
  end

  defp normalize_error(%{type: type} = error) when is_atom(type) do
    error |> Map.take([:type, :status, :code, :message, :details, :reason, :retry_after])
  end

  defp normalize_error(other), do: %{type: :unexpected, message: inspect(other)}

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
      plaid_item_id: get_in_any(connection.provider_metadata || %{}, ["item_id", :item_id]),
      mode: mode
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp sanitize_payload(payload) when is_map(payload) do
    keys = [
      "id",
      :id,
      "transaction_id",
      :transaction_id,
      "account_id",
      :account_id,
      "name",
      :name,
      "currency",
      :currency,
      "iso_currency_code",
      :iso_currency_code,
      "amount",
      :amount
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
