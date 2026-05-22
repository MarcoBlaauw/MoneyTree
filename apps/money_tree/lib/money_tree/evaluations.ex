defmodule MoneyTree.Evaluations do
  @moduledoc """
  Deterministic financial evaluation status aggregation.

  This context summarizes review posture from existing reviewed MoneyTree domains. It does
  not perform financial recommendations or persist inferred facts.
  """

  import Ecto.Query, warn: false

  alias MoneyTree.Loans.LenderQuote
  alias MoneyTree.Loans.LenderQuoteFeeLine
  alias MoneyTree.Loans.Loan
  alias MoneyTree.Loans.LoanDocument
  alias MoneyTree.Loans.LoanDocumentExtraction
  alias MoneyTree.Mortgages
  alias MoneyTree.Mortgages.Mortgage
  alias MoneyTree.Recurring.Anomaly
  alias MoneyTree.Recurring.Series
  alias MoneyTree.Repo
  alias MoneyTree.Users.User

  @default_stale_after_days 90
  @default_expiring_within_days 14
  @default_stuck_document_after_minutes 30
  @statuses ~w(incomplete stale needs_review opportunity expiring)
  @severity_rank %{"critical" => 0, "warning" => 1, "info" => 2}

  @doc """
  Returns cross-domain evaluation status counts and actionable items for a user.

  Rules are intentionally deterministic and conservative:

  * active loans and mortgages without review timestamps need review
  * active loans and mortgages with old review timestamps are stale
  * active mortgages without a home value estimate are incomplete for refinance/LTV checks
  * pending loan document extractions need review
  * active lender quotes expiring soon or already expired are surfaced as expiring
  """
  @spec status_summary(User.t() | binary(), keyword()) :: map()
  def status_summary(user, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    stale_after_days = Keyword.get(opts, :stale_after_days, @default_stale_after_days)
    expiring_within_days = Keyword.get(opts, :expiring_within_days, @default_expiring_within_days)

    stuck_document_after_minutes =
      Keyword.get(opts, :stuck_document_after_minutes, @default_stuck_document_after_minutes)

    user_id = normalize_user_id(user)

    items =
      []
      |> Kernel.++(mortgage_items(user, now, stale_after_days))
      |> Kernel.++(loan_items(user_id, now, stale_after_days))
      |> Kernel.++(pending_extraction_items(user_id))
      |> Kernel.++(document_processing_items(user_id, now, stuck_document_after_minutes))
      |> Kernel.++(quote_fee_review_items(user_id))
      |> Kernel.++(quote_expiration_items(user_id, now, expiring_within_days))
      |> Kernel.++(recurring_anomaly_items(user_id))
      |> Enum.sort_by(&{severity_rank(&1), &1.status, &1.title, &1.id})

    %{
      generated_at: now,
      counts: counts(items),
      items: items
    }
  end

  defp mortgage_items(user, now, stale_after_days) do
    user
    |> Mortgages.list_mortgages(preload: [])
    |> Enum.filter(&(&1.status == "active"))
    |> Enum.flat_map(fn mortgage ->
      []
      |> maybe_add_missing_home_value(mortgage)
      |> Kernel.++(review_freshness_items(:mortgage, mortgage, now, stale_after_days))
    end)
  end

  defp maybe_add_missing_home_value(items, %Mortgage{home_value_estimate: nil} = mortgage) do
    [
      item(%{
        id: "mortgage:#{mortgage.id}:home_value",
        domain: "mortgage",
        resource_id: mortgage.id,
        status: "incomplete",
        severity: "warning",
        title: "#{mortgage_label(mortgage)} is missing a home value estimate",
        summary: "Mortgage evaluations that depend on equity or LTV need a reviewed home value.",
        reasons: ["missing_home_value_estimate"],
        target_path: "/app/loans?mortgage_id=#{mortgage.id}"
      })
      | items
    ]
  end

  defp maybe_add_missing_home_value(items, _mortgage), do: items

  defp loan_items(user_id, now, stale_after_days) do
    Loan
    |> where([loan], loan.user_id == ^user_id and loan.status == "active")
    |> Repo.all()
    |> Enum.flat_map(&review_freshness_items(:loan, &1, now, stale_after_days))
  end

  defp review_freshness_items(domain, record, _now, _stale_after_days)
       when is_nil(record.last_reviewed_at) do
    [
      item(%{
        id: "#{domain}:#{record.id}:review",
        domain: Atom.to_string(domain),
        resource_id: record.id,
        status: "needs_review",
        severity: "warning",
        title: "#{record_label(domain, record)} has not been reviewed",
        summary: "Review the saved loan facts before using them for evaluation decisions.",
        reasons: ["never_reviewed"],
        target_path: target_path(domain, record)
      })
    ]
  end

  defp review_freshness_items(domain, record, now, stale_after_days) do
    stale_before = DateTime.add(now, -stale_after_days, :day)

    if DateTime.compare(record.last_reviewed_at, stale_before) == :lt do
      [
        item(%{
          id: "#{domain}:#{record.id}:stale",
          domain: Atom.to_string(domain),
          resource_id: record.id,
          status: "stale",
          severity: "info",
          title: "#{record_label(domain, record)} review is stale",
          summary: "The last reviewed facts are older than #{stale_after_days} days.",
          reasons: ["review_older_than_#{stale_after_days}_days"],
          target_path: target_path(domain, record)
        })
      ]
    else
      []
    end
  end

  defp pending_extraction_items(user_id) do
    LoanDocumentExtraction
    |> where(
      [extraction],
      extraction.user_id == ^user_id and extraction.status == "pending_review"
    )
    |> preload([:loan_document, :mortgage])
    |> order_by([extraction], desc: extraction.inserted_at)
    |> Repo.all()
    |> Enum.map(fn extraction ->
      document = extraction.loan_document || %LoanDocument{}
      mortgage = extraction.mortgage

      item(%{
        id: "loan_document_extraction:#{extraction.id}:review",
        domain: "loan_document_extraction",
        resource_id: extraction.id,
        status: "needs_review",
        severity: "warning",
        title: "Loan document extraction needs review",
        summary: extraction_summary(document, mortgage),
        reasons: ["pending_document_extraction_review"],
        target_path: "/app/loans?document_id=#{document.id}"
      })
    end)
  end

  defp document_processing_items(user_id, now, stuck_after_minutes) do
    stuck_before = DateTime.add(now, -stuck_after_minutes, :minute)

    LoanDocument
    |> where(
      [document],
      document.user_id == ^user_id and
        (document.status == "failed" or
           (document.status in ["queued", "extracting"] and document.updated_at <= ^stuck_before))
    )
    |> preload([:mortgage])
    |> order_by([document], asc: document.updated_at)
    |> Repo.all()
    |> Enum.map(fn document ->
      stuck? = document.status in ["queued", "extracting"]

      item(%{
        id: "loan_document:#{document.id}:#{document.status}",
        domain: "loan_document",
        resource_id: document.id,
        status: "needs_review",
        severity: if(document.status == "failed", do: "warning", else: "info"),
        title: document_processing_title(document, stuck?),
        summary: document_processing_summary(document, stuck_after_minutes, stuck?),
        reasons: [if(stuck?, do: "document_processing_stuck", else: "document_processing_failed")],
        target_path: "/app/loans?document_id=#{document.id}"
      })
    end)
  end

  defp quote_fee_review_items(user_id) do
    LenderQuoteFeeLine
    |> join(:inner, [line], quote in assoc(line, :lender_quote))
    |> where(
      [line, quote],
      quote.user_id == ^user_id and quote.status == "active" and line.requires_review == true
    )
    |> preload([line, quote], lender_quote: quote)
    |> order_by([line, quote], asc: quote.updated_at, asc: line.inserted_at)
    |> Repo.all()
    |> Enum.map(fn line ->
      quote = line.lender_quote

      item(%{
        id: "lender_quote_fee_line:#{line.id}:review",
        domain: "lender_quote_fee_line",
        resource_id: line.id,
        status: "needs_review",
        severity: "warning",
        title: "#{quote.lender_name} quote fee needs review",
        summary: fee_line_summary(line),
        reasons: ["lender_quote_fee_line_requires_review", line.classification],
        target_path: "/app/loans?quote_id=#{quote.id}"
      })
    end)
  end

  defp quote_expiration_items(user_id, now, expiring_within_days) do
    expires_before = DateTime.add(now, expiring_within_days, :day)

    LenderQuote
    |> where(
      [quote],
      quote.user_id == ^user_id and quote.status == "active" and
        not is_nil(quote.quote_expires_at) and quote.quote_expires_at <= ^expires_before
    )
    |> preload([:mortgage])
    |> order_by([quote], asc: quote.quote_expires_at)
    |> Repo.all()
    |> Enum.map(fn quote ->
      expired? = DateTime.compare(quote.quote_expires_at, now) == :lt

      item(%{
        id: "lender_quote:#{quote.id}:expiration",
        domain: "lender_quote",
        resource_id: quote.id,
        status: "expiring",
        severity: if(expired?, do: "critical", else: "warning"),
        title: "#{quote.lender_name} quote #{if expired?, do: "expired", else: "expires soon"}",
        summary: quote_expiration_summary(quote, expiring_within_days, expired?),
        reasons: [if(expired?, do: "quote_expired", else: "quote_expires_within_window")],
        target_path: "/app/loans?quote_id=#{quote.id}"
      })
    end)
  end

  defp recurring_anomaly_items(user_id) do
    Anomaly
    |> join(:inner, [anomaly], series in Series, on: anomaly.series_id == series.id)
    |> where([anomaly, series], series.user_id == ^user_id and anomaly.status == "open")
    |> preload([anomaly, series], series: series)
    |> order_by([anomaly, _series], desc: anomaly.detected_at)
    |> Repo.all()
    |> Enum.map(fn anomaly ->
      series = anomaly.series

      item(%{
        id: "recurring_anomaly:#{anomaly.id}:open",
        domain: "recurring_anomaly",
        resource_id: anomaly.id,
        status: "needs_review",
        severity: anomaly.severity,
        title: "Recurring #{String.replace(anomaly.anomaly_type, "_", " ")} needs review",
        summary: recurring_anomaly_summary(anomaly, series),
        reasons: ["open_recurring_anomaly", anomaly.anomaly_type],
        target_path: "/app/obligations?recurring_series_id=#{series.id}"
      })
    end)
  end

  defp item(attrs), do: Map.put(attrs, :source, "deterministic")

  defp counts(items) do
    base = Map.new(@statuses, &{&1, 0})

    Enum.reduce(items, base, fn item, acc ->
      Map.update!(acc, item.status, &(&1 + 1))
    end)
  end

  defp severity_rank(%{severity: severity}), do: Map.get(@severity_rank, severity, 9)

  defp record_label(:mortgage, mortgage), do: mortgage_label(mortgage)
  defp record_label(:loan, %Loan{name: name}), do: name

  defp mortgage_label(%Mortgage{nickname: nickname})
       when is_binary(nickname) and nickname != "" do
    nickname
  end

  defp mortgage_label(%Mortgage{property_name: property_name}) when is_binary(property_name) do
    property_name
  end

  defp target_path(:mortgage, mortgage), do: "/app/loans?mortgage_id=#{mortgage.id}"
  defp target_path(:loan, loan), do: "/app/loans?loan_id=#{loan.id}"

  defp extraction_summary(%LoanDocument{} = document, %Mortgage{} = mortgage) do
    "#{document.original_filename || "Loan document"} for #{mortgage_label(mortgage)} has extracted values awaiting confirmation."
  end

  defp extraction_summary(%LoanDocument{} = document, _mortgage) do
    "#{document.original_filename || "Loan document"} has extracted values awaiting confirmation."
  end

  defp document_processing_title(%LoanDocument{} = document, true) do
    "#{document.original_filename} document processing appears stuck"
  end

  defp document_processing_title(%LoanDocument{} = document, false) do
    "#{document.original_filename} document processing failed"
  end

  defp document_processing_summary(%LoanDocument{} = document, minutes, true) do
    "The document has stayed #{document.status} for more than #{minutes} minutes."
  end

  defp document_processing_summary(%LoanDocument{}, _minutes, false) do
    "The document extraction workflow failed and needs review before it can update loan records."
  end

  defp fee_line_summary(%LenderQuoteFeeLine{} = line) do
    note =
      if is_binary(line.review_note) and line.review_note != "" do
        " #{line.review_note}"
      else
        ""
      end

    "#{line.original_label} is classified as #{line.classification}.#{note}"
  end

  defp recurring_anomaly_summary(%Anomaly{} = anomaly, %Series{} = series) do
    "Recurring series #{series.fingerprint} has an open #{String.replace(anomaly.anomaly_type, "_", " ")} anomaly for #{Date.to_iso8601(anomaly.occurred_on)}."
  end

  defp quote_expiration_summary(%LenderQuote{} = quote, _window, true) do
    "The quote expiration date has passed: #{DateTime.to_iso8601(quote.quote_expires_at)}."
  end

  defp quote_expiration_summary(%LenderQuote{} = quote, window, false) do
    "The quote expires within #{window} days: #{DateTime.to_iso8601(quote.quote_expires_at)}."
  end

  defp normalize_user_id(%User{id: user_id}), do: user_id
  defp normalize_user_id(user_id) when is_binary(user_id), do: user_id
end
