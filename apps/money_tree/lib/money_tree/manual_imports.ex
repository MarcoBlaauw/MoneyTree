defmodule MoneyTree.ManualImports do
  @moduledoc """
  Manual import batch and staging lifecycle for transaction imports.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias MoneyTree.Accounts
  alias MoneyTree.Accounts.Account
  alias MoneyTree.Categorization
  alias MoneyTree.ManualImports.Batch
  alias MoneyTree.ManualImports.Row
  alias MoneyTree.Repo
  alias MoneyTree.Transactions
  alias MoneyTree.Transactions.DuplicateDetector
  alias MoneyTree.Transactions.Fingerprints
  alias MoneyTree.Transactions.TransferMatch
  alias MoneyTree.Transactions.TransferMatcher
  alias MoneyTree.Transactions.Transaction
  alias MoneyTree.Users.User
  alias Decimal

  @auto_transfer_lookback_days 7
  @auto_transfer_match_threshold Decimal.new("0.95")
  @auto_confirm_match_types ~w(checking_to_savings checking_to_credit_card checking_to_loan)

  @spec list_batches(User.t() | binary(), keyword()) :: [Batch.t()]
  def list_batches(user, opts \\ []) do
    limit = Keyword.get(opts, :limit)

    query =
      from(batch in Batch,
        where: batch.user_id == ^resolve_user_id(user),
        order_by: [desc: batch.inserted_at]
      )

    query
    |> maybe_limit(limit)
    |> Repo.all()
  end

  @spec get_batch(User.t() | binary(), binary()) :: {:ok, Batch.t()} | {:error, :not_found}
  def get_batch(user, batch_id) when is_binary(batch_id) do
    batch =
      from(batch in Batch,
        where: batch.id == ^batch_id and batch.user_id == ^resolve_user_id(user)
      )
      |> Repo.one()

    case batch do
      %Batch{} = value -> {:ok, value}
      nil -> {:error, :not_found}
    end
  end

  def get_batch(_user, _batch_id), do: {:error, :not_found}

  @spec create_batch(User.t() | binary(), map()) :: {:ok, Batch.t()} | {:error, term()}
  def create_batch(user, attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    with {:ok, attrs} <- put_accessible_account_id(user, attrs) do
      params =
        attrs
        |> Map.put("user_id", resolve_user_id(user))
        |> Map.put_new("status", "uploaded")
        |> Map.put_new("mapping_config", %{})
        |> Map.put_new("started_at", DateTime.utc_now() |> DateTime.truncate(:second))

      %Batch{}
      |> Batch.changeset(params)
      |> Repo.insert()
    end
  end

  @spec update_mapping(User.t() | binary(), binary(), map(), map()) ::
          {:ok, Batch.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def update_mapping(user, batch_id, mapping_config, attrs \\ %{})
      when is_binary(batch_id) and is_map(mapping_config) and is_map(attrs) do
    with {:ok, batch} <- get_batch(user, batch_id) do
      attrs = stringify_keys(attrs)

      params =
        attrs
        |> Map.put("mapping_config", mapping_config)
        |> Map.put_new("status", "mapped")

      batch
      |> Batch.changeset(params)
      |> Repo.update()
    end
  end

  @spec list_rows(User.t() | binary(), binary(), keyword()) :: [Row.t()]
  def list_rows(user, batch_id, opts \\ [])

  def list_rows(user, batch_id, opts) when is_binary(batch_id) do
    parse_status = Keyword.get(opts, :parse_status)
    review_decision = Keyword.get(opts, :review_decision)

    from(row in Row,
      join: batch in Batch,
      on: row.manual_import_batch_id == batch.id,
      where: batch.id == ^batch_id and batch.user_id == ^resolve_user_id(user),
      order_by: [asc: row.row_index]
    )
    |> maybe_filter_parse_status(parse_status)
    |> maybe_filter_review_decision(review_decision)
    |> Repo.all()
  end

  def list_rows(_user, _batch_id, _opts), do: []

  @spec stage_rows(User.t() | binary(), binary(), [map()]) ::
          {:ok, %{batch: Batch.t(), inserted_rows: non_neg_integer()}}
          | {:error, :not_found | Ecto.Changeset.t()}
  def stage_rows(user, batch_id, rows) when is_binary(batch_id) and is_list(rows) do
    with {:ok, batch} <- get_batch(user, batch_id) do
      indexed_rows = rows_with_index(rows)

      Multi.new()
      |> Multi.delete_all(
        :delete_existing_rows,
        from(row in Row, where: row.manual_import_batch_id == ^batch.id)
      )
      |> insert_rows(indexed_rows, batch.id)
      |> Multi.run(:batch, fn repo, _changes ->
        counts = batch_counts(repo, batch.id)

        batch
        |> Batch.changeset(
          Map.merge(counts, %{
            status: "parsed"
          })
        )
        |> repo.update()
      end)
      |> Repo.transaction()
      |> case do
        {:ok, changes} ->
          inserted_rows =
            changes
            |> Enum.count(fn {name, _value} ->
              is_binary(name) and String.starts_with?(name, "row_")
            end)

          {:ok, %{batch: changes.batch, inserted_rows: inserted_rows}}

        {:error, _operation, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  @spec update_rows(User.t() | binary(), binary(), [map()]) ::
          {:ok, Batch.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def update_rows(user, batch_id, updates) when is_binary(batch_id) and is_list(updates) do
    with {:ok, batch} <- get_batch(user, batch_id) do
      Multi.new()
      |> apply_row_updates(batch, updates)
      |> Multi.run(:batch, fn repo, _changes ->
        batch
        |> Batch.changeset(Map.put(batch_counts(repo, batch.id), :status, "reviewed"))
        |> repo.update()
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{batch: updated_batch}} -> {:ok, updated_batch}
        {:error, _operation, reason, _changes} -> {:error, reason}
      end
    end
  end

  @spec commit_batch(User.t() | binary(), binary()) ::
          {:ok, Batch.t()} | {:error, :not_found | :account_required | Ecto.Changeset.t()}
  def commit_batch(user, batch_id) when is_binary(batch_id) do
    with {:ok, batch} <- get_batch(user, batch_id),
         {:ok, account_id} <- ensure_account_for_commit(batch),
         staged_rows <- commit_candidate_rows(batch.id),
         {:ok, %{batch: updated_batch}} <- commit_rows_transaction(batch, account_id, staged_rows) do
      {:ok, updated_batch}
    end
  end

  @spec rollback_batch(User.t() | binary(), binary()) ::
          {:ok, Batch.t()}
          | {:error,
             :not_found | :not_committed | :already_rolled_back | :unsafe_transfer_matches}
  def rollback_batch(user, batch_id) when is_binary(batch_id) do
    with {:ok, batch} <- get_batch(user, batch_id),
         :ok <- ensure_batch_rollbackable(batch),
         transaction_ids <- committed_transaction_ids(batch.id),
         :ok <- ensure_safe_batch_rollback(transaction_ids),
         {:ok, %{batch: rolled_back_batch}} <- rollback_batch_transaction(batch, transaction_ids) do
      {:ok, rolled_back_batch}
    end
  end

  defp commit_rows_transaction(batch, account_id, staged_rows) do
    Multi.new()
    |> Multi.update(:start_batch, Batch.changeset(batch, %{status: "committing"}))
    |> process_rows(batch, account_id, staged_rows)
    |> Multi.run(:batch, fn repo, _changes ->
      counts = batch_counts(repo, batch.id)

      batch
      |> Batch.changeset(
        counts
        |> Map.put(:status, "committed")
        |> Map.put(:committed_at, DateTime.utc_now() |> DateTime.truncate(:second))
      )
      |> repo.update()
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{batch: updated_batch}} -> {:ok, %{batch: updated_batch}}
      {:error, _operation, reason, _changes} -> {:error, reason}
    end
  end

  defp process_rows(multi, batch, account_id, rows) do
    Enum.reduce(rows, multi, fn row, acc ->
      Multi.run(acc, "commit_row_#{row.id}", fn repo, _changes ->
        commit_single_row(repo, batch, account_id, row)
      end)
    end)
  end

  defp commit_single_row(repo, batch, account_id, row) do
    case build_transaction_attrs(batch, account_id, row) do
      {:error, reason} ->
        row
        |> Row.changeset(%{
          parse_status: "error",
          parse_errors: Map.put(row.parse_errors || %{}, "commit", reason)
        })
        |> repo.update()

      {:ok, attrs} ->
        duplicate = DuplicateDetector.detect(attrs)

        if duplicate.status in [:exact, :high] do
          row
          |> Row.changeset(%{
            parse_status: "excluded",
            review_decision: "exclude",
            duplicate_candidate_transaction_id: duplicate.candidate_transaction_id,
            duplicate_confidence: duplicate.confidence_score,
            parse_errors:
              Map.put(row.parse_errors || %{}, "duplicate_reason", duplicate.explanation)
          })
          |> repo.update()
        else
          case %Transaction{} |> Transaction.changeset(attrs) |> repo.insert() do
            {:ok, transaction} ->
              if is_nil(attrs.category) do
                _ = Categorization.apply_to_transaction(transaction)
              end

              transfer_attrs =
                case maybe_auto_confirm_transfer_match(repo, batch, transaction) do
                  {:ok, attrs} ->
                    attrs

                  {:error, reason} ->
                    %{
                      parse_errors:
                        Map.put(row.parse_errors || %{}, "transfer_match", to_string(reason))
                    }
                end

              row
              |> Row.changeset(
                %{
                  parse_status: "committed",
                  duplicate_candidate_transaction_id: duplicate.candidate_transaction_id,
                  duplicate_confidence: duplicate.confidence_score,
                  committed_transaction_id: transaction.id
                }
                |> Map.merge(transfer_attrs)
              )
              |> repo.update()

            {:error, %Ecto.Changeset{} = changeset} ->
              row
              |> Row.changeset(%{
                parse_status: "error",
                parse_errors:
                  Map.put(
                    row.parse_errors || %{},
                    "transaction_insert",
                    inspect(changeset.errors)
                  )
              })
              |> repo.update()
          end
        end
    end
  end

  defp build_transaction_attrs(batch, account_id, row) do
    cond do
      is_nil(row.posted_at) ->
        {:error, "missing posted_at"}

      is_nil(row.amount) ->
        {:error, "missing amount"}

      true ->
        external_id =
          row.external_transaction_id ||
            "manual:#{batch.id}:#{row.row_index}:#{short_hash("#{batch.id}:#{row.id}")}"

        description =
          row.description || row.original_description || row.merchant_name ||
            "Imported transaction"

        transaction_kind =
          case row.direction do
            "income" -> "income"
            "expense" -> "expense"
            "transfer" -> "internal_transfer"
            _ -> "unknown"
          end

        attrs =
          %{
            account_id: account_id,
            external_id: external_id,
            source: "manual_import",
            source_transaction_id: row.external_transaction_id,
            source_reference: row.source_reference,
            posted_at: row.posted_at,
            authorized_at: row.authorized_at,
            amount: row.amount,
            currency: row.currency || "USD",
            description: description,
            original_description: row.original_description || description,
            merchant_name: row.merchant_name,
            category: row.category_name_snapshot,
            status: "posted",
            transaction_kind: transaction_kind,
            manual_import_batch_id: batch.id,
            manual_import_row_id: row.id
          }
          |> Map.put(
            :source_fingerprint,
            Fingerprints.source_fingerprint(%{
              source: "manual_import",
              account_id: account_id,
              source_transaction_id: row.external_transaction_id,
              source_reference: row.source_reference,
              posted_at: row.posted_at,
              amount: row.amount,
              original_description: row.original_description || description,
              currency: row.currency || "USD"
            })
          )
          |> Map.put(
            :normalized_fingerprint,
            Fingerprints.normalized_fingerprint(%{
              account_id: account_id,
              posted_at: row.posted_at,
              amount: row.amount,
              merchant_name: row.merchant_name,
              description: description,
              currency: row.currency || "USD"
            })
          )

        {:ok, attrs}
    end
  end

  defp commit_candidate_rows(batch_id) do
    from(row in Row,
      where: row.manual_import_batch_id == ^batch_id,
      where: row.parse_status in ["parsed", "warning"],
      where: row.review_decision != "exclude",
      order_by: [asc: row.row_index]
    )
    |> Repo.all()
  end

  defp rollback_batch_transaction(batch, transaction_ids) do
    Multi.new()
    |> Multi.update(:start_batch, Batch.changeset(batch, %{status: "rollback_pending"}))
    |> Multi.delete_all(
      :delete_transfer_matches,
      from(match in TransferMatch,
        where:
          match.outflow_transaction_id in ^transaction_ids or
            match.inflow_transaction_id in ^transaction_ids
      )
    )
    |> Multi.delete_all(
      :delete_transactions,
      from(transaction in Transaction,
        where:
          transaction.id in ^transaction_ids and transaction.manual_import_batch_id == ^batch.id
      )
    )
    |> Multi.run(:batch, fn repo, _changes ->
      counts = batch_counts(repo, batch.id)

      batch
      |> Batch.changeset(
        counts
        |> Map.put(:status, "rolled_back")
        |> Map.put(:rolled_back_at, DateTime.utc_now() |> DateTime.truncate(:second))
      )
      |> repo.update()
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{batch: updated_batch}} -> {:ok, %{batch: updated_batch}}
      {:error, _operation, reason, _changes} -> {:error, reason}
    end
  end

  defp maybe_auto_confirm_transfer_match(repo, batch, transaction) do
    case find_auto_confirm_transfer_candidate(repo, batch.user_id, transaction) do
      :no_match ->
        {:ok, %{}}

      {:ok, %{counterpart_transaction_id: counterpart_id} = suggestion} ->
        case ensure_no_existing_transfer_match(
               repo,
               suggestion.outflow_transaction_id,
               suggestion.inflow_transaction_id
             ) do
          :ok ->
            attrs =
              suggestion
              |> Map.take([
                :outflow_transaction_id,
                :inflow_transaction_id,
                :match_type,
                :confidence_score,
                :match_reason,
                :amount_difference,
                :date_difference_days
              ])
              |> Map.put(:status, "auto_confirmed")
              |> Map.put(:matched_by, "import_batch")

            case Transactions.create_transfer_match(batch.user_id, attrs) do
              {:ok, _match} ->
                {:ok,
                 %{
                   transfer_match_candidate_transaction_id: counterpart_id,
                   transfer_match_confidence: suggestion.confidence_score,
                   transfer_match_status: "auto_confirmed"
                 }}

              {:error, reason} ->
                {:error, "transfer match creation failed: #{inspect(reason)}"}
            end

          {:error, :already_matched} ->
            {:ok, %{}}
        end
    end
  end

  defp find_auto_confirm_transfer_candidate(repo, user_id, %Transaction{} = transaction) do
    with {:ok, transaction_with_account} <- transaction_with_account(repo, transaction),
         true <- has_amount?(transaction_with_account.amount),
         true <- matchable_direction?(transaction_with_account.amount),
         %DateTime{} = posted_at <- transaction_with_account.posted_at do
      from_dt = DateTime.add(posted_at, -@auto_transfer_lookback_days * 86_400, :second)
      to_dt = DateTime.add(posted_at, @auto_transfer_lookback_days * 86_400, :second)

      candidates =
        from(candidate in Transaction,
          join: account in Account,
          on: candidate.account_id == account.id,
          join: accessible in subquery(Accounts.accessible_accounts_query(user_id)),
          on: candidate.account_id == accessible.id,
          where: candidate.id != ^transaction.id,
          where: candidate.account_id != ^transaction.account_id,
          where: not is_nil(candidate.posted_at),
          where: candidate.posted_at >= ^from_dt and candidate.posted_at <= ^to_dt,
          limit: 200,
          preload: [account: account]
        )
        |> repo.all()

      candidates
      |> Enum.reduce(nil, fn candidate, best ->
        case oriented_match_suggestion(transaction_with_account, candidate) do
          nil ->
            best

          %{confidence_score: confidence, match_type: match_type} = suggestion ->
            if Decimal.compare(confidence, @auto_transfer_match_threshold) in [:eq, :gt] and
                 match_type in @auto_confirm_match_types and best_match?(best, suggestion) do
              suggestion
            else
              best
            end
        end
      end)
      |> case do
        nil -> :no_match
        suggestion -> {:ok, suggestion}
      end
    else
      _ -> :no_match
    end
  end

  defp oriented_match_suggestion(
         %Transaction{} = left,
         %Transaction{} = right
       ) do
    cond do
      outflow?(left.amount) and inflow?(right.amount) ->
        suggestion_for_pair(left, right, right.id)

      inflow?(left.amount) and outflow?(right.amount) ->
        suggestion_for_pair(right, left, right.id)

      true ->
        nil
    end
  end

  defp suggestion_for_pair(
         %Transaction{} = outflow,
         %Transaction{} = inflow,
         counterpart_transaction_id
       ) do
    case TransferMatcher.suggest_pair(outflow, outflow.account, inflow, inflow.account) do
      {:ok, suggestion} ->
        Map.put(suggestion, :counterpart_transaction_id, counterpart_transaction_id)

      :no_match ->
        nil
    end
  end

  defp ensure_no_existing_transfer_match(repo, outflow_transaction_id, inflow_transaction_id) do
    query =
      from(match in TransferMatch,
        where:
          (match.outflow_transaction_id == ^outflow_transaction_id and
             match.inflow_transaction_id == ^inflow_transaction_id) or
            (match.outflow_transaction_id == ^inflow_transaction_id and
               match.inflow_transaction_id == ^outflow_transaction_id),
        select: match.id,
        limit: 1
      )

    case repo.one(query) do
      nil -> :ok
      _match_id -> {:error, :already_matched}
    end
  end

  defp transaction_with_account(repo, %Transaction{} = transaction) do
    query =
      from(current in Transaction,
        join: account in Account,
        on: current.account_id == account.id,
        where: current.id == ^transaction.id,
        preload: [account: account]
      )

    case repo.one(query) do
      %Transaction{} = value -> {:ok, value}
      nil -> {:error, :not_found}
    end
  end

  defp ensure_batch_rollbackable(%Batch{status: "committed"}), do: :ok

  defp ensure_batch_rollbackable(%Batch{status: "rolled_back"}),
    do: {:error, :already_rolled_back}

  defp ensure_batch_rollbackable(%Batch{}), do: {:error, :not_committed}

  defp committed_transaction_ids(batch_id) do
    from(row in Row,
      where: row.manual_import_batch_id == ^batch_id,
      where: not is_nil(row.committed_transaction_id),
      select: row.committed_transaction_id
    )
    |> Repo.all()
  end

  defp ensure_safe_batch_rollback([]), do: :ok

  defp ensure_safe_batch_rollback(transaction_ids) do
    query =
      from(match in TransferMatch,
        where:
          (match.outflow_transaction_id in ^transaction_ids and
             match.inflow_transaction_id not in ^transaction_ids) or
            (match.inflow_transaction_id in ^transaction_ids and
               match.outflow_transaction_id not in ^transaction_ids),
        select: match.id,
        limit: 1
      )

    case Repo.one(query) do
      nil -> :ok
      _match_id -> {:error, :unsafe_transfer_matches}
    end
  end

  defp best_match?(nil, _suggestion), do: true

  defp best_match?(%{confidence_score: current_confidence}, %{confidence_score: new_confidence}) do
    Decimal.compare(new_confidence, current_confidence) == :gt
  end

  defp has_amount?(value) do
    case Decimal.cast(value) do
      {:ok, _decimal} -> true
      :error -> false
    end
  end

  defp matchable_direction?(value), do: outflow?(value) or inflow?(value)

  defp outflow?(value) do
    case Decimal.cast(value) do
      {:ok, decimal} -> Decimal.compare(decimal, Decimal.new("0")) == :lt
      :error -> false
    end
  end

  defp inflow?(value) do
    case Decimal.cast(value) do
      {:ok, decimal} -> Decimal.compare(decimal, Decimal.new("0")) == :gt
      :error -> false
    end
  end

  defp batch_counts(repo, batch_id) do
    rows = repo.all(from(row in Row, where: row.manual_import_batch_id == ^batch_id))

    %{
      row_count: length(rows),
      accepted_count: Enum.count(rows, &(&1.review_decision == "accept")),
      excluded_count:
        Enum.count(rows, &(&1.review_decision == "exclude" or &1.parse_status == "excluded")),
      duplicate_count: Enum.count(rows, &(not is_nil(&1.duplicate_candidate_transaction_id))),
      committed_count: Enum.count(rows, &(not is_nil(&1.committed_transaction_id))),
      error_count: Enum.count(rows, &(&1.parse_status == "error"))
    }
  end

  defp rows_with_index(rows) do
    Enum.with_index(rows, 1)
    |> Enum.map(fn {row, index} ->
      row
      |> Map.new()
      |> Map.put_new(:row_index, index)
    end)
  end

  defp insert_rows(multi, rows, batch_id) do
    Enum.reduce(rows, multi, fn row, acc ->
      row_attrs = Map.put(row, :manual_import_batch_id, batch_id)
      Multi.insert(acc, "row_#{row_attrs.row_index}", Row.changeset(%Row{}, row_attrs))
    end)
  end

  defp apply_row_updates(multi, batch, updates) do
    Enum.reduce(updates, multi, fn attrs, acc ->
      row_id = get(attrs, :id)

      Multi.run(acc, "update_row_#{row_id}", fn repo, _changes ->
        case repo.get_by(Row, id: row_id, manual_import_batch_id: batch.id) do
          nil ->
            {:error, :not_found}

          %Row{} = row ->
            row
            |> Row.changeset(Map.drop(attrs, [:id, "id"]))
            |> repo.update()
        end
      end)
    end)
  end

  defp put_accessible_account_id(user, attrs) do
    case get(attrs, :account_id) do
      nil ->
        {:ok, attrs}

      account_id ->
        case Accounts.fetch_accessible_account(user, account_id) do
          {:ok, _account} -> {:ok, attrs}
          {:error, :not_found} -> {:error, :not_found}
        end
    end
  end

  defp ensure_account_for_commit(%Batch{account_id: account_id}) when is_binary(account_id),
    do: {:ok, account_id}

  defp ensure_account_for_commit(_batch), do: {:error, :account_required}

  defp resolve_user_id(%User{id: user_id}), do: user_id
  defp resolve_user_id(user_id) when is_binary(user_id), do: user_id

  defp maybe_filter_parse_status(query, nil), do: query

  defp maybe_filter_parse_status(query, status),
    do: where(query, [row, _batch], row.parse_status == ^status)

  defp maybe_filter_review_decision(query, nil), do: query

  defp maybe_filter_review_decision(query, review_decision),
    do: where(query, [row, _batch], row.review_decision == ^review_decision)

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, limit) when is_integer(limit) and limit > 0, do: limit(query, ^limit)
  defp maybe_limit(query, _limit), do: query

  defp short_hash(input) do
    :sha256
    |> :crypto.hash(input)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end

  defp get(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp stringify_keys(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      key =
        case key do
          atom when is_atom(atom) -> Atom.to_string(atom)
          other -> other
        end

      Map.put(acc, key, value)
    end)
  end
end
