defmodule MoneyTree.SimpleFin.Synchronizer do
  @moduledoc """
  Synchronizes SimpleFIN accounts and transactions for a connection.
  """

  alias Decimal, as: D
  alias Ecto.Changeset
  import Ecto.Query, warn: false

  alias MoneyTree.Accounts.Account
  alias MoneyTree.Audit
  alias MoneyTree.Categorization
  alias MoneyTree.Currency
  alias MoneyTree.Institutions
  alias MoneyTree.Institutions.Connection
  alias MoneyTree.Institutions.Institution
  alias MoneyTree.Recurring
  alias MoneyTree.Repo
  alias MoneyTree.SimpleFin.Redaction
  alias MoneyTree.Transactions.Fingerprints
  alias MoneyTree.Transactions.Transaction

  @telemetry_start [:money_tree, :simplefin, :sync, :start]
  @telemetry_stop [:money_tree, :simplefin, :sync, :stop]
  @telemetry_exception [:money_tree, :simplefin, :sync, :exception]

  @spec sync(Connection.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def sync(connection, opts \\ [])

  def sync(%Connection{provider: "simplefin"} = connection, opts) do
    client_module =
      Keyword.get(
        opts,
        :client,
        Application.get_env(:money_tree, :simplefin_client, MoneyTree.SimpleFin.Client)
      )

    mode = Keyword.get(opts, :mode, "incremental")

    metadata =
      Map.merge(
        sync_metadata(connection, mode),
        Map.new(Keyword.get(opts, :telemetry_metadata, %{}))
      )

    start_time = System.monotonic_time()

    Audit.log(:simplefin_sync_started, metadata)
    :telemetry.execute(@telemetry_start, %{system_time: System.system_time()}, metadata)

    case do_sync(connection, client_module, mode) do
      {:ok, payload} -> finalize_success(connection, payload, metadata, start_time)
      {:error, reason} -> finalize_failure(connection, reason, metadata, start_time)
    end
  end

  def sync(%Connection{}, _opts), do: {:error, :invalid_provider}

  defp do_sync(connection, client_module, mode) do
    with {:ok, access_url} <- access_url(connection),
         :ok <- enforce_quota(connection),
         {:ok, response} <-
           get_accounts(client_module, access_url, sync_options(connection, mode)),
         {:ok, connection} <- record_request_usage(connection, response),
         {:ok, institution_map} <- ensure_account_institutions(response["connections"]),
         {:ok, account_records} <-
           persist_accounts(connection, response["accounts"], institution_map),
         {:ok, transaction_count} <-
           persist_transactions(connection, account_records, response["accounts"]),
         {:ok, connection} <- persist_provider_metadata(connection, response) do
      {:ok,
       %{
         connection: connection,
         accounts_synced: map_size(account_records),
         transactions_synced: transaction_count
       }}
    end
  end

  defp finalize_success(connection, payload, metadata, start_time) do
    now = DateTime.utc_now()

    case Institutions.update_sync_state(connection, %{
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

        Audit.log(:simplefin_sync_succeeded, success_metadata)
        :telemetry.execute(@telemetry_stop, %{duration: duration}, success_metadata)

        _ = Recurring.schedule_detection(updated_connection)

        {:ok,
         %{
           connection: updated_connection,
           accounts_synced: payload.accounts_synced,
           transactions_synced: payload.transactions_synced
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

    Audit.log(:simplefin_sync_failed, failure_metadata)
    :telemetry.execute(@telemetry_exception, %{duration: duration}, failure_metadata)

    {:error, reason}
  end

  defp sync_options(connection, mode) do
    today = Date.utc_today()
    start_date = sync_start_date(connection, mode, today)

    [
      start_date: start_date,
      end_date: Date.add(today, 1),
      pending: config(:include_pending, false),
      version: config(:protocol_version, "2")
    ]
  end

  defp sync_start_date(_connection, "initial", today) do
    Date.add(today, -min(config(:initial_sync_days, 90), 90))
  end

  defp sync_start_date(%Connection{last_synced_at: %DateTime{} = last_synced_at}, _mode, _today) do
    last_synced_at
    |> DateTime.to_date()
    |> Date.add(-3)
  end

  defp sync_start_date(_connection, _mode, today), do: sync_start_date(nil, "initial", today)

  defp persist_accounts(connection, accounts, institution_map) do
    timestamp = DateTime.utc_now()

    accounts
    |> List.wrap()
    |> Enum.reduce_while({:ok, %{}}, fn payload, {:ok, acc} ->
      case upsert_account(connection, payload, timestamp, institution_map) do
        {:ok, account} ->
          {:cont, {:ok, Map.put(acc, simplefin_account_id(payload), account)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp upsert_account(connection, payload, timestamp, institution_map) do
    simplefin_id = simplefin_account_id(payload)
    external_id = account_external_id(connection, simplefin_id)
    currency = account_currency(payload)
    institution_id = account_institution_id(connection, payload, institution_map)
    internal_account_kind = infer_internal_account_kind(payload)

    with {:id, true} <- {:id, is_binary(simplefin_id)},
         {:currency, true} <- {:currency, Currency.valid_code?(currency)},
         attrs <-
           %{
             user_id: connection.user_id,
             institution_id: institution_id,
             institution_connection_id: connection.id,
             external_id: external_id,
             name: account_name(payload),
             currency: currency,
             type: account_type(payload),
             subtype: get_any(payload, ["subtype", :subtype]),
             internal_account_kind: internal_account_kind,
             liability_type: liability_type_for_kind(internal_account_kind, payload),
             current_balance: to_decimal(get_any(payload, ["balance", :balance])) || D.new("0"),
             available_balance:
               to_decimal(get_any(payload, ["available-balance", :available_balance])),
             last_synced_at: timestamp
           },
         changeset <- Account.changeset(%Account{}, attrs),
         {:ok, account} <- upsert_simplefin_account(connection, changeset, attrs, timestamp) do
      {:ok, account}
    else
      {:id, _} ->
        {:error, {:missing_account_identifier, %{connection_id: connection.id}}}

      {:currency, _} ->
        {:error, {:invalid_account_currency, %{account_id: simplefin_id, currency: currency}}}

      {:error, %Changeset{} = changeset} ->
        {:error, {:account_changeset, changeset}}
    end
  end

  defp upsert_simplefin_account(connection, changeset, attrs, timestamp) do
    case find_relink_candidate(connection, attrs) do
      %Account{external_id: external_id} = account when external_id != attrs.external_id ->
        account
        |> Account.changeset(existing_account_attrs(account, attrs))
        |> Repo.update()

      _ ->
        insert_simplefin_account(connection, changeset, attrs, timestamp)
    end
  end

  defp insert_simplefin_account(connection, changeset, attrs, timestamp) do
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
            :last_synced_at,
            :institution_id,
            :institution_connection_id
          ])
          |> Map.put(:updated_at, timestamp)
          |> Enum.into([])
      ],
      returning: true
    )
    |> case do
      {:ok, account} ->
        {:ok, account}

      {:error, %Changeset{} = changeset} ->
        maybe_relink_existing_account(connection, changeset, attrs)
    end
  end

  defp maybe_relink_existing_account(connection, changeset, attrs) do
    case find_relink_candidate(connection, attrs) do
      %Account{} = account ->
        account
        |> Account.changeset(existing_account_attrs(account, attrs))
        |> Repo.update()

      nil ->
        {:error, changeset}
    end
  end

  defp find_relink_candidate(connection, attrs) do
    user_id = connection.user_id
    connection_id = connection.id
    name = attrs.name
    currency = attrs.currency

    from(account in Account,
      where:
        account.user_id == ^user_id and
          account.institution_connection_id == ^connection_id and
          account.name == ^name and
          account.currency == ^currency,
      limit: 2,
      order_by: [desc: account.updated_at]
    )
    |> Repo.all()
    |> case do
      [account] -> account
      _ambiguous_or_missing -> nil
    end
  end

  defp existing_account_attrs(account, attrs) do
    attrs
    |> Map.put(
      :internal_account_kind,
      account.internal_account_kind || attrs.internal_account_kind
    )
    |> Map.put(:liability_type, account.liability_type || attrs.liability_type)
  end

  defp persist_transactions(connection, account_records, account_payloads) do
    timestamp = DateTime.utc_now()

    account_payloads
    |> List.wrap()
    |> Enum.reduce_while({:ok, 0}, fn account_payload, {:ok, count} ->
      simplefin_account_id = simplefin_account_id(account_payload)
      account = Map.get(account_records, simplefin_account_id)

      case persist_account_transactions(connection, account, account_payload, timestamp) do
        {:ok, processed} -> {:cont, {:ok, count + processed}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp persist_account_transactions(_connection, nil, _payload, _timestamp), do: {:ok, 0}

  defp persist_account_transactions(connection, account, account_payload, timestamp) do
    account_payload
    |> get_any(["transactions", :transactions])
    |> List.wrap()
    |> Enum.reject(&(get_any(&1, ["pending", :pending]) == true))
    |> Enum.reduce_while({:ok, 0}, fn transaction_payload, {:ok, count} ->
      with {:ok, transaction} <-
             upsert_transaction(connection, account, transaction_payload, timestamp),
           {:ok, _categorized} <- Categorization.apply_to_transaction(transaction) do
        {:cont, {:ok, count + 1}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp upsert_transaction(connection, account, payload, timestamp) do
    with {:ok, attrs} <- build_transaction_attrs(connection, account, payload, timestamp),
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

  defp build_transaction_attrs(connection, account, payload, timestamp) do
    simplefin_id = get_any(payload, ["id", :id])
    amount = to_decimal(get_any(payload, ["amount", :amount]))
    posted_at = parse_datetime(get_any(payload, ["posted", :posted])) || timestamp

    cond do
      not is_binary(simplefin_id) ->
        {:error, {:missing_transaction_identifier, %{account_id: account.id}}}

      is_nil(amount) ->
        {:error,
         {:invalid_transaction_amount, %{account_id: account.id, transaction_id: simplefin_id}}}

      true ->
        external_id = transaction_external_id(connection, account.external_id, simplefin_id)
        description = transaction_description(payload)

        attrs =
          %{
            account_id: account.id,
            external_id: external_id,
            source: "simplefin",
            source_transaction_id: simplefin_id,
            amount: amount,
            currency: account.currency,
            type: get_any(payload, ["type", :type]) || "transaction",
            posted_at: posted_at,
            authorized_at: parse_datetime(get_any(payload, ["transacted_at", :transacted_at])),
            description: description,
            original_description: description,
            status:
              if(get_any(payload, ["pending", :pending]) == true, do: "pending", else: "posted"),
            encrypted_metadata: %{
              "simplefin" => %{
                "raw_amount" => get_any(payload, ["amount", :amount]),
                "extra" => get_any(payload, ["extra", :extra]) || %{}
              }
            }
          }
          |> with_fingerprints()

        {:ok, attrs}
    end
  end

  defp persist_provider_metadata(connection, response) do
    simplefin_metadata = %{
      "protocol_versions" => ["1", "2"],
      "selected_protocol_version" => to_string(config(:protocol_version, "2")),
      "connections" => List.wrap(response["connections"]) |> Redaction.redact(),
      "last_full_sync_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "errors" => Redaction.redact(response["errors"] || [])
    }

    provider_metadata = put_simplefin_metadata(connection.provider_metadata, simplefin_metadata)

    connection
    |> Connection.changeset(%{provider_metadata: provider_metadata})
    |> Repo.update()
  end

  defp ensure_account_institutions(connections) do
    connections
    |> List.wrap()
    |> Enum.reduce_while({:ok, %{}}, fn payload, {:ok, acc} ->
      case ensure_simplefin_institution(payload) do
        {:ok, %Institution{} = institution} ->
          case get_any(payload, ["conn_id", :conn_id]) do
            conn_id when is_binary(conn_id) ->
              {:cont, {:ok, Map.put(acc, conn_id, institution.id)}}

            _ ->
              {:cont, {:ok, acc}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp ensure_simplefin_institution(payload) do
    name = get_any(payload, ["org_name", :org_name, "name", :name]) || "SimpleFIN institution"
    org_id = get_any(payload, ["org_id", :org_id]) || normalize_slug(name)
    external_id = "simplefin:#{org_id}"

    case Repo.get_by(Institution, external_id: external_id) do
      %Institution{} = institution ->
        {:ok, institution}

      nil ->
        %Institution{}
        |> Institution.changeset(%{
          name: name,
          slug: normalize_slug("#{name}-#{org_id}"),
          external_id: external_id,
          website_url: get_any(payload, ["org_url", :org_url]),
          metadata: %{"provider" => "simplefin", "simplefin" => Redaction.redact(payload)}
        })
        |> Repo.insert()
    end
  end

  defp record_request_usage(connection, _response) do
    today = Date.utc_today() |> Date.to_iso8601()
    usage = request_usage(connection)

    usage =
      if usage["utc_date"] == today do
        Map.update(usage, "accounts_requests", 1, &(&1 + 1))
      else
        %{"utc_date" => today, "accounts_requests" => 1}
      end

    provider_metadata =
      put_simplefin_metadata(connection.provider_metadata, %{"request_usage" => usage})

    connection
    |> Connection.changeset(%{provider_metadata: provider_metadata})
    |> Repo.update()
  end

  defp enforce_quota(connection) do
    usage = request_usage(connection)
    today = Date.utc_today() |> Date.to_iso8601()
    max_requests = config(:max_requests_per_connection_per_day, 24)

    if usage["utc_date"] == today and (usage["accounts_requests"] || 0) >= max_requests do
      {:error, :quota_exceeded}
    else
      :ok
    end
  end

  defp request_usage(connection) do
    connection.provider_metadata
    |> normalize_map()
    |> get_in(["simplefin", "request_usage"])
    |> normalize_map()
  end

  defp access_url(%Connection{encrypted_credentials: credentials}) when is_binary(credentials) do
    case Jason.decode(credentials) do
      {:ok, %{"access_url" => access_url}} when is_binary(access_url) -> {:ok, access_url}
      _ -> {:error, :missing_access_url}
    end
  end

  defp access_url(_connection), do: {:error, :missing_access_url}

  defp get_accounts(client_module, access_url, opts) when is_atom(client_module) do
    client_module.get_accounts(access_url, opts)
  end

  defp get_accounts(client, access_url, opts),
    do: MoneyTree.SimpleFin.Client.get_accounts(client, access_url, opts)

  defp account_external_id(connection, simplefin_id),
    do: "simplefin:#{connection.id}:#{simplefin_id}"

  defp transaction_external_id(connection, account_external_id, simplefin_id) do
    account_id = String.replace_prefix(account_external_id, "simplefin:#{connection.id}:", "")
    "simplefin:#{connection.id}:#{account_id}:#{simplefin_id}"
  end

  defp simplefin_account_id(payload), do: get_any(payload, ["id", :id])

  defp account_name(payload), do: get_any(payload, ["name", :name]) || "SimpleFIN account"

  defp account_type(payload) do
    get_any(payload, ["type", :type]) ||
      get_in_any(payload, [
        ["extra", "account-type"],
        ["extra", :account_type],
        [:extra, "account-type"],
        [:extra, :account_type]
      ]) ||
      "account"
  end

  defp infer_internal_account_kind(payload) do
    text =
      [
        account_name(payload),
        account_type(payload),
        get_any(payload, ["subtype", :subtype]),
        get_in_any(payload, [
          ["extra", "account-type"],
          ["extra", :account_type],
          [:extra, "account-type"],
          [:extra, :account_type]
        ])
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> String.downcase()

    cond do
      String.contains?(text, "escrow") ->
        "escrow"

      String.contains?(text, "checking") ->
        "checking"

      String.contains?(text, "savings") or String.contains?(text, "money market") ->
        "savings"

      String.contains?(text, "credit") or String.contains?(text, "card") ->
        "credit_card"

      String.contains?(text, "mortgage") or String.contains?(text, "home loan") ->
        "mortgage"

      String.contains?(text, "loan") or String.contains?(text, "auto") or
          String.contains?(text, "student") ->
        "loan"

      String.contains?(text, "investment") or String.contains?(text, "brokerage") or
        String.contains?(text, "retirement") or String.contains?(text, "ira") or
          String.contains?(text, "401k") ->
        "investment"

      true ->
        "other"
    end
  end

  defp liability_type_for_kind("credit_card", _payload), do: "credit_card"
  defp liability_type_for_kind("mortgage", _payload), do: "mortgage"

  defp liability_type_for_kind("loan", payload) do
    text =
      [
        account_name(payload),
        account_type(payload),
        get_any(payload, ["subtype", :subtype])
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> String.downcase()

    cond do
      String.contains?(text, "auto") -> "auto_loan"
      String.contains?(text, "student") -> "student_loan"
      String.contains?(text, "pool") -> "pool_loan"
      true -> "other_loan"
    end
  end

  defp liability_type_for_kind(_kind, _payload), do: nil

  defp account_institution_id(connection, payload, institution_map) do
    case get_any(payload, ["conn_id", :conn_id]) do
      conn_id when is_binary(conn_id) ->
        Map.get(institution_map, conn_id, connection.institution_id)

      _ ->
        connection.institution_id
    end
  end

  defp account_currency(payload) do
    payload
    |> get_any(["currency", :currency])
    |> case do
      nil -> "USD"
      value -> value
    end
    |> normalize_currency()
  end

  defp transaction_description(payload) do
    get_any(payload, ["description", :description]) ||
      get_in_any(payload, [["extra", "name"], ["extra", :name], [:extra, "name"], [:extra, :name]]) ||
      "SimpleFIN transaction"
  end

  defp normalize_slug(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9-]+/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
  end

  defp with_fingerprints(attrs) do
    attrs
    |> Map.put(:source_fingerprint, Fingerprints.source_fingerprint(attrs))
    |> Map.put(:normalized_fingerprint, Fingerprints.normalized_fingerprint(attrs))
  end

  defp get_any(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp get_any(_map, _keys), do: nil

  defp get_in_any(map, paths) when is_map(map) do
    Enum.find_value(paths, fn path ->
      path
      |> List.wrap()
      |> Enum.reduce_while(map, fn key, acc ->
        cond do
          is_map(acc) and Map.has_key?(acc, key) -> {:cont, Map.get(acc, key)}
          true -> {:halt, nil}
        end
      end)
    end)
  end

  defp get_in_any(_map, _paths), do: nil

  defp to_decimal(nil), do: nil
  defp to_decimal(%D{} = decimal), do: decimal

  defp to_decimal(value) do
    case D.cast(value) do
      {:ok, decimal} -> decimal
      :error -> nil
    end
  end

  defp normalize_currency(value) when is_binary(value) do
    value |> String.trim() |> String.upcase()
  end

  defp normalize_currency(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_currency()

  defp normalize_currency(_value), do: nil

  defp parse_datetime(nil), do: nil
  defp parse_datetime(%DateTime{} = datetime), do: datetime
  defp parse_datetime(%Date{} = date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")

  defp parse_datetime(value) when is_integer(value) do
    DateTime.from_unix!(value)
  end

  defp parse_datetime(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        nil

      match?({:ok, _, _}, DateTime.from_iso8601(value)) ->
        {:ok, datetime, _offset} = DateTime.from_iso8601(value)
        datetime

      match?({:ok, _}, Date.from_iso8601(value)) ->
        {:ok, date} = Date.from_iso8601(value)
        parse_datetime(date)

      true ->
        nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp normalize_error(reason) do
    case reason do
      atom when is_atom(atom) ->
        %{"type" => Atom.to_string(atom)}

      {type, details} when is_atom(type) ->
        %{"type" => Atom.to_string(type), "details" => Redaction.redact(details)}

      other ->
        %{"type" => "error", "details" => Redaction.redact(inspect(other))}
    end
  end

  defp sync_metadata(connection, mode) do
    %{
      provider: "simplefin",
      mode: mode,
      connection_id: connection.id,
      user_id: connection.user_id,
      institution_id: connection.institution_id
    }
  end

  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(_value), do: %{}

  defp put_simplefin_metadata(provider_metadata, updates) do
    provider_metadata = normalize_map(provider_metadata)
    current = provider_metadata |> Map.get("simplefin", %{}) |> normalize_map()
    Map.put(provider_metadata, "simplefin", Map.merge(current, updates))
  end

  defp config(key, default) do
    :money_tree
    |> Application.get_env(MoneyTree.SimpleFin, [])
    |> Keyword.get(key, default)
  end
end
