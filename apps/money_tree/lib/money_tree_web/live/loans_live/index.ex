defmodule MoneyTreeWeb.LoansLive.Index do
  @moduledoc """
  Loan Center overview with a mortgage-first baseline.
  """

  use MoneyTreeWeb, :live_view

  alias MoneyTree.Loans
  alias MoneyTree.Loans.AlertRule
  alias MoneyTree.Loans.Amortization
  alias MoneyTree.Loans.LenderQuote
  alias MoneyTree.Loans.Loan
  alias MoneyTree.Loans.LoanDocument
  alias MoneyTree.Loans.LoanDocumentExtraction
  alias MoneyTree.Loans.RateObservation
  alias MoneyTree.Loans.RateSource
  alias MoneyTree.Loans.RefinanceCalculator
  alias MoneyTree.Loans.RefinanceFeeItem
  alias MoneyTree.Loans.RefinanceScenario
  alias MoneyTree.Mortgages
  alias MoneyTree.Mortgages.Mortgage

  @impl true
  def mount(params, _session, %{assigns: %{current_user: current_user}} = socket) do
    socket =
      socket
      |> assign(
        page_title: "Loan Center",
        route_loan_id: Map.get(params, "loan_id"),
        mortgage_form_open?: false,
        mortgage_form_mode: :new,
        editing_mortgage: nil,
        mortgage_changeset: mortgage_changeset(current_user),
        generic_loan_form_open?: false,
        generic_loan_changeset: generic_loan_changeset(current_user),
        what_if_form: default_what_if_form(nil),
        what_if_summary: nil,
        selected_analysis_scenario_id: nil,
        scenario_form_open?: false,
        scenario_changeset: scenario_changeset(current_user, []),
        rate_observation_form_open?: false,
        rate_observation_changeset: rate_observation_changeset(),
        fee_form_open?: false,
        fee_changeset: fee_changeset([]),
        document_form_open?: false,
        document_changeset: document_changeset(current_user, []),
        extraction_form_open?: false,
        extraction_form: default_extraction_form([]),
        ollama_extraction_form_open?: false,
        ollama_extraction_form: default_ollama_extraction_form([]),
        quote_form_open?: false,
        quote_changeset: quote_changeset(current_user, []),
        alert_form_open?: false,
        alert_form: default_alert_form([])
      )
      |> load_page(current_user)

    {:ok,
     allow_upload(socket, :loan_document_file,
       accept:
         ~w(.pdf .png .jpg .jpeg .txt .md .csv text/plain text/markdown text/csv application/pdf image/png image/jpeg),
       max_entries: 1,
       max_file_size: 20_000_000
     )}
  end

  @impl true
  def handle_event("new-mortgage", _params, %{assigns: %{current_user: current_user}} = socket) do
    {:noreply,
     assign(socket,
       mortgage_form_open?: true,
       mortgage_form_mode: :new,
       editing_mortgage: nil,
       mortgage_changeset: mortgage_changeset(current_user)
     )}
  end

  def handle_event("cancel-mortgage", _params, %{assigns: %{current_user: current_user}} = socket) do
    {:noreply,
     assign(socket,
       mortgage_form_open?: false,
       mortgage_form_mode: :new,
       editing_mortgage: nil,
       mortgage_changeset: mortgage_changeset(current_user)
     )}
  end

  def handle_event(
        "new-generic-loan",
        _params,
        %{assigns: %{current_user: current_user}} = socket
      ) do
    {:noreply,
     assign(socket,
       generic_loan_form_open?: true,
       generic_loan_changeset: generic_loan_changeset(current_user)
     )}
  end

  def handle_event(
        "cancel-generic-loan",
        _params,
        %{assigns: %{current_user: current_user}} = socket
      ) do
    {:noreply,
     assign(socket,
       generic_loan_form_open?: false,
       generic_loan_changeset: generic_loan_changeset(current_user)
     )}
  end

  def handle_event(
        "validate-generic-loan",
        %{"loan" => params},
        %{assigns: %{current_user: current_user}} = socket
      ) do
    changeset =
      current_user
      |> base_generic_loan(params)
      |> Loans.change_loan(normalize_generic_loan_rate_params(params))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, generic_loan_form_open?: true, generic_loan_changeset: changeset)}
  end

  def handle_event(
        "save-generic-loan",
        %{"loan" => params},
        %{assigns: %{current_user: current_user}} = socket
      ) do
    params = normalize_generic_loan_rate_params(params)

    case Loans.create_loan(current_user, params) do
      {:ok, _loan} ->
        {:noreply,
         socket
         |> load_page(current_user)
         |> assign(
           generic_loan_form_open?: false,
           generic_loan_changeset: generic_loan_changeset(current_user)
         )
         |> put_flash(:info, "Loan added to Loan Center.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket,
           generic_loan_form_open?: true,
           generic_loan_changeset: Map.put(changeset, :action, :validate)
         )}
    end
  end

  def handle_event(
        "edit-mortgage",
        %{"id" => mortgage_id},
        %{assigns: %{current_user: current_user}} = socket
      ) do
    case Mortgages.fetch_mortgage(current_user, mortgage_id) do
      {:ok, mortgage} ->
        {:noreply,
         assign(socket,
           mortgage_form_open?: true,
           mortgage_form_mode: :edit,
           editing_mortgage: mortgage,
           mortgage_changeset: Mortgages.change_mortgage(mortgage)
         )}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Mortgage record not found.")}
    end
  end

  def handle_event(
        "validate-mortgage",
        %{"mortgage" => params},
        %{assigns: %{current_user: current_user}} = socket
      ) do
    params = normalize_mortgage_rate_params(params)

    changeset =
      socket
      |> mortgage_for_form(current_user)
      |> Mortgages.change_mortgage(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, mortgage_changeset: changeset, mortgage_form_open?: true)}
  end

  def handle_event(
        "save-mortgage",
        %{"mortgage" => params},
        %{assigns: %{current_user: current_user}} = socket
      ) do
    params = normalize_mortgage_rate_params(params)

    result =
      case socket.assigns.mortgage_form_mode do
        :edit ->
          Mortgages.update_mortgage(current_user, socket.assigns.editing_mortgage, params)

        _ ->
          Mortgages.create_mortgage(current_user, params)
      end

    case result do
      {:ok, _mortgage} ->
        {:noreply,
         socket
         |> load_page(current_user)
         |> assign(
           mortgage_form_open?: false,
           mortgage_form_mode: :new,
           editing_mortgage: nil,
           mortgage_changeset: mortgage_changeset(current_user)
         )
         |> put_flash(:info, mortgage_saved_message(socket.assigns.mortgage_form_mode))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket,
           mortgage_form_open?: true,
           mortgage_changeset: Map.put(changeset, :action, :validate)
         )}
    end
  end

  def handle_event(
        "new-scenario",
        _params,
        %{assigns: %{current_user: current_user, mortgages: mortgages}} = socket
      ) do
    {:noreply,
     assign(socket,
       scenario_form_open?: true,
       scenario_changeset: scenario_changeset(current_user, mortgages)
     )}
  end

  def handle_event(
        "cancel-scenario",
        _params,
        %{assigns: %{current_user: current_user, mortgages: mortgages}} = socket
      ) do
    {:noreply,
     assign(socket,
       scenario_form_open?: false,
       scenario_changeset: scenario_changeset(current_user, mortgages)
     )}
  end

  def handle_event(
        "validate-scenario",
        %{"refinance_scenario" => params},
        %{assigns: %{current_user: current_user, mortgages: mortgages}} = socket
      ) do
    params = normalize_scenario_rate_params(params)

    changeset =
      current_user
      |> base_scenario(mortgages, params)
      |> Loans.change_refinance_scenario(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, scenario_changeset: changeset, scenario_form_open?: true)}
  end

  def handle_event(
        "save-scenario",
        %{"refinance_scenario" => params},
        %{assigns: %{current_user: current_user, mortgages: mortgages}} = socket
      ) do
    params = normalize_scenario_rate_params(params)
    mortgage_id = Map.get(params, "mortgage_id") || Map.get(params, :mortgage_id)

    case Loans.create_refinance_scenario(current_user, mortgage_id, params) do
      {:ok, _scenario} ->
        {:noreply,
         socket
         |> load_page(current_user)
         |> assign(
           scenario_form_open?: false,
           scenario_changeset: scenario_changeset(current_user, mortgages),
           fee_changeset: fee_changeset(socket.assigns.scenario_rows)
         )
         |> put_flash(:info, "Refinance scenario saved.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Choose an accessible mortgage before saving.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket,
           scenario_form_open?: true,
           scenario_changeset: Map.put(changeset, :action, :validate)
         )}
    end
  end

  def handle_event("update-what-if", %{"what_if" => params}, socket) do
    form = merge_what_if_form(socket.assigns.what_if_form, params)

    {:noreply,
     assign(socket,
       what_if_form: form,
       what_if_summary: what_if_summary(socket.assigns.selected_mortgage, form)
     )}
  end

  def handle_event("show-analysis-detail", %{"id" => scenario_id}, socket) do
    {:noreply, assign(socket, selected_analysis_scenario_id: scenario_id)}
  end

  def handle_event("hide-analysis-detail", _params, socket) do
    {:noreply, assign(socket, selected_analysis_scenario_id: nil)}
  end

  def handle_event("new-rate-observation", _params, socket) do
    {:noreply,
     assign(socket,
       rate_observation_form_open?: true,
       rate_observation_changeset: rate_observation_changeset()
     )}
  end

  def handle_event("cancel-rate-observation", _params, socket) do
    {:noreply,
     assign(socket,
       rate_observation_form_open?: false,
       rate_observation_changeset: rate_observation_changeset()
     )}
  end

  def handle_event("validate-rate-observation", %{"rate_observation" => params}, socket) do
    changeset =
      params
      |> normalize_rate_observation_rate_params()
      |> rate_observation_changeset()
      |> Map.put(:action, :validate)

    {:noreply,
     assign(socket,
       rate_observation_form_open?: true,
       rate_observation_changeset: changeset
     )}
  end

  def handle_event("save-rate-observation", %{"rate_observation" => params}, socket) do
    params = normalize_rate_observation_rate_params(params)

    with {:ok, source} <- Loans.get_or_create_manual_rate_source(),
         {:ok, _observation} <- Loans.create_rate_observation(source, params) do
      {:noreply,
       socket
       |> load_page(socket.assigns.current_user)
       |> assign(
         rate_observation_form_open?: false,
         rate_observation_changeset: rate_observation_changeset()
       )
       |> put_flash(:info, "Benchmark rate saved.")}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket,
           rate_observation_form_open?: true,
           rate_observation_changeset: Map.put(changeset, :action, :validate)
         )}
    end
  end

  def handle_event(
        "import-rate-source",
        %{"id" => source_id},
        %{assigns: %{current_user: current_user}} = socket
      ) do
    case Loans.process_rate_import_job(source_id) do
      {:ok, %{imported: imported}} ->
        {:noreply,
         socket
         |> load_page(current_user)
         |> put_flash(:info, "Benchmark source imported #{length(imported)} observations.")}

      {:error, :disabled} ->
        {:noreply, put_flash(socket, :error, "Benchmark source is disabled.")}

      {:error, :no_configured_observations} ->
        {:noreply, put_flash(socket, :error, "Benchmark source has no configured observations.")}

      {:error, :missing_api_key} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "FRED_API_KEY is not configured. Add it to the environment before importing FRED benchmarks."
         )}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Benchmark source not found.")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Unable to import benchmark source.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Unable to import benchmark source.")}
    end
  end

  def handle_event(
        "create-scenario-from-rate-observation",
        %{"id" => observation_id},
        %{assigns: %{current_user: current_user, mortgages: mortgages}} = socket
      ) do
    case Loans.create_refinance_scenario_from_rate_observation(
           current_user,
           first_mortgage_id(mortgages),
           observation_id
         ) do
      {:ok, _scenario} ->
        {:noreply,
         socket
         |> load_page(current_user)
         |> put_flash(:info, "Benchmark rate scenario created.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Benchmark rate or loan not found.")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Unable to create scenario from benchmark rate.")}
    end
  end

  def handle_event("new-fee-item", _params, socket) do
    {:noreply,
     assign(socket,
       fee_form_open?: true,
       fee_changeset: fee_changeset(socket.assigns.scenario_rows)
     )}
  end

  def handle_event("cancel-fee-item", _params, socket) do
    {:noreply,
     assign(socket,
       fee_form_open?: false,
       fee_changeset: fee_changeset(socket.assigns.scenario_rows)
     )}
  end

  def handle_event("validate-fee-item", %{"refinance_fee_item" => params}, socket) do
    changeset =
      socket.assigns.scenario_rows
      |> base_fee_item(params)
      |> Loans.change_refinance_fee_item(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, fee_changeset: changeset, fee_form_open?: true)}
  end

  def handle_event(
        "save-fee-item",
        %{"refinance_fee_item" => params},
        %{assigns: %{current_user: current_user}} = socket
      ) do
    scenario_id =
      Map.get(params, "refinance_scenario_id") || Map.get(params, :refinance_scenario_id)

    case Loans.create_refinance_fee_item(current_user, scenario_id, params) do
      {:ok, _fee_item} ->
        {:noreply,
         socket
         |> load_page(current_user)
         |> assign(fee_form_open?: false)
         |> put_flash(:info, "Refinance fee item saved.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Choose an accessible scenario before saving.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket,
           fee_form_open?: true,
           fee_changeset: Map.put(changeset, :action, :validate)
         )}
    end
  end

  def handle_event(
        "run-analysis",
        %{"id" => scenario_id},
        %{assigns: %{current_user: current_user}} = socket
      ) do
    case Loans.analyze_refinance_scenario(current_user, scenario_id) do
      {:ok, _result} ->
        {:noreply,
         socket
         |> load_page(current_user)
         |> put_flash(:info, "Analysis snapshot saved.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Refinance scenario not found.")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Unable to save analysis right now.")}
    end
  end

  def handle_event(
        "new-document",
        _params,
        %{assigns: %{current_user: current_user, mortgages: mortgages}} = socket
      ) do
    {:noreply,
     assign(socket,
       document_form_open?: true,
       document_changeset: document_changeset(current_user, mortgages)
     )}
  end

  def handle_event(
        "cancel-document",
        _params,
        %{assigns: %{current_user: current_user, mortgages: mortgages}} = socket
      ) do
    {:noreply,
     assign(socket,
       document_form_open?: false,
       document_changeset: document_changeset(current_user, mortgages)
     )}
  end

  def handle_event(
        "validate-document",
        %{"loan_document" => params},
        %{assigns: %{current_user: current_user, mortgages: mortgages}} = socket
      ) do
    changeset =
      current_user
      |> base_document(mortgages, params)
      |> Loans.change_loan_document(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, document_changeset: changeset, document_form_open?: true)}
  end

  def handle_event(
        "save-document",
        %{"loan_document" => params},
        %{assigns: %{current_user: current_user, mortgages: mortgages}} = socket
      ) do
    mortgage_id =
      socket.assigns.route_loan_id || Map.get(params, "mortgage_id") ||
        first_mortgage_id(mortgages)

    attrs =
      params
      |> Map.delete("mortgage_id")
      |> Map.merge(uploaded_document_attrs(socket, current_user, mortgage_id))

    case Loans.create_loan_document(current_user, mortgage_id, attrs) do
      {:ok, document} ->
        maybe_enqueue_uploaded_document_extraction(socket, current_user, document, attrs)

        {:noreply,
         socket
         |> load_page(current_user)
         |> assign(
           document_form_open?: false,
           document_changeset: document_changeset(current_user, mortgages)
         )
         |> put_flash(:info, "Loan document metadata saved for review.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Choose an accessible mortgage before saving.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket,
           document_form_open?: true,
           document_changeset: Map.put(changeset, :action, :validate)
         )}
    end
  end

  def handle_event(
        "confirm-extraction",
        %{"id" => extraction_id},
        %{assigns: %{current_user: current_user}} = socket
      ) do
    case Loans.confirm_loan_document_extraction(current_user, extraction_id) do
      {:ok, _extraction} ->
        {:noreply,
         socket
         |> load_page(current_user)
         |> put_flash(:info, "Extraction candidate confirmed for review.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Extraction candidate not found.")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Unable to confirm extraction candidate.")}
    end
  end

  def handle_event(
        "reject-extraction",
        %{"id" => extraction_id},
        %{assigns: %{current_user: current_user}} = socket
      ) do
    case Loans.reject_loan_document_extraction(current_user, extraction_id) do
      {:ok, _extraction} ->
        {:noreply,
         socket
         |> load_page(current_user)
         |> put_flash(:info, "Extraction candidate rejected.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Extraction candidate not found.")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Unable to reject extraction candidate.")}
    end
  end

  def handle_event(
        "apply-extraction",
        %{"id" => extraction_id},
        %{assigns: %{current_user: current_user}} = socket
      ) do
    case Loans.apply_loan_document_extraction_to_mortgage(current_user, extraction_id) do
      {:ok, _mortgage} ->
        {:noreply,
         socket
         |> load_page(current_user)
         |> put_flash(:info, "Confirmed extraction applied to mortgage baseline.")}

      {:error, :not_confirmed} ->
        {:noreply, put_flash(socket, :error, "Confirm the extraction before applying it.")}

      {:error, :no_applicable_fields} ->
        {:noreply, put_flash(socket, :error, "No mortgage fields were found to apply.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Extraction candidate not found.")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Unable to apply extraction candidate.")}
    end
  end

  def handle_event(
        "create-quote-from-extraction",
        %{"id" => extraction_id},
        %{assigns: %{current_user: current_user}} = socket
      ) do
    case Loans.create_lender_quote_from_document_extraction(current_user, extraction_id) do
      {:ok, _quote} ->
        {:noreply,
         socket
         |> load_page(current_user)
         |> put_flash(:info, "Confirmed extraction created a lender quote.")}

      {:error, :not_confirmed} ->
        {:noreply, put_flash(socket, :error, "Confirm the extraction before creating a quote.")}

      {:error, :no_applicable_quote_fields} ->
        {:noreply, put_flash(socket, :error, "No lender quote fields were found to create.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Extraction candidate not found.")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Unable to create lender quote from extraction.")}
    end
  end

  def handle_event(
        "create-scenario-from-extraction",
        %{"id" => extraction_id},
        %{assigns: %{current_user: current_user}} = socket
      ) do
    case Loans.create_refinance_scenario_from_document_extraction(current_user, extraction_id) do
      {:ok, _scenario} ->
        {:noreply,
         socket
         |> load_page(current_user)
         |> put_flash(:info, "Confirmed extraction created a refinance scenario.")}

      {:error, :not_confirmed} ->
        {:noreply,
         put_flash(socket, :error, "Confirm the extraction before creating a scenario.")}

      {:error, :no_applicable_scenario_fields} ->
        {:noreply, put_flash(socket, :error, "No scenario fields were found to create.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Extraction candidate not found.")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Unable to create scenario from extraction.")}
    end
  end

  def handle_event("new-extraction", _params, socket) do
    {:noreply,
     assign(socket,
       extraction_form_open?: true,
       extraction_form: default_extraction_form(socket.assigns.document_rows)
     )}
  end

  def handle_event("new-ollama-extraction", _params, socket) do
    {:noreply,
     assign(socket,
       ollama_extraction_form_open?: true,
       ollama_extraction_form: default_ollama_extraction_form(socket.assigns.document_rows)
     )}
  end

  def handle_event(
        "extract-document",
        %{"id" => document_id},
        %{assigns: %{current_user: current_user}} = socket
      ) do
    case Loans.enqueue_loan_document_extraction(current_user, document_id) do
      {:ok, _job} ->
        {:noreply,
         socket
         |> load_page(current_user)
         |> put_flash(:info, "Document extraction queued for review.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Document not found.")}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Document extraction could not be queued: #{inspect(reason)}")}
    end
  end

  def handle_event("cancel-ollama-extraction", _params, socket) do
    {:noreply,
     assign(socket,
       ollama_extraction_form_open?: false,
       ollama_extraction_form: default_ollama_extraction_form(socket.assigns.document_rows)
     )}
  end

  def handle_event("validate-ollama-extraction", %{"ollama_extraction" => params}, socket) do
    {:noreply,
     assign(socket,
       ollama_extraction_form_open?: true,
       ollama_extraction_form:
         merge_ollama_extraction_form(socket.assigns.ollama_extraction_form, params)
     )}
  end

  def handle_event(
        "run-ollama-extraction",
        %{"ollama_extraction" => params},
        %{assigns: %{current_user: current_user}} = socket
      ) do
    form = merge_ollama_extraction_form(socket.assigns.ollama_extraction_form, params)

    case build_ollama_extraction_input(form) do
      {:ok, document_id, raw_text} ->
        case Loans.create_ollama_loan_document_extraction(current_user, document_id, raw_text) do
          {:ok, _extraction} ->
            {:noreply,
             socket
             |> load_page(current_user)
             |> assign(
               ollama_extraction_form_open?: false,
               ollama_extraction_form:
                 default_ollama_extraction_form(socket.assigns.document_rows)
             )
             |> put_flash(:info, "Ollama extraction candidate added for review.")}

          {:error, :disabled_for_user} ->
            {:noreply,
             socket
             |> assign(ollama_extraction_form_open?: true, ollama_extraction_form: form)
             |> put_flash(
               :error,
               "Enable local AI in settings before running Ollama extraction."
             )}

          {:error, :no_extracted_fields} ->
            {:noreply,
             socket
             |> assign(ollama_extraction_form_open?: true, ollama_extraction_form: form)
             |> put_flash(:error, "Ollama did not return reviewable mortgage fields.")}

          {:error, :not_found} ->
            {:noreply, put_flash(socket, :error, "Choose an accessible document first.")}

          {:error, %Ecto.Changeset{}} ->
            {:noreply, put_flash(socket, :error, "Unable to save Ollama extraction candidate.")}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(ollama_extraction_form_open?: true, ollama_extraction_form: form)
             |> put_flash(:error, "Ollama extraction failed: #{inspect(reason)}")}
        end

      {:error, message} ->
        {:noreply,
         socket
         |> assign(ollama_extraction_form_open?: true, ollama_extraction_form: form)
         |> put_flash(:error, message)}
    end
  end

  def handle_event("cancel-extraction", _params, socket) do
    {:noreply,
     assign(socket,
       extraction_form_open?: false,
       extraction_form: default_extraction_form(socket.assigns.document_rows)
     )}
  end

  def handle_event("validate-extraction", %{"extraction" => params}, socket) do
    {:noreply,
     assign(socket,
       extraction_form_open?: true,
       extraction_form: merge_extraction_form(socket.assigns.extraction_form, params)
     )}
  end

  def handle_event(
        "save-extraction",
        %{"extraction" => params},
        %{assigns: %{current_user: current_user}} = socket
      ) do
    form = merge_extraction_form(socket.assigns.extraction_form, params)

    case build_manual_extraction_attrs(form) do
      {:ok, document_id, attrs} ->
        case Loans.create_loan_document_extraction(current_user, document_id, attrs) do
          {:ok, _extraction} ->
            {:noreply,
             socket
             |> load_page(current_user)
             |> assign(
               extraction_form_open?: false,
               extraction_form: default_extraction_form(socket.assigns.document_rows)
             )
             |> put_flash(:info, "Extraction candidate added for review.")}

          {:error, :not_found} ->
            {:noreply, put_flash(socket, :error, "Choose an accessible document before saving.")}

          {:error, %Ecto.Changeset{}} ->
            {:noreply, put_flash(socket, :error, "Unable to save extraction candidate.")}
        end

      {:error, message} ->
        {:noreply,
         socket
         |> assign(extraction_form_open?: true, extraction_form: form)
         |> put_flash(:error, message)}
    end
  end

  def handle_event(
        "new-quote",
        _params,
        %{assigns: %{current_user: current_user, mortgages: mortgages}} = socket
      ) do
    {:noreply,
     assign(socket,
       quote_form_open?: true,
       quote_changeset: quote_changeset(current_user, mortgages)
     )}
  end

  def handle_event(
        "cancel-quote",
        _params,
        %{assigns: %{current_user: current_user, mortgages: mortgages}} = socket
      ) do
    {:noreply,
     assign(socket,
       quote_form_open?: false,
       quote_changeset: quote_changeset(current_user, mortgages)
     )}
  end

  def handle_event(
        "validate-quote",
        %{"lender_quote" => params},
        %{assigns: %{current_user: current_user, mortgages: mortgages}} = socket
      ) do
    changeset =
      current_user
      |> base_quote(mortgages, params)
      |> Loans.change_lender_quote(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, quote_changeset: changeset, quote_form_open?: true)}
  end

  def handle_event(
        "save-quote",
        %{"lender_quote" => params},
        %{assigns: %{current_user: current_user, mortgages: mortgages}} = socket
      ) do
    mortgage_id =
      socket.assigns.route_loan_id || Map.get(params, "mortgage_id") ||
        first_mortgage_id(mortgages)

    attrs =
      params
      |> Map.delete("mortgage_id")
      |> maybe_put_quote_source_note()

    case Loans.create_lender_quote(current_user, mortgage_id, attrs) do
      {:ok, _quote} ->
        {:noreply,
         socket
         |> load_page(current_user)
         |> assign(
           quote_form_open?: false,
           quote_changeset: quote_changeset(current_user, mortgages)
         )
         |> put_flash(:info, "Lender quote saved.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Choose an accessible mortgage before saving.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket,
           quote_form_open?: true,
           quote_changeset: Map.put(changeset, :action, :validate)
         )}
    end
  end

  def handle_event(
        "refresh-quote-expirations",
        _params,
        %{assigns: %{current_user: current_user, mortgages: mortgages}} = socket
      ) do
    expired_count =
      Enum.reduce(mortgages, 0, fn mortgage, total ->
        case Loans.expire_lender_quotes(current_user, mortgage) do
          {:ok, count} -> total + count
          {:error, _reason} -> total
        end
      end)

    {:noreply,
     socket
     |> load_page(current_user)
     |> put_flash(:info, "Quote freshness refreshed; #{expired_count} quotes expired.")}
  end

  def handle_event(
        "convert-quote",
        %{"id" => quote_id},
        %{assigns: %{current_user: current_user}} = socket
      ) do
    case Loans.convert_lender_quote_to_refinance_scenario(current_user, quote_id) do
      {:ok, _scenario} ->
        {:noreply,
         socket
         |> load_page(current_user)
         |> put_flash(:info, "Lender quote converted to a refinance scenario.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Lender quote not found.")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Unable to convert lender quote.")}
    end
  end

  def handle_event("new-alert-rule", _params, socket) do
    {:noreply,
     assign(socket,
       alert_form_open?: true,
       alert_form: default_alert_form(socket.assigns.mortgages)
     )}
  end

  def handle_event("cancel-alert-rule", _params, socket) do
    {:noreply,
     assign(socket,
       alert_form_open?: false,
       alert_form: default_alert_form(socket.assigns.mortgages)
     )}
  end

  def handle_event("validate-alert-rule", %{"alert_rule" => params}, socket) do
    {:noreply,
     assign(socket,
       alert_form_open?: true,
       alert_form: merge_alert_form(socket.assigns.alert_form, params)
     )}
  end

  def handle_event(
        "save-alert-rule",
        %{"alert_rule" => params},
        %{assigns: %{current_user: current_user, mortgages: mortgages}} = socket
      ) do
    form = merge_alert_form(socket.assigns.alert_form, params)

    mortgage_id =
      socket.assigns.route_loan_id || form["mortgage_id"] || first_mortgage_id(mortgages)

    case build_alert_rule_attrs(form) do
      {:ok, attrs} ->
        case Loans.create_loan_alert_rule(current_user, mortgage_id, attrs) do
          {:ok, _rule} ->
            {:noreply,
             socket
             |> load_page(current_user)
             |> assign(alert_form_open?: false, alert_form: default_alert_form(mortgages))
             |> put_flash(:info, "Loan alert rule saved.")}

          {:error, :not_found} ->
            {:noreply, put_flash(socket, :error, "Choose an accessible mortgage before saving.")}

          {:error, %Ecto.Changeset{}} ->
            {:noreply,
             socket
             |> assign(alert_form_open?: true, alert_form: form)
             |> put_flash(:error, "Unable to save alert rule.")}
        end

      {:error, message} ->
        {:noreply,
         socket
         |> assign(alert_form_open?: true, alert_form: form)
         |> put_flash(:error, message)}
    end
  end

  def handle_event(
        "evaluate-alert-rules",
        _params,
        %{assigns: %{current_user: current_user, route_loan_id: mortgage_id}} = socket
      )
      when is_binary(mortgage_id) do
    case Loans.evaluate_loan_alert_rules(current_user, mortgage_id) do
      {:ok, summary} ->
        {:noreply,
         socket
         |> load_page(current_user)
         |> put_flash(
           :info,
           "Evaluated #{summary.evaluated} alert rules; #{summary.triggered} triggered."
         )}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Loan alert workspace not found.")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Unable to evaluate alert rules.")}
    end
  end

  def handle_event("evaluate-alert-rules", _params, socket) do
    {:noreply, put_flash(socket, :error, "Open a loan workspace before evaluating alerts.")}
  end

  def handle_event(
        "schedule-alert-evaluation",
        _params,
        %{assigns: %{current_user: current_user, route_loan_id: mortgage_id}} = socket
      )
      when is_binary(mortgage_id) do
    case Loans.enqueue_loan_alert_evaluation(current_user, mortgage_id) do
      {:ok, _job} ->
        {:noreply,
         socket
         |> load_page(current_user)
         |> put_flash(:info, "Loan alert evaluation queued.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Loan alert workspace not found.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Unable to queue alert evaluation.")}
    end
  end

  def handle_event("schedule-alert-evaluation", _params, socket) do
    {:noreply, put_flash(socket, :error, "Open a loan workspace before queuing alerts.")}
  end

  def handle_event("select-loan", %{"loan_id" => loan_id}, socket) do
    {:noreply, push_navigate(socket, to: workspace_path(socket.assigns.live_action, loan_id))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="space-y-6">
      <.header
        title="Loan Center"
        subtitle="Mortgage loans are supported first. Additional loan types will be added incrementally."
      >
        <:actions>
          <button type="button" class="btn btn-outline" phx-click="new-mortgage">
            Add mortgage
          </button>
        </:actions>
      </.header>

      <div :if={is_nil(@route_loan_id)} class="rounded-xl border border-zinc-200 bg-white p-5 shadow-sm">
        <p class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">Current loans</p>
        <p class="mt-1 text-2xl font-semibold text-zinc-900"><%= length(@all_mortgages) + length(@generic_loans) %></p>
        <p class="text-xs text-zinc-500">Mortgage records and non-mortgage loan baselines in Loan Center</p>
      </div>

      <div :if={@route_loan_id} class="space-y-4 rounded-xl border border-zinc-200 bg-white p-5 shadow-sm">
        <div :if={@selected_mortgage} class="rounded-xl border border-zinc-100 bg-zinc-50 p-4">
          <div class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
            <div>
              <p class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">Selected loan</p>
              <h2 class="mt-1 text-xl font-semibold text-zinc-900"><%= @selected_mortgage.property_name %></h2>
              <p class="text-sm text-zinc-500">
                <%= @selected_mortgage.loan_type %> • <%= @selected_mortgage.status %>
              </p>
              <button
                type="button"
                class="btn btn-outline mt-3"
                phx-click="edit-mortgage"
                phx-value-id={@selected_mortgage.id}
              >
                Edit loan
              </button>
            </div>

            <dl class="grid gap-3 text-sm sm:grid-cols-4 lg:min-w-[560px]">
              <div>
                <dt class="text-xs font-semibold uppercase tracking-wide text-zinc-500">Balance</dt>
                <dd class="mt-1 font-semibold text-zinc-900"><%= format_currency(@selected_mortgage.current_balance) %></dd>
              </div>
              <div>
                <dt class="text-xs font-semibold uppercase tracking-wide text-zinc-500">Rate</dt>
                <dd class="mt-1 font-semibold text-zinc-900"><%= format_percent(@selected_mortgage.current_interest_rate) %></dd>
              </div>
              <div>
                <dt class="text-xs font-semibold uppercase tracking-wide text-zinc-500">Payment</dt>
                <dd class="mt-1 font-semibold text-zinc-900"><%= format_currency(@selected_mortgage.monthly_payment_total) %></dd>
              </div>
              <div>
                <dt class="text-xs font-semibold uppercase tracking-wide text-zinc-500">Term left</dt>
                <dd class="mt-1 font-semibold text-zinc-900"><%= @selected_mortgage.remaining_term_months %> months</dd>
              </div>
            </dl>
          </div>
        </div>

        <div class="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
          <div>
            <p class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">Loan workspace</p>
            <h2 class="mt-1 text-lg font-semibold text-zinc-900"><%= workspace_title(@live_action) %></h2>
            <p class="text-sm text-zinc-500"><%= workspace_description(@live_action) %></p>
          </div>

          <div class="space-y-3">
            <form phx-change="select-loan" class="min-w-64">
              <label class="text-sm font-medium text-zinc-700" for="loan_workspace_selector">Browse loans</label>
              <select id="loan_workspace_selector" name="loan_id" class="input">
                <%= Phoenix.HTML.Form.options_for_select(mortgage_options(@all_mortgages), @route_loan_id) %>
              </select>
            </form>

            <nav class="flex flex-wrap gap-2 text-sm" aria-label="Loan workspaces">
              <.link navigate={~p"/app/loans/#{@route_loan_id}"} class={workspace_link_class(@live_action, :detail)}>
                Overview
              </.link>
              <.link navigate={~p"/app/loans/#{@route_loan_id}/refinance"} class={workspace_link_class(@live_action, :refinance)}>
                Refinance
              </.link>
              <.link navigate={~p"/app/loans/#{@route_loan_id}/documents"} class={workspace_link_class(@live_action, :documents)}>
                Documents
              </.link>
              <.link navigate={~p"/app/loans/#{@route_loan_id}/quotes"} class={workspace_link_class(@live_action, :quotes)}>
                Lender quotes
              </.link>
              <.link navigate={~p"/app/loans/#{@route_loan_id}/alerts"} class={workspace_link_class(@live_action, :alerts)}>
                Alerts
              </.link>
            </nav>
          </div>
        </div>

        <div :if={@live_action == :alerts} class="grid gap-4 xl:grid-cols-[minmax(0,1.2fr)_minmax(0,0.9fr)]">
          <div class="space-y-3">
            <div class="flex items-center justify-between gap-3">
              <div>
                <h3 class="text-base font-semibold text-zinc-900">Alert rules</h3>
                <p class="text-sm text-zinc-500">Rules create durable MoneyTree notifications when thresholds are met.</p>
              </div>
              <div class="flex gap-2">
                <button type="button" class="btn btn-outline" phx-click="evaluate-alert-rules" disabled={@alert_rows == []}>
                  Evaluate
                </button>
                <button type="button" class="btn btn-outline" phx-click="schedule-alert-evaluation" disabled={@alert_rows == []}>
                  Queue evaluation
                </button>
                <button type="button" class="btn btn-outline" phx-click="new-alert-rule" disabled={@mortgages == []}>
                  Add alert
                </button>
              </div>
            </div>

            <div :if={@alert_rows == []} class="rounded-xl border border-dashed border-zinc-200 p-5 text-sm text-zinc-500">
              Add alert rules for document review, quote expiration, payment, savings, break-even, or full-term cost thresholds.
            </div>

            <div :if={@alert_rows != []} class="overflow-x-auto">
              <table class="min-w-full divide-y divide-zinc-200 text-sm">
                <thead>
                  <tr class="text-left text-xs font-semibold uppercase tracking-wide text-zinc-500">
                    <th class="px-3 py-2">Rule</th>
                    <th class="px-3 py-2">Kind</th>
                    <th class="px-3 py-2">Threshold</th>
                    <th class="px-3 py-2">Cooldown</th>
                    <th class="px-3 py-2">Delivery</th>
                    <th class="px-3 py-2">Last evaluated</th>
                    <th class="px-3 py-2">Last triggered</th>
                    <th class="px-3 py-2">State</th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-zinc-100">
                  <tr :for={row <- @alert_rows} class="text-zinc-700">
                    <td class="px-3 py-3 font-medium text-zinc-900"><%= row.rule.name %></td>
                    <td class="px-3 py-3"><%= format_label(row.rule.kind) %></td>
                    <td class="px-3 py-3"><%= alert_threshold_label(row.rule) %></td>
                    <td class="px-3 py-3"><%= alert_cooldown_label(row.rule) %></td>
                    <td class="px-3 py-3"><%= alert_delivery_label(row.rule) %></td>
                    <td class="px-3 py-3"><%= format_datetime(row.rule.last_evaluated_at) || "Never" %></td>
                    <td class="px-3 py-3"><%= format_datetime(row.rule.last_triggered_at) || "Never" %></td>
                    <td class="px-3 py-3"><%= if row.rule.active, do: "Active", else: "Inactive" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>

          <div class="space-y-4 rounded-xl border border-zinc-100 bg-zinc-50 p-4">
            <div class="flex items-start justify-between gap-3">
              <div>
                <h3 class="text-base font-semibold text-zinc-900">Add alert rule</h3>
                <p class="text-sm text-zinc-500">Threshold rules are evaluated against current scenarios and review queues.</p>
              </div>
              <button :if={@alert_form_open?} type="button" class="btn btn-outline" phx-click="cancel-alert-rule">
                Cancel
              </button>
            </div>

            <div :if={!@alert_form_open?} class="rounded-xl border border-dashed border-zinc-200 bg-white p-5 text-sm text-zinc-500">
              Add an alert rule after selecting a mortgage-backed loan workspace.
            </div>

            <form :if={@alert_form_open?}
                  id="loan-alert-rule-form"
                  class="space-y-4"
                  phx-change="validate-alert-rule"
                  phx-submit="save-alert-rule">
              <input type="hidden" name="alert_rule[mortgage_id]" value={@alert_form["mortgage_id"] || first_mortgage_id(@mortgages)} />

              <div>
                <label class="text-sm font-medium text-zinc-700" for="alert_rule_name">Name</label>
                <input id="alert_rule_name" class="input" name="alert_rule[name]" value={@alert_form["name"]} />
              </div>

              <div>
                <label class="text-sm font-medium text-zinc-700" for="alert_rule_kind">Kind</label>
                <select id="alert_rule_kind" name="alert_rule[kind]" class="input">
                  <%= Phoenix.HTML.Form.options_for_select(alert_kind_options(), @alert_form["kind"]) %>
                </select>
              </div>

              <div :if={alert_uses_threshold?(@alert_form["kind"])}>
                <label class="text-sm font-medium text-zinc-700" for="alert_rule_threshold_value">
                  <%= alert_threshold_label_for_kind(@alert_form["kind"]) %>
                </label>
                <input id="alert_rule_threshold_value" class="input" name="alert_rule[threshold_value]" value={@alert_form["threshold_value"]} />
              </div>

              <div :if={@alert_form["kind"] == "lender_quote_expiring"}>
                <label class="text-sm font-medium text-zinc-700" for="alert_rule_lead_days">Lead days</label>
                <input id="alert_rule_lead_days" class="input" name="alert_rule[lead_days]" type="number" min="0" value={@alert_form["lead_days"]} />
              </div>

              <div>
                <label class="text-sm font-medium text-zinc-700" for="alert_rule_cooldown_hours">Cooldown hours</label>
                <input id="alert_rule_cooldown_hours" class="input" name="alert_rule[cooldown_hours]" type="number" min="0" value={@alert_form["cooldown_hours"]} />
              </div>

              <div>
                <label class="text-sm font-medium text-zinc-700" for="alert_rule_active">State</label>
                <select id="alert_rule_active" name="alert_rule[active]" class="input">
                  <%= Phoenix.HTML.Form.options_for_select([{"Active", "true"}, {"Inactive", "false"}], @alert_form["active"]) %>
                </select>
              </div>

              <div class="flex justify-end gap-2">
                <button type="button" class="btn btn-outline" phx-click="cancel-alert-rule">Cancel</button>
                <button type="submit" class="btn">Save alert</button>
              </div>
            </form>
          </div>
        </div>

        <div :if={@live_action == :quotes} class="grid gap-4 xl:grid-cols-[minmax(0,1.2fr)_minmax(0,0.9fr)]">
          <div class="space-y-3">
            <div class="flex items-center justify-between gap-3">
              <div>
                <h3 class="text-base font-semibold text-zinc-900">Lender quote tracker</h3>
                <p class="text-sm text-zinc-500">Quotes are stored separately from benchmark rate estimates.</p>
              </div>
              <div class="flex flex-wrap justify-end gap-2">
                <button type="button" class="btn btn-outline" phx-click="refresh-quote-expirations" disabled={@mortgages == []}>
                  Refresh expirations
                </button>
                <button type="button" class="btn btn-outline" phx-click="new-quote" disabled={@mortgages == []}>
                  Add lender quote
                </button>
              </div>
            </div>

            <div :if={@quote_rows == []} class="rounded-xl border border-dashed border-zinc-200 p-5 text-sm text-zinc-500">
              Refinance lender quotes will appear here with payment, cost, lock, and expiration details.
            </div>

            <div :if={@quote_rows != []} class="overflow-x-auto">
              <table class="min-w-full divide-y divide-zinc-200 text-sm">
                <thead>
                  <tr class="text-left text-xs font-semibold uppercase tracking-wide text-zinc-500">
                    <th class="px-3 py-2">Lender</th>
                    <th class="px-3 py-2">Product</th>
                    <th class="px-3 py-2">Rate / APR</th>
                    <th class="px-3 py-2">Payment</th>
                    <th class="px-3 py-2">Costs</th>
                    <th class="px-3 py-2">Lock</th>
                    <th class="px-3 py-2">Expires</th>
                    <th class="px-3 py-2">Freshness</th>
                    <th class="px-3 py-2">Status</th>
                    <th class="px-3 py-2"></th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-zinc-100">
                  <tr :for={row <- @quote_rows} class="text-zinc-700">
                    <td class="px-3 py-3 font-medium text-zinc-900"><%= row.quote.lender_name %></td>
                    <td class="px-3 py-3">
                      <%= format_label(row.quote.product_type || row.quote.loan_type) %>
                      <span class="block text-xs text-zinc-500"><%= row.quote.term_months %> months</span>
                    </td>
                    <td class="px-3 py-3">
                      <%= format_percent(row.quote.interest_rate) %>
                      <span :if={row.quote.apr} class="block text-xs text-zinc-500">
                        APR <%= format_percent(row.quote.apr) %>
                      </span>
                    </td>
                    <td class="px-3 py-3"><%= format_currency(row.quote.estimated_monthly_payment_expected) %></td>
                    <td class="px-3 py-3">
                      <%= format_currency(row.quote.estimated_closing_costs_expected) %>
                      <span :if={row.quote.estimated_cash_to_close_expected} class="block text-xs text-zinc-500">
                        Cash <%= format_currency(row.quote.estimated_cash_to_close_expected) %>
                      </span>
                    </td>
                    <td class="px-3 py-3"><%= quote_lock_status(row.quote) %></td>
                    <td class="px-3 py-3"><%= format_datetime(row.quote.quote_expires_at) || "Not set" %></td>
                    <td class="px-3 py-3"><%= quote_freshness_label(row.quote) %></td>
                    <td class="px-3 py-3"><%= format_label(row.quote.status) %></td>
                    <td class="px-3 py-3 text-right">
                      <button type="button"
                              class="btn btn-outline"
                              phx-click="convert-quote"
                              phx-value-id={row.quote.id}
                              disabled={quote_convert_disabled?(row.quote)}>
                        Convert to scenario
                      </button>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>

          <div class="space-y-4 rounded-xl border border-zinc-100 bg-zinc-50 p-4">
            <div class="flex items-start justify-between gap-3">
              <div>
                <h3 class="text-base font-semibold text-zinc-900">Refinance lender quote</h3>
                <p class="text-sm text-zinc-500">Record lender-specific refinance terms, then convert the quote to a scenario when ready.</p>
              </div>
              <button :if={@quote_form_open?} type="button" class="btn btn-outline" phx-click="cancel-quote">
                Cancel
              </button>
            </div>

            <div :if={!@quote_form_open?} class="rounded-xl border border-dashed border-zinc-200 bg-white p-5 text-sm text-zinc-500">
              Add a quote after selecting a mortgage-backed loan workspace.
            </div>

            <.simple_form :if={@quote_form_open?}
                          for={@quote_changeset}
                          id="lender-quote-form"
                          phx-change="validate-quote"
                          phx-submit="save-quote"
                          :let={f}>
              <input type="hidden" name="lender_quote[mortgage_id]" value={f[:mortgage_id].value || first_mortgage_id(@mortgages)} />

              <div class="grid gap-4">
                <.input field={f[:lender_name]} label="Lender name" />
                <.input field={f[:quote_reference]} label="Quote reference" />

                <div class="grid gap-4 sm:grid-cols-2">
                  <div>
                    <label class="text-sm font-medium text-zinc-700" for="lender_quote_quote_source">Quote source</label>
                    <select id="lender_quote_quote_source" name="lender_quote[quote_source]" class="input">
                      <%= Phoenix.HTML.Form.options_for_select(quote_source_options(), f[:quote_source].value || "manual") %>
                    </select>
                  </div>
                  <.input field={f[:product_type]} label="Product type" />
                  <.input field={f[:term_months]} label="Term months" type={:number} min="1" />
                  <.input field={f[:interest_rate]} label="Interest rate" type={:number} step="0.0001" min="0" />
                  <.input field={f[:apr]} label="APR" type={:number} step="0.0001" min="0" />
                  <.input field={f[:points]} label="Points" type={:number} step="0.0001" min="0" />
                </div>

                <div class="grid gap-4 sm:grid-cols-2">
                  <.input field={f[:lender_credit_amount]} label="Lender credit" type={:number} step="0.01" min="0" />
                  <.input field={f[:estimated_monthly_payment_expected]} label="Expected payment" type={:number} step="0.01" min="0" />
                  <.input field={f[:estimated_closing_costs_expected]} label="Expected closing costs" type={:number} step="0.01" min="0" />
                  <.input field={f[:estimated_cash_to_close_expected]} label="Expected cash to close" type={:number} step="0.01" min="0" />
                </div>

                <div class="grid gap-4 sm:grid-cols-2">
                  <div>
                    <label class="text-sm font-medium text-zinc-700" for="lender_quote_lock_available">Rate lock</label>
                    <select id="lender_quote_lock_available" name="lender_quote[lock_available]" class="input">
                      <%= Phoenix.HTML.Form.options_for_select([{"No lock", "false"}, {"Lock available", "true"}], f[:lock_available].value || "false") %>
                    </select>
                  </div>
                  <.input field={f[:quote_expires_at]} label="Quote expires at" placeholder="2026-06-01T00:00:00Z" />
                </div>

                <div>
                  <label class="text-sm font-medium text-zinc-700" for="lender_quote_status">Status</label>
                  <select id="lender_quote_status" name="lender_quote[status]" class="input">
                    <%= Phoenix.HTML.Form.options_for_select(quote_status_options(), f[:status].value || "active") %>
                  </select>
                </div>

                <div>
                  <label class="text-sm font-medium text-zinc-700" for="lender_quote_source_note">Source note</label>
                  <textarea id="lender_quote_source_note" class="input min-h-24" name="lender_quote[source_note]"></textarea>
                </div>
              </div>

              <div class="flex justify-end gap-2">
                <button type="button" class="btn btn-outline" phx-click="cancel-quote">Cancel</button>
                <button type="submit" class="btn">Save lender quote</button>
              </div>
            </.simple_form>
          </div>
        </div>

        <div :if={@live_action == :documents} class="grid gap-4 xl:grid-cols-[minmax(0,1.25fr)_minmax(0,0.9fr)]">
          <div class="space-y-3">
            <div class="flex items-center justify-between gap-3">
              <h3 class="text-base font-semibold text-zinc-900">Document review queue</h3>
              <button type="button" class="btn btn-outline" phx-click="new-document" disabled={@mortgages == []}>
                Add document
              </button>
            </div>

            <div :if={@document_rows == []} class="rounded-xl border border-dashed border-zinc-200 p-5 text-sm text-zinc-500">
              Document metadata will appear here before extraction candidates can be reviewed.
            </div>

            <div :if={@document_rows != []} class="overflow-x-auto">
              <table class="min-w-full divide-y divide-zinc-200 text-sm">
                <thead>
                  <tr class="text-left text-xs font-semibold uppercase tracking-wide text-zinc-500">
                    <th class="px-3 py-2">Document</th>
                    <th class="px-3 py-2">Type</th>
                    <th class="px-3 py-2">Status</th>
                    <th class="px-3 py-2">Extractions</th>
                    <th class="px-3 py-2">Uploaded</th>
                    <th class="px-3 py-2">Actions</th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-zinc-100">
                  <tr :for={row <- @document_rows} class="text-zinc-700">
                    <td class="px-3 py-3 font-medium text-zinc-900"><%= row.document.original_filename %></td>
                    <td class="px-3 py-3"><%= format_label(row.document.document_type) %></td>
                    <td class="px-3 py-3"><%= format_label(row.document.status) %></td>
                    <td class="px-3 py-3"><%= extraction_summary(row.document.extractions) %></td>
                    <td class="px-3 py-3"><%= format_datetime(row.document.uploaded_at) %></td>
                    <td class="px-3 py-3">
                      <button type="button"
                              class="btn btn-outline"
                              phx-click="extract-document"
                              phx-value-id={row.document.id}
                              disabled={!stored_document?(row.document)}>
                        Run extraction
                      </button>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <div :if={@document_rows != []} class="space-y-3 border-t border-zinc-100 pt-4">
              <div class="flex items-center justify-between gap-3">
                <h3 class="text-base font-semibold text-zinc-900">Extraction candidates</h3>
                <div class="flex gap-2">
                  <button type="button" class="btn btn-outline" phx-click="new-ollama-extraction">
                    Generate with Ollama
                  </button>
                  <button type="button" class="btn btn-outline" phx-click="new-extraction">
                    Add extraction candidate
                  </button>
                </div>
              </div>

              <div :if={extraction_rows(@document_rows) == []} class="rounded-xl border border-dashed border-zinc-200 p-5 text-sm text-zinc-500">
                Extracted fields will appear here for confirmation before any canonical record changes.
              </div>

              <div :for={candidate <- extraction_rows(@document_rows)} class="rounded-xl border border-zinc-100 bg-zinc-50 p-4">
                <div class="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
                  <div class="space-y-1">
                    <p class="font-medium text-zinc-900"><%= candidate.document.original_filename %></p>
                    <p class="text-xs text-zinc-500">
                      <%= format_label(candidate.extraction.extraction_method) %> •
                      <%= format_label(candidate.extraction.status) %>
                    </p>
                    <p :if={candidate.extraction.model_name} class="text-xs text-zinc-500">
                      Model <%= candidate.extraction.model_name %>
                    </p>
                  </div>

                  <div class="flex flex-wrap justify-end gap-2">
                    <button type="button"
                            class="btn btn-outline"
                            phx-click="confirm-extraction"
                            phx-value-id={candidate.extraction.id}
                            disabled={!extraction_pending_review?(candidate.extraction)}>
                      Confirm extraction
                    </button>
                    <button type="button"
                            class="btn btn-outline"
                            phx-click="reject-extraction"
                            phx-value-id={candidate.extraction.id}
                            disabled={extraction_rejected?(candidate.extraction)}>
                      Reject extraction
                    </button>
                    <button type="button"
                            class="btn btn-outline"
                            phx-click="apply-extraction"
                            phx-value-id={candidate.extraction.id}
                            disabled={!extraction_confirmed?(candidate.extraction)}>
                      Apply to mortgage
                    </button>
                    <button type="button"
                            class="btn btn-outline"
                            phx-click="create-quote-from-extraction"
                            phx-value-id={candidate.extraction.id}
                            disabled={!extraction_confirmed?(candidate.extraction)}>
                      Create lender quote
                    </button>
                    <button type="button"
                            class="btn btn-outline"
                            phx-click="create-scenario-from-extraction"
                            phx-value-id={candidate.extraction.id}
                            disabled={!extraction_confirmed?(candidate.extraction)}>
                      Create scenario
                    </button>
                  </div>
                </div>

                <dl class="mt-3 grid gap-2 text-sm sm:grid-cols-2">
                  <div :for={{field, value} <- payload_fields(candidate.extraction.extracted_payload)} class="rounded-lg bg-white px-3 py-2">
                    <dt class="flex items-center justify-between gap-2 text-xs font-semibold uppercase tracking-wide text-zinc-500">
                      <span><%= format_label(field) %></span>
                      <span :if={field_confidence(candidate.extraction.field_confidence, field)} class="font-medium normal-case tracking-normal text-emerald-700">
                        <%= field_confidence(candidate.extraction.field_confidence, field) %>
                      </span>
                    </dt>
                    <dd class="mt-1 text-zinc-900"><%= format_payload_value(value) %></dd>
                    <dd :if={field_citations(candidate.extraction.source_citations, field) != []} class="mt-2 space-y-1 text-xs text-zinc-500">
                      <p :for={citation <- field_citations(candidate.extraction.source_citations, field)}>
                        <%= citation %>
                      </p>
                    </dd>
                  </div>
                </dl>

                <div :if={extraction_review_context?(candidate.extraction)} class="mt-3 rounded-lg border border-zinc-100 bg-white p-3 text-sm">
                  <div :if={stored_text_artifact(candidate.extraction)} class="text-xs text-zinc-500">
                    <span class="font-semibold uppercase tracking-wide">Stored text artifact</span>
                    <span class="break-all"><%= stored_text_artifact(candidate.extraction) %></span>
                  </div>

                  <details :if={stored_text_excerpt(candidate.extraction)} class="mt-2">
                    <summary class="cursor-pointer text-xs font-semibold uppercase tracking-wide text-zinc-500">
                      Stored extracted text
                    </summary>
                    <pre class="mt-2 max-h-64 overflow-auto whitespace-pre-wrap rounded-md bg-zinc-50 p-3 text-xs leading-5 text-zinc-700"><%= stored_text_excerpt(candidate.extraction) %></pre>
                  </details>

                  <details :if={raw_text_excerpt(candidate.extraction)} class="mt-2">
                    <summary class="cursor-pointer text-xs font-semibold uppercase tracking-wide text-zinc-500">
                      Extracted text excerpt
                    </summary>
                    <pre class="mt-2 max-h-48 overflow-auto whitespace-pre-wrap rounded-md bg-zinc-50 p-3 text-xs leading-5 text-zinc-700"><%= raw_text_excerpt(candidate.extraction) %></pre>
                  </details>
                </div>
              </div>
            </div>
          </div>

          <div class="space-y-4 rounded-xl border border-zinc-100 bg-zinc-50 p-4">
            <div class="flex items-start justify-between gap-3">
              <div>
                <h3 class="text-base font-semibold text-zinc-900">Add document metadata</h3>
                <p class="text-sm text-zinc-500">Record source metadata before extraction and review.</p>
              </div>
              <button :if={@document_form_open?} type="button" class="btn btn-outline" phx-click="cancel-document">
                Cancel
              </button>
            </div>

            <div :if={!@document_form_open?} class="rounded-xl border border-dashed border-zinc-200 bg-white p-5 text-sm text-zinc-500">
              Add document metadata after selecting a mortgage-backed loan workspace.
            </div>

            <.simple_form :if={@document_form_open?}
                          for={@document_changeset}
                          id="loan-document-form"
                          phx-change="validate-document"
                          phx-submit="save-document"
                          :let={f}>
              <input type="hidden" name="loan_document[mortgage_id]" value={f[:mortgage_id].value || first_mortgage_id(@mortgages)} />
              <div class="grid gap-4">
                <div>
                  <label class="text-sm font-medium text-zinc-700">Document file</label>
                  <.live_file_input upload={@uploads.loan_document_file} class="w-full text-sm text-zinc-700" />
                  <p :for={entry <- @uploads.loan_document_file.entries} class="mt-1 text-xs text-zinc-500">
                    <%= entry.client_name %> • <%= entry.client_type %>
                  </p>
                  <p :for={error <- upload_errors(@uploads.loan_document_file)} class="text-sm text-red-600">
                    <%= upload_error_message(error) %>
                  </p>
                </div>

                <div>
                  <label class="text-sm font-medium text-zinc-700" for="loan_document_document_type">Document type</label>
                  <select id="loan_document_document_type" name="loan_document[document_type]" class="input">
                    <%= Phoenix.HTML.Form.options_for_select(document_type_options(), f[:document_type].value || "loan_estimate") %>
                  </select>
                  <p :for={error <- errors_on(@document_changeset, :document_type)} class="text-sm text-red-600"><%= error %></p>
                </div>

                <.input field={f[:original_filename]} label="Original filename" />
                <.input field={f[:content_type]} label="Content type" />
                <.input field={f[:byte_size]} label="Byte size" type={:number} min="1" />
                <.input field={f[:storage_key]} label="Storage key" />
                <.input field={f[:checksum_sha256]} label="SHA-256 checksum" />
              </div>

              <div class="flex justify-end gap-2">
                <button type="button" class="btn btn-outline" phx-click="cancel-document">Cancel</button>
                <button type="submit" class="btn">Save document</button>
              </div>
            </.simple_form>

            <div class="border-t border-zinc-200 pt-4">
              <div class="flex items-start justify-between gap-3">
                <div>
                  <h3 class="text-base font-semibold text-zinc-900">Generate with Ollama</h3>
                  <p class="text-sm text-zinc-500">Paste OCR or statement text to create a review-only candidate.</p>
                </div>
                <button :if={@ollama_extraction_form_open?} type="button" class="btn btn-outline" phx-click="cancel-ollama-extraction">
                  Cancel
                </button>
              </div>

              <div :if={!@ollama_extraction_form_open?} class="mt-4 rounded-xl border border-dashed border-zinc-200 bg-white p-5 text-sm text-zinc-500">
                Ollama extraction uses local AI settings and still requires user confirmation before persistence to the mortgage baseline.
              </div>

              <form :if={@ollama_extraction_form_open?}
                    id="loan-document-ollama-extraction-form"
                    class="mt-4 space-y-4"
                    phx-change="validate-ollama-extraction"
                    phx-submit="run-ollama-extraction">
                <div>
                  <label class="text-sm font-medium text-zinc-700" for="ollama_extraction_loan_document_id">Document</label>
                  <select id="ollama_extraction_loan_document_id" name="ollama_extraction[loan_document_id]" class="input">
                    <%= Phoenix.HTML.Form.options_for_select(document_options(@document_rows), @ollama_extraction_form["loan_document_id"]) %>
                  </select>
                </div>

                <div>
                  <label class="text-sm font-medium text-zinc-700" for="ollama_extraction_raw_text">Document text</label>
                  <textarea id="ollama_extraction_raw_text" class="input min-h-40" name="ollama_extraction[raw_text]"><%= @ollama_extraction_form["raw_text"] %></textarea>
                </div>

                <div class="flex justify-end gap-2">
                  <button type="button" class="btn btn-outline" phx-click="cancel-ollama-extraction">Cancel</button>
                  <button type="submit" class="btn">Generate candidate</button>
                </div>
              </form>
            </div>

            <div class="border-t border-zinc-200 pt-4">
              <div class="flex items-start justify-between gap-3">
                <div>
                  <h3 class="text-base font-semibold text-zinc-900">Add extraction candidate</h3>
                  <p class="text-sm text-zinc-500">Enter a reviewable field from a document without applying it.</p>
                </div>
                <button :if={@extraction_form_open?} type="button" class="btn btn-outline" phx-click="cancel-extraction">
                  Cancel
                </button>
              </div>

              <div :if={!@extraction_form_open?} class="mt-4 rounded-xl border border-dashed border-zinc-200 bg-white p-5 text-sm text-zinc-500">
                Add an extraction candidate after recording document metadata.
              </div>

              <form :if={@extraction_form_open?}
                    id="loan-document-extraction-form"
                    class="mt-4 space-y-4"
                    phx-change="validate-extraction"
                    phx-submit="save-extraction">
                <div>
                  <label class="text-sm font-medium text-zinc-700" for="extraction_loan_document_id">Document</label>
                  <select id="extraction_loan_document_id" name="extraction[loan_document_id]" class="input">
                    <%= Phoenix.HTML.Form.options_for_select(document_options(@document_rows), @extraction_form["loan_document_id"]) %>
                  </select>
                </div>

                <div class="grid gap-4 sm:grid-cols-2">
                  <div>
                    <label class="text-sm font-medium text-zinc-700" for="extraction_field_name">Field name</label>
                    <input id="extraction_field_name" class="input" name="extraction[field_name]" value={@extraction_form["field_name"]} />
                  </div>
                  <div>
                    <label class="text-sm font-medium text-zinc-700" for="extraction_field_value">Field value</label>
                    <input id="extraction_field_value" class="input" name="extraction[field_value]" value={@extraction_form["field_value"]} />
                  </div>
                  <div>
                    <label class="text-sm font-medium text-zinc-700" for="extraction_confidence">Confidence</label>
                    <input id="extraction_confidence" class="input" name="extraction[confidence]" value={@extraction_form["confidence"]} placeholder="0.90" />
                  </div>
                  <div>
                    <label class="text-sm font-medium text-zinc-700" for="extraction_model_name">Model/source</label>
                    <input id="extraction_model_name" class="input" name="extraction[model_name]" value={@extraction_form["model_name"]} />
                  </div>
                </div>

                <div>
                  <label class="text-sm font-medium text-zinc-700" for="extraction_source_note">Source note</label>
                  <textarea id="extraction_source_note" class="input min-h-24" name="extraction[source_note]"><%= @extraction_form["source_note"] %></textarea>
                </div>

                <div class="flex justify-end gap-2">
                  <button type="button" class="btn btn-outline" phx-click="cancel-extraction">Cancel</button>
                  <button type="submit" class="btn">Save extraction candidate</button>
                </div>
              </form>
            </div>
          </div>
        </div>
      </div>

      <div :if={@live_action == :refinance && @selected_mortgage} class="space-y-4 rounded-xl border border-zinc-200 bg-white p-5 shadow-sm">
        <div>
          <h2 class="text-lg font-semibold text-zinc-900">What-if sandbox</h2>
          <p class="text-sm text-zinc-500">
            Estimate-only sliders. Changes are not saved and do not update the mortgage record.
          </p>
        </div>

        <form id="mortgage-what-if-form" class="grid gap-5 lg:grid-cols-[minmax(0,0.9fr)_minmax(0,1.1fr)]" phx-change="update-what-if">
          <div class="space-y-5 rounded-xl border border-zinc-100 bg-zinc-50 p-4">
            <div>
              <div class="flex items-center justify-between gap-3">
                <label class="text-sm font-medium text-zinc-700" for="what_if_rate_percent">Interest rate</label>
                <span class="text-sm font-semibold text-zinc-900"><%= @what_if_form["rate_percent"] %>%</span>
              </div>
              <input
                id="what_if_rate_percent"
                name="what_if[rate_percent]"
                type="range"
                min="0"
                max="15"
                step="0.125"
                value={@what_if_form["rate_percent"]}
                class="mt-2 w-full"
              />
            </div>

            <div>
              <div class="flex items-center justify-between gap-3">
                <label class="text-sm font-medium text-zinc-700" for="what_if_term_months">Loan term</label>
                <span class="text-sm font-semibold text-zinc-900"><%= @what_if_form["term_months"] %> months</span>
              </div>
              <input
                id="what_if_term_months"
                name="what_if[term_months]"
                type="range"
                min="12"
                max="480"
                step="12"
                value={@what_if_form["term_months"]}
                class="mt-2 w-full"
              />
            </div>

            <div>
              <div class="flex items-center justify-between gap-3">
                <label class="text-sm font-medium text-zinc-700" for="what_if_extra_monthly_principal">Extra principal</label>
                <span class="text-sm font-semibold text-zinc-900"><%= format_currency_string(@what_if_form["extra_monthly_principal"]) %> / mo</span>
              </div>
              <input
                id="what_if_extra_monthly_principal"
                name="what_if[extra_monthly_principal]"
                type="range"
                min="0"
                max="5000"
                step="25"
                value={@what_if_form["extra_monthly_principal"]}
                class="mt-2 w-full"
              />
            </div>
          </div>

          <div class="grid gap-3 sm:grid-cols-2">
            <div class="rounded-xl border border-zinc-100 bg-zinc-50 p-4">
              <p class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">Monthly payment</p>
              <p class="mt-1 text-xl font-semibold text-zinc-900"><%= format_currency(@what_if_summary.scheduled_monthly_payment) %></p>
              <p class="text-xs text-zinc-500">Principal and interest only</p>
            </div>
            <div class="rounded-xl border border-zinc-100 bg-zinc-50 p-4">
              <p class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">Payoff timeline</p>
              <p class="mt-1 text-xl font-semibold text-zinc-900"><%= format_months(@what_if_summary.payoff_months) %></p>
              <p class="text-xs text-zinc-500">With extra monthly principal</p>
            </div>
            <div class="rounded-xl border border-zinc-100 bg-zinc-50 p-4">
              <p class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">Total mortgage sum</p>
              <p class="mt-1 text-xl font-semibold text-zinc-900"><%= format_currency(@what_if_summary.total_paid) %></p>
              <p class="text-xs text-zinc-500">Principal and interest over payoff</p>
            </div>
            <div class="rounded-xl border border-zinc-100 bg-zinc-50 p-4">
              <p class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">Total interest</p>
              <p class="mt-1 text-xl font-semibold text-zinc-900"><%= format_currency(@what_if_summary.total_interest) %></p>
              <p class="text-xs text-zinc-500">Interest saved <%= format_currency(@what_if_summary.interest_saved) %></p>
            </div>
          </div>
        </form>
      </div>

      <div :if={@live_action == :refinance} class="space-y-4 rounded-xl border border-zinc-200 bg-white p-5 shadow-sm">
        <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
          <div>
            <h2 class="text-lg font-semibold text-zinc-900">Market rate snapshot</h2>
            <p class="text-sm text-zinc-500">
              National benchmarks provide context for refinance assumptions. They are not personalized lender offers.
            </p>
          </div>
          <p class="text-xs text-zinc-500">
            Updated <%= format_date(@market_snapshot.quality.latest_effective_date) || "Not imported" %>
          </p>
        </div>

        <div :if={@market_snapshot.quality.warnings != []} class="rounded-lg border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-800">
          <p :for={warning <- @market_snapshot.quality.warnings}><%= warning %></p>
        </div>

        <div class="grid gap-3 md:grid-cols-2 xl:grid-cols-4">
          <div class="rounded-xl border border-zinc-100 bg-zinc-50 p-4">
            <p class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">30-year national average</p>
            <p class="mt-1 text-xl font-semibold text-zinc-900"><%= market_rate_value(@market_snapshot, "mortgage30us") %></p>
            <p class="text-xs text-zinc-500"><%= market_trend_label(@market_snapshot, "mortgage30us", 90) %></p>
          </div>
          <div class="rounded-xl border border-zinc-100 bg-zinc-50 p-4">
            <p class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">15-year national average</p>
            <p class="mt-1 text-xl font-semibold text-zinc-900"><%= market_rate_value(@market_snapshot, "mortgage15us") %></p>
            <p class="text-xs text-zinc-500"><%= market_trend_label(@market_snapshot, "mortgage15us", 90) %></p>
          </div>
          <div class="rounded-xl border border-zinc-100 bg-zinc-50 p-4">
            <p class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">10-year treasury</p>
            <p class="mt-1 text-xl font-semibold text-zinc-900"><%= market_rate_value(@market_snapshot, "gs10") %></p>
            <p class="text-xs text-zinc-500"><%= market_trend_label(@market_snapshot, "gs10", 30) %></p>
          </div>
          <div class="rounded-xl border border-zinc-100 bg-zinc-50 p-4">
            <p class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">Market explanation</p>
            <p class="mt-1 text-sm font-medium text-zinc-900"><%= market_explanation(@market_snapshot) %></p>
            <p class="text-xs text-zinc-500">Structured benchmark interpretation</p>
          </div>
        </div>

        <p class="text-xs text-zinc-500">
          Source: <%= market_snapshot_attribution(@market_snapshot) %>. Your actual offer may vary based on credit score, LTV, points, lender fees, loan size, location, and lock period.
        </p>

        <p class="rounded-lg border border-zinc-100 bg-zinc-50 px-3 py-2 text-xs text-zinc-500">
          This product uses the FRED® API but is not endorsed or certified by the Federal Reserve Bank of St. Louis.
        </p>
      </div>

      <div :if={@live_action == :refinance} class={refinance_split_class(@rate_observation_form_open?)}>
        <div class="space-y-4 rounded-xl border border-zinc-200 bg-white p-5 shadow-sm">
          <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
            <div>
              <h2 class="text-lg font-semibold text-zinc-900">Benchmark rates</h2>
              <p class="text-sm text-zinc-500">Rate observations are estimates and can seed editable refinance scenarios.</p>
            </div>
            <div class="flex flex-wrap gap-2">
              <button type="button" class="btn btn-outline" phx-click="new-rate-observation">
                Add benchmark rate
              </button>
            </div>
          </div>

          <div :if={@rate_source_rows != []} class="rounded-xl border border-zinc-100 bg-zinc-50 p-4">
            <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
              <div>
                <h3 class="text-sm font-semibold text-zinc-900">Benchmark sources</h3>
                <p class="text-sm text-zinc-500">Configured public benchmark sources import estimate rows for scenario seeding.</p>
              </div>
            </div>

            <div class="mt-3 grid gap-2">
              <div :for={source <- @rate_source_rows} class="flex flex-col gap-3 rounded-lg bg-white px-3 py-3 sm:flex-row sm:items-center sm:justify-between">
                <div>
                  <p class="font-medium text-zinc-900"><%= source.name %></p>
                  <p class="text-xs text-zinc-500">
                    <%= format_label(source.source_type) %> • <%= rate_source_import_status(source) %>
                  </p>
                </div>
                <button
                  type="button"
                  class="btn btn-outline"
                  phx-click="import-rate-source"
                  phx-value-id={source.id}
                >
                  Import benchmarks
                </button>
              </div>
            </div>
          </div>

          <div :if={@rate_observation_rows == []} class="rounded-xl border border-dashed border-zinc-200 p-6 text-center text-sm text-zinc-500">
            Add a manual benchmark rate to compare estimated refinance scenarios against lender quotes.
          </div>

          <div :if={@rate_observation_rows != []} class="overflow-x-auto">
            <table class="min-w-full divide-y divide-zinc-200 text-sm">
              <thead>
                <tr class="text-left text-xs font-semibold uppercase tracking-wide text-zinc-500">
                  <th class="px-3 py-2">Product</th>
                  <th class="px-3 py-2">Term</th>
                  <th class="px-3 py-2">Rate / APR</th>
                  <th class="px-3 py-2">Points</th>
                  <th class="px-3 py-2">Observed</th>
                  <th class="px-3 py-2">Source</th>
                  <th class="px-3 py-2"></th>
                </tr>
              </thead>
              <tbody class="divide-y divide-zinc-100">
                <tr :for={observation <- @rate_observation_rows} class="text-zinc-700">
                  <td class="px-3 py-3"><%= format_label(observation.product_type || observation.loan_type) %></td>
                  <td class="px-3 py-3"><%= observation.term_months %> months</td>
                  <td class="px-3 py-3">
                    <%= format_percent(observation.rate) %>
                    <span :if={observation.apr} class="block text-xs text-zinc-500">
                      APR <%= format_percent(observation.apr) %>
                    </span>
                  </td>
                  <td class="px-3 py-3"><%= format_decimal(observation.points) %></td>
                  <td class="px-3 py-3"><%= format_date(observation.effective_date) %></td>
                  <td class="px-3 py-3"><%= rate_source_label(observation) %></td>
                  <td class="px-3 py-3 text-right">
                    <button
                      type="button"
                      class="btn btn-outline"
                      phx-click="create-scenario-from-rate-observation"
                      phx-value-id={observation.id}
                      disabled={@mortgages == []}
                    >
                      Create scenario
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <div :if={@rate_observation_form_open?} class="space-y-4 rounded-xl border border-zinc-200 bg-white p-5 shadow-sm">
          <div class="flex items-start justify-between gap-3">
            <div>
              <h2 class="text-lg font-semibold text-zinc-900">Add benchmark rate</h2>
              <p class="text-sm text-zinc-500">Manual benchmark rates are estimates, not lender offers.</p>
            </div>
            <button type="button" class="btn btn-outline" phx-click="cancel-rate-observation">
              Cancel
            </button>
          </div>

          <.simple_form for={@rate_observation_changeset}
                        id="rate-observation-form"
                        phx-change="validate-rate-observation"
                        phx-submit="save-rate-observation"
                        :let={f}>
            <input type="hidden" name="rate_observation[loan_type]" value="mortgage" />

            <div class="grid gap-4">
              <div class="grid gap-4 sm:grid-cols-2">
                <.input field={f[:product_type]} label="Product type" />
                <.input field={f[:term_months]} label="Term months" type={:number} min="1" />
              </div>

              <div class="grid gap-4 sm:grid-cols-2">
                <div>
                  <label class="text-sm font-medium text-zinc-700" for="rate_observation_rate_percent">Rate (%)</label>
                  <input
                    id="rate_observation_rate_percent"
                    name="rate_observation[rate_percent]"
                    class="input"
                    type="number"
                    step="0.0001"
                    min="0"
                    value={rate_observation_rate_percent_value(@rate_observation_changeset, :rate)}
                  />
                  <p :for={error <- errors_on(@rate_observation_changeset, :rate)} class="text-sm text-red-600"><%= error %></p>
                </div>

                <div>
                  <label class="text-sm font-medium text-zinc-700" for="rate_observation_apr_percent">APR (%)</label>
                  <input
                    id="rate_observation_apr_percent"
                    name="rate_observation[apr_percent]"
                    class="input"
                    type="number"
                    step="0.0001"
                    min="0"
                    value={rate_observation_rate_percent_value(@rate_observation_changeset, :apr)}
                  />
                  <p :for={error <- errors_on(@rate_observation_changeset, :apr)} class="text-sm text-red-600"><%= error %></p>
                </div>
              </div>

              <.input field={f[:points]} label="Points" type={:number} step="0.0001" min="0" />
            </div>

            <div class="flex justify-end gap-2">
              <button type="button" class="btn btn-outline" phx-click="cancel-rate-observation">Cancel</button>
              <button type="submit" class="btn">Save benchmark rate</button>
            </div>
          </.simple_form>
        </div>
      </div>

      <div :if={@live_action == :refinance} class="grid gap-6 xl:grid-cols-[minmax(0,1.35fr)_minmax(0,1fr)]">
        <div class="space-y-4 rounded-xl border border-zinc-200 bg-white p-5 shadow-sm">
          <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
            <div>
              <h2 class="text-lg font-semibold text-zinc-900">Refinance analysis</h2>
              <p class="text-sm text-zinc-500">Compare payment, break-even, and full-term cost.</p>
            </div>
            <div class="flex gap-2">
              <button type="button" class="btn btn-outline" phx-click="new-scenario" disabled={@mortgages == []}>
                Add scenario
              </button>
              <button type="button" class="btn btn-outline" phx-click="new-fee-item" disabled={@scenario_rows == []}>
                Add fee item
              </button>
            </div>
          </div>

          <div :if={@scenario_rows == []} class="rounded-xl border border-dashed border-zinc-200 p-6 text-center text-sm text-zinc-500">
            Save a refinance scenario to compare expected monthly payment, break-even, and full-term cost.
          </div>

          <div :if={@scenario_rows != []} class="grid gap-3 md:grid-cols-3">
            <.refinance_metric
              label="Lowest expected payment"
              value={metric_payment_value(@scenario_rows)}
              row={lowest_expected_payment_row(@scenario_rows)}
            />
            <.refinance_metric
              label="Fastest break-even"
              value={metric_break_even_value(@scenario_rows)}
              row={fastest_break_even_row(@scenario_rows)}
            />
            <.refinance_metric
              label="Lowest full-term delta"
              value={metric_full_term_delta_value(@scenario_rows)}
              row={lowest_full_term_delta_row(@scenario_rows)}
            />
          </div>

          <div :if={@scenario_rows != []} class="overflow-x-auto">
            <table class="min-w-full divide-y divide-zinc-200 text-sm">
              <thead>
                <tr class="text-left text-xs font-semibold uppercase tracking-wide text-zinc-500">
                  <th class="px-3 py-2">Scenario</th>
                  <th class="px-3 py-2">Loan</th>
                  <th class="px-3 py-2">Term</th>
                  <th class="px-3 py-2">Rate</th>
                  <th class="px-3 py-2">Payment range</th>
                  <th class="px-3 py-2">Savings range</th>
                  <th class="px-3 py-2">True cost range</th>
                  <th class="px-3 py-2">Cash to close range</th>
                  <th class="px-3 py-2">Break-even range</th>
                  <th class="px-3 py-2">Full-term delta</th>
                  <th class="px-3 py-2">Warnings</th>
                  <th class="px-3 py-2"></th>
                </tr>
              </thead>
              <tbody class="divide-y divide-zinc-100">
                <tr :for={row <- @scenario_rows} class="text-zinc-700">
                  <td class="px-3 py-3 font-medium text-zinc-900"><%= row.scenario.name %></td>
                  <td class="px-3 py-3"><%= row.mortgage.property_name %></td>
                  <td class="px-3 py-3"><%= row.scenario.new_term_months %> months</td>
                  <td class="px-3 py-3"><%= format_percent(row.scenario.new_interest_rate) %></td>
                  <td class="px-3 py-3"><.range_value range={row.analysis.payment_range} /></td>
                  <td class="px-3 py-3"><.range_value range={row.analysis.monthly_savings_range} /></td>
                  <td class="px-3 py-3"><.range_value range={row.analysis.true_refinance_cost_range} /></td>
                  <td class="px-3 py-3"><.range_value range={row.analysis.cash_to_close_range} /></td>
                  <td class="px-3 py-3"><.range_value range={row.analysis.break_even_range} kind={:months} /></td>
                  <td class="px-3 py-3"><%= format_currency(row.analysis.full_term_finance_cost_delta) %></td>
                  <td class="px-3 py-3"><.warning_status warnings={row.analysis.warnings} /></td>
                  <td class="px-3 py-3 text-right">
                    <div class="flex justify-end gap-2">
                      <button type="button"
                              class="btn btn-outline"
                              phx-click="show-analysis-detail"
                              phx-value-id={row.scenario.id}>
                        View details
                      </button>
                      <button type="button"
                              class="btn btn-outline"
                              phx-click="run-analysis"
                              phx-value-id={row.scenario.id}>
                        Save analysis
                      </button>
                    </div>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <div :if={@scenario_rows != [] && @selected_analysis_scenario_id == nil} class="rounded-xl border border-dashed border-zinc-200 p-5 text-sm text-zinc-500">
            Select “View details” on a scenario to review full-term totals, assumptions, and warnings.
          </div>

          <div :for={row <- selected_analysis_rows(@scenario_rows, @selected_analysis_scenario_id)} class="space-y-4 border-t border-zinc-100 pt-4">
            <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
              <div>
                <h3 class="text-base font-semibold text-zinc-900">Analysis details</h3>
                <p class="text-sm text-zinc-500">
                  <%= row.scenario.name %> full-term totals and assumptions.
                </p>
              </div>
              <button type="button" class="btn btn-outline" phx-click="hide-analysis-detail">Close details</button>
            </div>

            <div class="space-y-4">
              <div class="flex flex-col gap-1 sm:flex-row sm:items-baseline sm:justify-between">
                <h4 class="font-semibold text-zinc-900"><%= row.scenario.name %></h4>
                <p class="text-xs text-zinc-500">
                  <%= row.scenario.new_term_months %> months at <%= format_percent(row.scenario.new_interest_rate) %>
                </p>
              </div>

              <div class="grid gap-3 sm:grid-cols-3">
                <div class="rounded-lg border border-zinc-200 bg-zinc-50 p-4">
                  <p class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">Expected payment</p>
                  <p class="mt-1 text-xl font-semibold text-zinc-900"><%= format_currency(row.analysis.payment_range.expected) %></p>
                </div>
                <div class="rounded-lg border border-zinc-200 bg-zinc-50 p-4">
                  <p class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">Expected break-even</p>
                  <p class="mt-1 text-xl font-semibold text-zinc-900"><%= format_months(row.analysis.break_even_range.expected) %></p>
                </div>
                <div class="rounded-lg border border-zinc-200 bg-zinc-50 p-4">
                  <p class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">Full-term delta</p>
                  <p class="mt-1 text-xl font-semibold text-zinc-900"><%= format_currency(row.analysis.full_term_finance_cost_delta) %></p>
                </div>
              </div>

              <div class="grid gap-4 lg:grid-cols-3">
                <div>
                  <p class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">Core outputs</p>
                  <dl class="mt-2 space-y-2 text-sm">
                    <div class="flex justify-between gap-4">
                      <dt class="text-zinc-500">Current payment</dt>
                      <dd class="font-medium text-zinc-900"><%= format_currency(row.analysis.current_monthly_payment) %></dd>
                    </div>
                    <div class="flex justify-between gap-4">
                      <dt class="text-zinc-500">New payment range</dt>
                      <dd class="min-w-44 font-medium text-zinc-900"><.range_value range={row.analysis.payment_range} /></dd>
                    </div>
                    <div class="flex justify-between gap-4">
                      <dt class="text-zinc-500">Savings range</dt>
                      <dd class="min-w-44 font-medium text-zinc-900"><.range_value range={row.analysis.monthly_savings_range} /></dd>
                    </div>
                    <div class="flex justify-between gap-4">
                      <dt class="text-zinc-500">Break-even range</dt>
                      <dd class="min-w-44 font-medium text-zinc-900"><.range_value range={row.analysis.break_even_range} kind={:months} /></dd>
                    </div>
                  </dl>
                </div>

                <div>
                  <p class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">Full-term cost</p>
                  <dl class="mt-2 space-y-2 text-sm">
                    <div class="flex justify-between gap-4">
                      <dt class="text-zinc-500">Current full-term total</dt>
                      <dd class="font-medium text-zinc-900"><%= format_currency(row.analysis.current_full_term_total_payment) %></dd>
                    </div>
                    <div class="flex justify-between gap-4">
                      <dt class="text-zinc-500">Current full-term interest</dt>
                      <dd class="font-medium text-zinc-900"><%= format_currency(row.analysis.current_full_term_interest_cost) %></dd>
                    </div>
                    <div class="flex justify-between gap-4">
                      <dt class="text-zinc-500">New full-term total</dt>
                      <dd class="font-medium text-zinc-900"><%= format_currency(row.analysis.new_full_term_total_payment) %></dd>
                    </div>
                    <div class="flex justify-between gap-4">
                      <dt class="text-zinc-500">New full-term interest</dt>
                      <dd class="font-medium text-zinc-900"><%= format_currency(row.analysis.new_full_term_interest_cost) %></dd>
                    </div>
                    <div class="flex justify-between gap-4">
                      <dt class="text-zinc-500">Full-term delta</dt>
                      <dd class="font-medium text-zinc-900"><%= format_currency(row.analysis.full_term_finance_cost_delta) %></dd>
                    </div>
                  </dl>
                </div>

                <div>
                  <p class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">Assumptions and warnings</p>
                  <dl class="mt-2 space-y-2 text-sm">
                    <div class="flex justify-between gap-4">
                      <dt class="text-zinc-500">True refinance cost</dt>
                      <dd class="font-medium text-zinc-900"><%= format_currency(row.analysis.true_refinance_cost) %></dd>
                    </div>
                    <div class="flex justify-between gap-4">
                      <dt class="text-zinc-500">Cash timing cost</dt>
                      <dd class="font-medium text-zinc-900"><%= format_currency(row.analysis.cash_to_close_timing_cost) %></dd>
                    </div>
                    <div class="flex justify-between gap-4">
                      <dt class="text-zinc-500">Cash to close range</dt>
                      <dd class="min-w-44 font-medium text-zinc-900"><.range_value range={row.analysis.cash_to_close_range} /></dd>
                    </div>
                  </dl>

                  <div :if={row.analysis.warnings != []} class="mt-3 rounded-lg border border-amber-200 bg-amber-50 p-3">
                    <p class="text-xs font-semibold uppercase tracking-wide text-amber-800">Review needed</p>
                    <ul class="mt-2 space-y-1 text-sm text-amber-800">
                      <li :for={warning <- row.analysis.warnings}><%= warning %></li>
                    </ul>
                  </div>
                  <p :if={row.analysis.warnings == []} class="mt-3 rounded-lg border border-zinc-200 bg-zinc-50 p-3 text-sm text-zinc-500">
                    No warnings for this scenario.
                  </p>
                </div>
              </div>
            </div>
          </div>
        </div>

        <div :if={@scenario_form_open?} class="space-y-4 rounded-xl border border-zinc-200 bg-white p-5 shadow-sm">
          <div class="flex items-start justify-between gap-3">
            <div>
              <h2 class="text-lg font-semibold text-zinc-900">Add scenario</h2>
              <p class="text-sm text-zinc-500">Save rate, term, and principal assumptions.</p>
            </div>
            <button type="button" class="btn btn-outline" phx-click="cancel-scenario">
              Cancel
            </button>
          </div>

          <.simple_form for={@scenario_changeset}
                        id="refinance-scenario-form"
                        phx-change="validate-scenario"
                        phx-submit="save-scenario"
                        :let={f}>
            <div class="grid gap-4">
              <div>
                <label class="text-sm font-medium text-zinc-700" for="refinance_scenario_mortgage_id">Mortgage</label>
                <select id="refinance_scenario_mortgage_id" name="refinance_scenario[mortgage_id]" class="input">
                  <%= Phoenix.HTML.Form.options_for_select(mortgage_options(@mortgages), f[:mortgage_id].value || first_mortgage_id(@mortgages)) %>
                </select>
                <p :for={error <- errors_on(@scenario_changeset, :mortgage_id)} class="text-sm text-red-600"><%= error %></p>
              </div>

              <.input field={f[:name]} label="Scenario name" />
              <.input field={f[:product_type]} label="Product type" />

              <div class="grid gap-4 sm:grid-cols-2">
                <.input field={f[:new_term_months]} label="New term months" type={:number} min="1" />
                <div>
                  <label class="text-sm font-medium text-zinc-700" for="refinance_scenario_new_interest_rate_percent">New interest rate (%)</label>
                  <input
                    id="refinance_scenario_new_interest_rate_percent"
                    name="refinance_scenario[new_interest_rate_percent]"
                    class="input"
                    type="number"
                    step="0.0001"
                    min="0"
                    value={scenario_rate_percent_value(@scenario_changeset, :new_interest_rate)}
                  />
                  <p class="mt-1 text-xs text-zinc-500">Example: enter 5.5 for 5.5%.</p>
                  <p :for={error <- errors_on(@scenario_changeset, :new_interest_rate)} class="text-sm text-red-600"><%= error %></p>
                </div>
                <.input field={f[:new_principal_amount]} label="New principal amount" type={:number} step="0.01" min="0" />
                <div>
                  <label class="text-sm font-medium text-zinc-700" for="refinance_scenario_new_apr_percent">APR (%)</label>
                  <input
                    id="refinance_scenario_new_apr_percent"
                    name="refinance_scenario[new_apr_percent]"
                    class="input"
                    type="number"
                    step="0.0001"
                    min="0"
                    value={scenario_rate_percent_value(@scenario_changeset, :new_apr)}
                  />
                  <p :for={error <- errors_on(@scenario_changeset, :new_apr)} class="text-sm text-red-600"><%= error %></p>
                </div>
              </div>

              <div class="grid gap-4 sm:grid-cols-2">
                <.input field={f[:points]} label="Points" type={:number} step="0.0001" min="0" />
                <.input field={f[:lender_credit_amount]} label="Lender credit" type={:number} step="0.01" min="0" />
              </div>
            </div>

            <div class="flex justify-end gap-2">
              <button type="button" class="btn btn-outline" phx-click="cancel-scenario">Cancel</button>
              <button type="submit" class="btn">Save scenario</button>
            </div>
          </.simple_form>
        </div>
      </div>

      <div :if={@live_action == :refinance} class={refinance_split_class(@fee_form_open?)}>
        <div class="space-y-4 rounded-xl border border-zinc-200 bg-white p-5 shadow-sm">
          <div>
            <h2 class="text-lg font-semibold text-zinc-900">Cost assumptions</h2>
            <p class="text-sm text-zinc-500">Track true refinance costs separately from prepaid and escrow timing costs.</p>
          </div>

          <div :if={@scenario_rows == []} class="rounded-xl border border-dashed border-zinc-200 p-6 text-center text-sm text-zinc-500">
            Fee items can be added after saving a refinance scenario.
          </div>

          <ul :if={@scenario_rows != []} class="space-y-3">
            <li :for={row <- @scenario_rows} class="rounded-xl border border-zinc-100 bg-zinc-50 p-4">
              <div class="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
                <div>
                  <p class="font-semibold text-zinc-900"><%= row.scenario.name %></p>
                  <p class="text-xs text-zinc-500">
                    <%= length(row.scenario.fee_items || []) %> fee items
                  </p>
                </div>
                <div class="text-left sm:text-right">
                  <p class="text-sm font-medium text-zinc-900">
                    True cost <%= format_currency(row.true_refinance_cost) %>
                  </p>
                  <p class="text-xs text-zinc-500">
                    Cash to close <%= format_currency(row.cash_to_close) %>
                  </p>
                </div>
              </div>
            </li>
          </ul>
        </div>

        <div :if={@fee_form_open?} class="space-y-4 rounded-xl border border-zinc-200 bg-white p-5 shadow-sm">
          <div class="flex items-start justify-between gap-3">
            <div>
              <h2 class="text-lg font-semibold text-zinc-900">Add fee item</h2>
              <p class="text-sm text-zinc-500">Classify each amount for break-even and cash-to-close math.</p>
            </div>
            <button type="button" class="btn btn-outline" phx-click="cancel-fee-item">
              Cancel
            </button>
          </div>

          <.simple_form for={@fee_changeset}
                        id="refinance-fee-item-form"
                        phx-change="validate-fee-item"
                        phx-submit="save-fee-item"
                        :let={f}>
            <div class="grid gap-4">
              <div>
                <label class="text-sm font-medium text-zinc-700" for="refinance_fee_item_refinance_scenario_id">Scenario</label>
                <select id="refinance_fee_item_refinance_scenario_id" name="refinance_fee_item[refinance_scenario_id]" class="input">
                  <%= Phoenix.HTML.Form.options_for_select(scenario_options(@scenario_rows), f[:refinance_scenario_id].value || first_scenario_id(@scenario_rows)) %>
                </select>
                <p :for={error <- errors_on(@fee_changeset, :refinance_scenario_id)} class="text-sm text-red-600"><%= error %></p>
              </div>

              <div class="grid gap-4 sm:grid-cols-2">
                <.input field={f[:name]} label="Name" />
                <.input field={f[:category]} label="Category" />
                <.input field={f[:expected_amount]} label="Expected amount" type={:number} step="0.01" min="0" />
                <.input field={f[:sort_order]} label="Sort order" type={:number} min="0" />
              </div>

              <div>
                <label class="text-sm font-medium text-zinc-700" for="refinance_fee_item_kind">Kind</label>
                <select id="refinance_fee_item_kind" name="refinance_fee_item[kind]" class="input">
                  <%= Phoenix.HTML.Form.options_for_select(fee_kind_options(), f[:kind].value || "fee") %>
                </select>
                <p :for={error <- errors_on(@fee_changeset, :kind)} class="text-sm text-red-600"><%= error %></p>
              </div>

              <div>
                <label class="text-sm font-medium text-zinc-700" for="refinance_fee_item_is_true_cost">Break-even treatment</label>
                <select id="refinance_fee_item_is_true_cost" name="refinance_fee_item[is_true_cost]" class="input">
                  <%= Phoenix.HTML.Form.options_for_select([{"True refinance cost", "true"}, {"Not a true cost", "false"}], f[:is_true_cost].value || "true") %>
                </select>
                <p :for={error <- errors_on(@fee_changeset, :is_true_cost)} class="text-sm text-red-600"><%= error %></p>
              </div>

              <div>
                <label class="text-sm font-medium text-zinc-700" for="refinance_fee_item_is_prepaid_or_escrow">Cash timing treatment</label>
                <select id="refinance_fee_item_is_prepaid_or_escrow" name="refinance_fee_item[is_prepaid_or_escrow]" class="input">
                  <%= Phoenix.HTML.Form.options_for_select([{"Not prepaid or escrow", "false"}, {"Prepaid or escrow timing", "true"}], f[:is_prepaid_or_escrow].value || "false") %>
                </select>
                <p :for={error <- errors_on(@fee_changeset, :is_prepaid_or_escrow)} class="text-sm text-red-600"><%= error %></p>
              </div>
            </div>

            <div class="flex justify-end gap-2">
              <button type="button" class="btn btn-outline" phx-click="cancel-fee-item">Cancel</button>
              <button type="submit" class="btn">Save fee item</button>
            </div>
          </.simple_form>
        </div>
      </div>

      <div :if={@live_action == :refinance} class="space-y-4 rounded-xl border border-zinc-200 bg-white p-5 shadow-sm">
        <div>
          <h2 class="text-lg font-semibold text-zinc-900">Analysis history</h2>
          <p class="text-sm text-zinc-500">Saved deterministic snapshots for reproducible refinance comparisons.</p>
        </div>

        <div :if={@analysis_history_rows == []} class="rounded-xl border border-dashed border-zinc-200 p-6 text-center text-sm text-zinc-500">
          Save an analysis from the scenario table to create a historical snapshot.
        </div>

        <div :if={@analysis_history_rows != []} class="overflow-x-auto">
          <table class="min-w-full divide-y divide-zinc-200 text-sm">
            <thead>
              <tr class="text-left text-xs font-semibold uppercase tracking-wide text-zinc-500">
                <th class="px-3 py-2">Scenario</th>
                <th class="px-3 py-2">Saved</th>
                <th class="px-3 py-2">Expected payment</th>
                <th class="px-3 py-2">Break-even</th>
                <th class="px-3 py-2">True cost</th>
                <th class="px-3 py-2">Cash to close</th>
                <th class="px-3 py-2">Full-term delta</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-zinc-100">
              <tr :for={row <- @analysis_history_rows} class="text-zinc-700">
                <td class="px-3 py-3 font-medium text-zinc-900"><%= row.scenario_name %></td>
                <td class="px-3 py-3"><%= format_datetime(row.result.computed_at) %></td>
                <td class="px-3 py-3"><%= format_currency(row.result.new_monthly_payment_expected) %></td>
                <td class="px-3 py-3"><%= format_months(row.result.break_even_months_expected) %></td>
                <td class="px-3 py-3"><%= format_currency(row.result.true_refinance_cost_expected) %></td>
                <td class="px-3 py-3"><%= format_currency(row.result.cash_to_close_expected) %></td>
                <td class="px-3 py-3"><%= format_currency(row.result.full_term_finance_cost_delta_expected) %></td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <div :if={is_nil(@route_loan_id) || @live_action == :detail} class="grid gap-6 xl:grid-cols-[minmax(0,1.35fr)_minmax(0,1fr)]">
        <div class="space-y-4 rounded-xl border border-zinc-200 bg-white p-5 shadow-sm">
          <h2 class="text-lg font-semibold text-zinc-900">Mortgage details</h2>

          <ul :if={@mortgages != []} class="space-y-3">
            <li :for={mortgage <- @mortgages} class="rounded-xl border border-zinc-100 bg-zinc-50 p-4">
              <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
                <div>
                  <p class="font-semibold text-zinc-900"><%= mortgage.property_name %></p>
                  <p class="text-xs text-zinc-500">
                    <%= mortgage.loan_type %> • <%= mortgage.status %>
                  </p>
                  <div class="mt-3 flex flex-wrap gap-2 text-xs">
                    <.link navigate={~p"/app/loans/#{mortgage.id}"} class="rounded-full border border-zinc-200 bg-white px-3 py-1 font-medium text-zinc-700 hover:bg-zinc-50">
                      Open workspace
                    </.link>
                    <.link navigate={~p"/app/loans/#{mortgage.id}/refinance"} class="rounded-full border border-zinc-200 bg-white px-3 py-1 font-medium text-zinc-700 hover:bg-zinc-50">
                      Refinance
                    </.link>
                    <.link navigate={~p"/app/loans/#{mortgage.id}/quotes"} class="rounded-full border border-zinc-200 bg-white px-3 py-1 font-medium text-zinc-700 hover:bg-zinc-50">
                      Lender quotes
                    </.link>
                    <.link navigate={~p"/app/loans/#{mortgage.id}/documents"} class="rounded-full border border-zinc-200 bg-white px-3 py-1 font-medium text-zinc-700 hover:bg-zinc-50">
                      Documents
                    </.link>
                    <button
                      type="button"
                      class="rounded-full border border-zinc-200 bg-white px-3 py-1 font-medium text-zinc-700 hover:bg-zinc-50"
                      phx-click="edit-mortgage"
                      phx-value-id={mortgage.id}
                    >
                      Edit loan
                    </button>
                  </div>
                </div>

                <div class="text-left sm:text-right">
                  <p class="font-semibold text-zinc-900"><%= format_currency(mortgage.current_balance) %></p>
                  <p class="text-xs text-zinc-500">
                    Payment <%= format_currency(mortgage.monthly_payment_total) %> •
                    <%= mortgage.remaining_term_months %> months left
                  </p>
                </div>
              </div>
            </li>
          </ul>

          <div :if={@mortgages == []} class="rounded-xl border border-dashed border-zinc-200 p-6 text-center">
            <p class="text-sm text-zinc-500">
              No mortgage records yet. Add a mortgage baseline to start Loan Center analysis.
            </p>
            <button type="button" class="btn mt-4" phx-click="new-mortgage">Add mortgage baseline</button>
          </div>
        </div>

        <div class="space-y-4 rounded-xl border border-zinc-200 bg-white p-5 shadow-sm">
          <div class="flex items-start justify-between gap-3">
            <div>
              <h2 class="text-lg font-semibold text-zinc-900">Other loans</h2>
              <p class="text-sm text-zinc-500">Auto, personal, and student loan baselines use generic payoff analysis.</p>
            </div>
            <button type="button" class="btn btn-outline" phx-click="new-generic-loan">
              Add non-mortgage loan
            </button>
          </div>

          <ul :if={@generic_loans != []} class="space-y-3">
            <li :for={loan <- @generic_loans} class="rounded-xl border border-zinc-100 bg-zinc-50 p-4">
              <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
                <div>
                  <p class="font-semibold text-zinc-900"><%= loan.name %></p>
                  <p class="text-xs text-zinc-500">
                    <%= format_label(loan.loan_type) %> • <%= loan.status %>
                  </p>
                  <p :if={loan.collateral_description} class="mt-1 text-xs text-zinc-500">
                    <%= loan.collateral_description %>
                  </p>
                </div>
                <div class="text-left sm:text-right">
                  <p class="font-semibold text-zinc-900"><%= format_currency(loan.current_balance) %></p>
                  <p class="text-xs text-zinc-500">
                    Payment <%= format_currency(loan.monthly_payment_total) %> •
                    <%= loan.remaining_term_months %> months left
                  </p>
                </div>
              </div>

              <div class="mt-4 rounded-lg border border-zinc-200 bg-white p-3">
                <p class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">Refinance preview</p>
                <%= case generic_loan_preview(loan) do %>
                  <% {:ok, analysis} -> %>
                    <dl class="mt-2 grid gap-3 text-sm sm:grid-cols-3">
                      <div>
                        <dt class="text-xs text-zinc-500">Expected payment</dt>
                        <dd class="font-semibold text-zinc-900"><%= format_currency(analysis.payment_range.expected) %></dd>
                      </div>
                      <div>
                        <dt class="text-xs text-zinc-500">Expected savings</dt>
                        <dd class="font-semibold text-zinc-900"><%= format_currency(analysis.monthly_savings_range.expected) %></dd>
                      </div>
                      <div>
                        <dt class="text-xs text-zinc-500">Full-term delta</dt>
                        <dd class="font-semibold text-zinc-900"><%= format_currency(analysis.full_term_finance_cost_delta) %></dd>
                      </div>
                    </dl>
                  <% {:error, _changeset} -> %>
                    <p class="mt-2 text-sm text-zinc-500">Preview unavailable for this loan baseline.</p>
                <% end %>
              </div>
            </li>
          </ul>

          <div :if={@generic_loans == []} class="rounded-xl border border-dashed border-zinc-200 p-6 text-center text-sm text-zinc-500">
            Add an auto, personal, or student loan baseline to compare payment changes without mortgage-specific fields.
          </div>
        </div>

        <div class="space-y-4 rounded-xl border border-zinc-200 bg-white p-5 shadow-sm">
          <div class="flex items-start justify-between gap-3">
            <div>
              <h2 class="text-lg font-semibold text-zinc-900"><%= mortgage_form_title(@mortgage_form_mode) %></h2>
              <p class="text-sm text-zinc-500"><%= mortgage_form_description(@mortgage_form_mode) %></p>
            </div>
            <button :if={@mortgage_form_open?} type="button" class="btn btn-outline" phx-click="cancel-mortgage">
              Cancel
            </button>
          </div>

          <div :if={!@mortgage_form_open?} class="rounded-xl border border-dashed border-zinc-200 p-6 text-center text-sm text-zinc-500">
            Select “Edit loan” on an existing loan or add a new mortgage baseline here.
          </div>

          <.simple_form :if={@mortgage_form_open?}
                        for={@mortgage_changeset}
                        id="mortgage-form"
                        phx-change="validate-mortgage"
                        phx-submit="save-mortgage"
                        :let={f}>
            <div class="grid gap-4">
              <.input field={f[:property_name]} label="Property name" />
              <.input field={f[:nickname]} label="Nickname" />
              <.input field={f[:loan_type]} label="Loan type" />
              <.input field={f[:lender_name]} label="Lender" />
              <.input field={f[:servicer_name]} label="Servicer" />

              <div class="grid gap-4 sm:grid-cols-2">
                <.input field={f[:current_balance]} label="Current balance" type={:number} step="0.01" min="0" />
                <div>
                  <label class="text-sm font-medium text-zinc-700" for="mortgage_current_interest_rate_percent">
                    Current interest rate (%)
                  </label>
                  <input
                    id="mortgage_current_interest_rate_percent"
                    name="mortgage[current_interest_rate_percent]"
                    class="input"
                    type="number"
                    step="0.0001"
                    min="0"
                    value={mortgage_rate_percent_value(@mortgage_changeset, :current_interest_rate)}
                  />
                  <p class="mt-1 text-xs text-zinc-500">Example: enter 7.125 for 7.125%.</p>
                  <p :for={error <- errors_on(@mortgage_changeset, :current_interest_rate)} class="text-sm text-red-600"><%= error %></p>
                </div>
                <.input field={f[:remaining_term_months]} label="Remaining term months" type={:number} min="1" />
                <.input field={f[:monthly_payment_total]} label="Monthly payment" type={:number} step="0.01" min="0" />
              </div>

              <div class="grid gap-4 sm:grid-cols-2">
                <.input field={f[:monthly_principal_interest]} label="Monthly principal & interest" type={:number} step="0.01" min="0" />
                <.input field={f[:home_value_estimate]} label="Home value estimate" type={:number} step="0.01" min="0" />
              </div>

              <div>
                <label class="text-sm font-medium text-zinc-700" for="mortgage_has_escrow">Escrow</label>
                <select id="mortgage_has_escrow" name="mortgage[has_escrow]" class="input">
                  <%= Phoenix.HTML.Form.options_for_select([{"No escrow", "false"}, {"Has escrow", "true"}], f[:has_escrow].value || "false") %>
                </select>
                <p :for={error <- errors_on(@mortgage_changeset, :has_escrow)} class="text-sm text-red-600"><%= error %></p>
              </div>

              <div>
                <label class="text-sm font-medium text-zinc-700" for="mortgage_escrow_included_in_payment">Payment includes escrow</label>
                <select id="mortgage_escrow_included_in_payment" name="mortgage[escrow_included_in_payment]" class="input">
                  <%= Phoenix.HTML.Form.options_for_select([{"No", "false"}, {"Yes", "true"}], f[:escrow_included_in_payment].value || "false") %>
                </select>
                <p :for={error <- errors_on(@mortgage_changeset, :escrow_included_in_payment)} class="text-sm text-red-600"><%= error %></p>
              </div>
            </div>

            <div class="flex justify-end gap-2">
              <button type="button" class="btn btn-outline" phx-click="cancel-mortgage">Cancel</button>
              <button type="submit" class="btn"><%= mortgage_form_submit_label(@mortgage_form_mode) %></button>
            </div>
          </.simple_form>
        </div>

        <div :if={@generic_loan_form_open?} class="space-y-4 rounded-xl border border-zinc-200 bg-white p-5 shadow-sm">
          <div class="flex items-start justify-between gap-3">
            <div>
              <h2 class="text-lg font-semibold text-zinc-900">Add non-mortgage loan</h2>
              <p class="text-sm text-zinc-500">Create a generic loan baseline for auto, personal, or student debt.</p>
            </div>
            <button type="button" class="btn btn-outline" phx-click="cancel-generic-loan">
              Cancel
            </button>
          </div>

          <.simple_form for={@generic_loan_changeset}
                        id="generic-loan-form"
                        phx-change="validate-generic-loan"
                        phx-submit="save-generic-loan"
                        :let={f}>
            <div class="grid gap-4">
              <.input field={f[:name]} label="Loan name" />
              <div>
                <label class="text-sm font-medium text-zinc-700" for="loan_loan_type">Loan type</label>
                <select id="loan_loan_type" name="loan[loan_type]" class="input">
                  <%= Phoenix.HTML.Form.options_for_select(generic_loan_type_options(), f[:loan_type].value || "auto") %>
                </select>
              </div>
              <.input field={f[:lender_name]} label="Lender" />
              <.input field={f[:servicer_name]} label="Servicer" />
              <.input field={f[:collateral_description]} label="Collateral or note" />

              <div class="grid gap-4 sm:grid-cols-2">
                <.input field={f[:current_balance]} label="Current balance" type={:number} step="0.01" min="0" />
                <div>
                  <label class="text-sm font-medium text-zinc-700" for="loan_current_interest_rate_percent">
                    Current interest rate (%)
                  </label>
                  <input
                    id="loan_current_interest_rate_percent"
                    name="loan[current_interest_rate_percent]"
                    class="input"
                    type="number"
                    step="0.0001"
                    min="0"
                    value={generic_loan_rate_percent_value(@generic_loan_changeset, :current_interest_rate)}
                  />
                </div>
                <.input field={f[:remaining_term_months]} label="Remaining term months" type={:number} min="1" />
                <.input field={f[:monthly_payment_total]} label="Monthly payment" type={:number} step="0.01" min="0" />
              </div>
            </div>

            <div class="flex justify-end gap-2">
              <button type="button" class="btn btn-outline" phx-click="cancel-generic-loan">Cancel</button>
              <button type="submit" class="btn">Add loan</button>
            </div>
          </.simple_form>
        </div>
      </div>
    </section>
    """
  end

  defp range_value(assigns) do
    assigns = assign_new(assigns, :kind, fn -> :currency end)

    ~H"""
    <div class="space-y-1 text-xs">
      <div class="flex justify-between gap-3">
        <span class="text-zinc-500">Low</span>
        <span class="font-medium text-zinc-900"><%= format_range_value(@range.low, @kind) %></span>
      </div>
      <div class="flex justify-between gap-3">
        <span class="text-zinc-500">Expected</span>
        <span class="font-medium text-zinc-900"><%= format_range_value(@range.expected, @kind) %></span>
      </div>
      <div class="flex justify-between gap-3">
        <span class="text-zinc-500">High</span>
        <span class="font-medium text-zinc-900"><%= format_range_value(@range.high, @kind) %></span>
      </div>
    </div>
    """
  end

  defp warning_status(%{warnings: []} = assigns) do
    ~H"""
    <span class="inline-flex rounded-full border border-zinc-200 bg-zinc-50 px-2.5 py-1 text-xs font-medium text-zinc-600">
      No warnings
    </span>
    """
  end

  defp warning_status(assigns) do
    ~H"""
    <div class="space-y-1">
      <span class="inline-flex rounded-full border border-amber-200 bg-amber-50 px-2.5 py-1 text-xs font-medium text-amber-800">
        Review needed
      </span>
      <p class="max-w-56 text-xs text-amber-700"><%= List.first(@warnings) %></p>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :row, :any, default: nil

  defp refinance_metric(assigns) do
    ~H"""
    <div class="rounded-lg border border-zinc-200 bg-zinc-50 p-4">
      <p class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500"><%= @label %></p>
      <p class="mt-1 text-xl font-semibold text-zinc-900"><%= @value %></p>
      <p :if={@row} class="text-xs text-zinc-500"><%= @row.scenario.name %></p>
      <p :if={@row == nil} class="text-xs text-zinc-500">No comparable scenario</p>
    </div>
    """
  end

  defp load_page(socket, current_user) do
    all_mortgages = Mortgages.list_mortgages(current_user)
    generic_loans = Loans.list_loans(current_user)
    mortgages = scope_mortgages(all_mortgages, socket.assigns.route_loan_id)

    selected_mortgage = List.first(mortgages)
    what_if_form = maybe_reset_what_if_form(socket.assigns[:what_if_form], selected_mortgage)
    scenario_rows = scenario_rows(current_user, mortgages)

    assign(socket,
      all_mortgages: all_mortgages,
      generic_loans: generic_loans,
      mortgages: mortgages,
      selected_mortgage: selected_mortgage,
      what_if_form: what_if_form,
      what_if_summary: what_if_summary(selected_mortgage, what_if_form),
      selected_analysis_scenario_id:
        default_selected_analysis_scenario_id(
          socket.assigns.selected_analysis_scenario_id,
          scenario_rows
        ),
      scenario_rows: scenario_rows,
      rate_source_rows: rate_source_rows(),
      rate_observation_rows: rate_observation_rows(),
      market_snapshot: Loans.mortgage_market_snapshot(),
      analysis_history_rows: analysis_history_rows(current_user, mortgages),
      document_rows: document_rows(current_user, mortgages),
      quote_rows: quote_rows(current_user, mortgages),
      alert_rows: alert_rows(current_user, mortgages)
    )
  end

  defp scope_mortgages(mortgages, nil), do: mortgages

  defp scope_mortgages(mortgages, loan_id) do
    Enum.filter(mortgages, &(&1.id == loan_id))
  end

  defp mortgage_changeset(current_user) do
    current_user
    |> base_mortgage()
    |> Mortgages.change_mortgage()
  end

  defp generic_loan_changeset(current_user) do
    current_user
    |> base_generic_loan()
    |> Loans.change_loan()
  end

  defp base_generic_loan(current_user, attrs \\ %{}) do
    %Loan{
      user_id: current_user.id,
      loan_type: Map.get(attrs, "loan_type", "auto"),
      status: "active"
    }
  end

  defp normalize_mortgage_rate_params(params) do
    params
    |> normalize_percent_param("current_interest_rate_percent", "current_interest_rate")
  end

  defp normalize_generic_loan_rate_params(params) do
    params
    |> normalize_percent_param("current_interest_rate_percent", "current_interest_rate")
  end

  defp normalize_scenario_rate_params(params) do
    params
    |> normalize_percent_param("new_interest_rate_percent", "new_interest_rate")
    |> normalize_percent_param("new_apr_percent", "new_apr")
  end

  defp normalize_percent_param(params, percent_key, decimal_key) do
    case Map.fetch(params, percent_key) do
      {:ok, value} ->
        params
        |> Map.put(decimal_key, percent_to_decimal_param(value))
        |> Map.delete(percent_key)

      :error ->
        params
    end
  end

  defp percent_to_decimal_param(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" ->
        ""

      trimmed ->
        case Decimal.cast(trimmed) do
          {:ok, decimal} ->
            decimal
            |> Decimal.div(Decimal.new("100"))
            |> Decimal.to_string(:normal)

          :error ->
            trimmed
        end
    end
  end

  defp mortgage_rate_percent_value(changeset, field) do
    changeset
    |> Ecto.Changeset.get_field(field)
    |> case do
      nil ->
        ""

      value ->
        value
        |> Decimal.mult(Decimal.new("100"))
        |> Decimal.round(4)
        |> Decimal.to_string(:normal)
        |> trim_trailing_decimal_zeros()
    end
  end

  defp generic_loan_rate_percent_value(changeset, field) do
    changeset
    |> Ecto.Changeset.get_field(field)
    |> case do
      nil ->
        ""

      value ->
        value
        |> Decimal.mult(Decimal.new("100"))
        |> Decimal.round(4)
        |> Decimal.to_string(:normal)
        |> trim_trailing_decimal_zeros()
    end
  end

  defp generic_loan_preview(%Loan{} = loan) do
    loan
    |> Loans.generic_loan_refinance_template()
    |> then(&Loans.generic_loan_refinance_preview(loan, &1))
  end

  defp scenario_rate_percent_value(changeset, field) do
    mortgage_rate_percent_value(changeset, field)
  end

  defp trim_trailing_decimal_zeros(value) do
    value
    |> String.replace(~r/(\.\d*?)0+$/, "\\1")
    |> String.replace(~r/\.$/, "")
  end

  defp default_what_if_form(nil) do
    %{
      "mortgage_id" => nil,
      "rate_percent" => "0",
      "term_months" => "360",
      "extra_monthly_principal" => "0"
    }
  end

  defp default_what_if_form(%Mortgage{} = mortgage) do
    %{
      "mortgage_id" => mortgage.id,
      "rate_percent" => decimal_to_percent_string(mortgage.current_interest_rate),
      "term_months" => mortgage.remaining_term_months |> default_term_months() |> to_string(),
      "extra_monthly_principal" => "0"
    }
  end

  defp maybe_reset_what_if_form(nil, mortgage), do: default_what_if_form(mortgage)

  defp maybe_reset_what_if_form(%{"mortgage_id" => mortgage_id} = form, %Mortgage{id: mortgage_id}) do
    form
  end

  defp maybe_reset_what_if_form(_form, mortgage), do: default_what_if_form(mortgage)

  defp merge_what_if_form(form, params) do
    Map.merge(
      form || default_what_if_form(nil),
      Map.take(params, Map.keys(default_what_if_form(nil)))
    )
  end

  defp what_if_summary(nil, _form), do: nil

  defp what_if_summary(%Mortgage{} = mortgage, form) do
    rate =
      form
      |> Map.get("rate_percent", "0")
      |> percent_to_decimal_param()

    term_months =
      form
      |> Map.get("term_months", "360")
      |> parse_positive_integer(default_term_months(mortgage.remaining_term_months))

    extra_principal =
      form
      |> Map.get("extra_monthly_principal", "0")
      |> decimal_string_or_zero()

    Amortization.payoff_summary(mortgage.current_balance, rate, term_months, extra_principal)
  rescue
    _error ->
      Amortization.payoff_summary(
        mortgage.current_balance,
        mortgage.current_interest_rate,
        default_term_months(mortgage.remaining_term_months),
        "0"
      )
  end

  defp default_term_months(months) when is_integer(months) and months > 0, do: months
  defp default_term_months(_months), do: 360

  defp parse_positive_integer(value, fallback) do
    case Integer.parse(to_string(value)) do
      {integer, _rest} when integer > 0 -> integer
      _other -> fallback
    end
  end

  defp decimal_string_or_zero(value) do
    case Decimal.cast(value) do
      {:ok, decimal} ->
        if Decimal.compare(decimal, Decimal.new("0")) == :lt do
          "0"
        else
          Decimal.to_string(decimal, :normal)
        end

      _other ->
        "0"
    end
  end

  defp decimal_to_percent_string(nil), do: "0"

  defp decimal_to_percent_string(value) do
    value
    |> Decimal.mult(Decimal.new("100"))
    |> Decimal.round(4)
    |> Decimal.to_string(:normal)
    |> trim_trailing_decimal_zeros()
  end

  defp format_currency_string(value) do
    case Decimal.cast(value) do
      {:ok, decimal} -> format_currency(decimal)
      :error -> "$0.00"
    end
  end

  defp mortgage_for_form(
         %{assigns: %{mortgage_form_mode: :edit, editing_mortgage: %Mortgage{} = mortgage}},
         _current_user
       ) do
    mortgage
  end

  defp mortgage_for_form(_socket, current_user), do: base_mortgage(current_user)

  defp mortgage_saved_message(:edit), do: "Loan updated."
  defp mortgage_saved_message(_mode), do: "Mortgage added to Loan Center."

  defp mortgage_form_title(:edit), do: "Edit loan"
  defp mortgage_form_title(_mode), do: "Add mortgage"

  defp mortgage_form_description(:edit),
    do: "Update the baseline loan record used by refinance analysis."

  defp mortgage_form_description(_mode) do
    "Create the baseline loan record used by refinance analysis."
  end

  defp mortgage_form_submit_label(:edit), do: "Save loan"
  defp mortgage_form_submit_label(_mode), do: "Add mortgage"

  defp base_mortgage(current_user) do
    %Mortgage{
      user_id: current_user.id,
      loan_type: "conventional",
      status: "active",
      has_escrow: false,
      escrow_included_in_payment: false
    }
  end

  defp scenario_changeset(current_user, mortgages) do
    current_user
    |> base_scenario(mortgages)
    |> Loans.change_refinance_scenario()
  end

  defp rate_observation_changeset(attrs \\ %{}) do
    %RateObservation{
      loan_type: "mortgage",
      product_type: "fixed",
      term_months: 360,
      assumptions: %{},
      raw_payload: %{}
    }
    |> Loans.change_rate_observation(attrs)
  end

  defp normalize_rate_observation_rate_params(params) do
    params
    |> normalize_percent_param("rate_percent", "rate")
    |> normalize_percent_param("apr_percent", "apr")
  end

  defp rate_observation_rate_percent_value(changeset, field) do
    changeset
    |> Ecto.Changeset.get_field(field)
    |> case do
      nil ->
        ""

      value ->
        value
        |> Decimal.mult(Decimal.new("100"))
        |> Decimal.round(4)
        |> Decimal.to_string(:normal)
        |> trim_trailing_decimal_zeros()
    end
  end

  defp rate_observation_rows do
    [loan_type: "mortgage", product_type: "fixed", limit: 10]
    |> Loans.list_rate_observations()
  end

  defp rate_source_rows do
    _ = Loans.get_or_create_fred_rate_source()

    [enabled: true]
    |> Loans.list_rate_sources()
    |> Enum.reject(&(&1.source_type == "manual"))
  end

  defp base_scenario(current_user, mortgages, attrs \\ %{}) do
    mortgage = mortgage_for_scenario_defaults(mortgages, attrs)

    %RefinanceScenario{
      user_id: current_user.id,
      mortgage_id: Map.get(attrs, "mortgage_id") || mortgage_id(mortgage),
      scenario_type: "manual",
      product_type: "fixed",
      new_term_months: default_scenario_term_months(mortgage),
      new_interest_rate: mortgage_rate(mortgage),
      new_principal_amount: mortgage_balance(mortgage),
      status: "draft"
    }
  end

  defp mortgage_for_scenario_defaults(mortgages, attrs) do
    mortgage_id = Map.get(attrs, "mortgage_id")

    Enum.find(mortgages, List.first(mortgages), &(&1.id == mortgage_id))
  end

  defp mortgage_id(%Mortgage{id: id}), do: id
  defp mortgage_id(_mortgage), do: nil

  defp default_scenario_term_months(%Mortgage{remaining_term_months: months})
       when is_integer(months) and months > 0,
       do: months

  defp default_scenario_term_months(_mortgage), do: 360

  defp mortgage_rate(%Mortgage{current_interest_rate: rate}), do: rate
  defp mortgage_rate(_mortgage), do: nil

  defp mortgage_balance(%Mortgage{current_balance: balance}), do: balance
  defp mortgage_balance(_mortgage), do: nil

  defp scenario_rows(current_user, mortgages) do
    Enum.flat_map(mortgages, fn mortgage ->
      current_user
      |> Loans.list_refinance_scenarios(mortgage, preload: [:fee_items])
      |> Enum.map(fn scenario ->
        true_refinance_cost = sum_fee_items(scenario.fee_items, :true_cost)
        cash_to_close_timing_cost = sum_fee_items(scenario.fee_items, :timing_cost)

        %{
          mortgage: mortgage,
          scenario: scenario,
          true_refinance_cost: true_refinance_cost,
          cash_to_close: Decimal.add(true_refinance_cost, cash_to_close_timing_cost),
          analysis:
            scenario_analysis(
              mortgage,
              scenario,
              true_refinance_cost,
              cash_to_close_timing_cost
            )
        }
      end)
    end)
  end

  defp selected_analysis_rows(_scenario_rows, nil), do: []

  defp selected_analysis_rows(scenario_rows, scenario_id) do
    Enum.filter(scenario_rows, &(&1.scenario.id == scenario_id))
  end

  defp default_selected_analysis_scenario_id(current_id, scenario_rows) do
    cond do
      current_id && Enum.any?(scenario_rows, &(&1.scenario.id == current_id)) ->
        current_id

      scenario_rows != [] ->
        scenario_rows |> List.first() |> then(& &1.scenario.id)

      true ->
        nil
    end
  end

  defp lowest_expected_payment_row([]), do: nil

  defp lowest_expected_payment_row(scenario_rows) do
    Enum.min_by(scenario_rows, & &1.analysis.payment_range.expected, Decimal)
  end

  defp fastest_break_even_row(scenario_rows) do
    scenario_rows
    |> Enum.filter(& &1.analysis.break_even_range.expected)
    |> case do
      [] -> nil
      rows -> Enum.min_by(rows, & &1.analysis.break_even_range.expected)
    end
  end

  defp lowest_full_term_delta_row([]), do: nil

  defp lowest_full_term_delta_row(scenario_rows) do
    Enum.min_by(scenario_rows, & &1.analysis.full_term_finance_cost_delta, Decimal)
  end

  defp metric_payment_value(scenario_rows) do
    case lowest_expected_payment_row(scenario_rows) do
      nil -> "No scenarios"
      row -> format_currency(row.analysis.payment_range.expected)
    end
  end

  defp metric_break_even_value(scenario_rows) do
    case fastest_break_even_row(scenario_rows) do
      nil -> "No break-even"
      row -> format_months(row.analysis.break_even_range.expected)
    end
  end

  defp metric_full_term_delta_value(scenario_rows) do
    case lowest_full_term_delta_row(scenario_rows) do
      nil -> "No scenarios"
      row -> format_currency(row.analysis.full_term_finance_cost_delta)
    end
  end

  defp analysis_history_rows(current_user, mortgages) do
    scenario_names =
      current_user
      |> scenario_rows(mortgages)
      |> Map.new(fn row -> {row.scenario.id, row.scenario.name} end)

    current_user
    |> Loans.list_refinance_analysis_results(limit: 10)
    |> Enum.map(fn result ->
      %{
        result: result,
        scenario_name: Map.get(scenario_names, result.refinance_scenario_id, "Scenario")
      }
    end)
  end

  defp scenario_analysis(mortgage, scenario, true_refinance_cost, cash_to_close_timing_cost) do
    RefinanceCalculator.analyze(%{
      current_principal: mortgage.current_balance,
      current_rate: mortgage.current_interest_rate,
      current_remaining_term_months: mortgage.remaining_term_months,
      current_monthly_payment: mortgage.monthly_payment_total,
      new_principal: scenario.new_principal_amount,
      new_rate: scenario.new_interest_rate,
      new_term_months: scenario.new_term_months,
      true_refinance_cost: true_refinance_cost,
      cash_to_close_timing_cost: cash_to_close_timing_cost
    })
  end

  defp fee_changeset(scenario_rows) do
    scenario_rows
    |> base_fee_item()
    |> Loans.change_refinance_fee_item()
  end

  defp base_fee_item(scenario_rows, attrs \\ %{}) do
    %RefinanceFeeItem{
      refinance_scenario_id:
        Map.get(attrs, "refinance_scenario_id") || first_scenario_id(scenario_rows),
      kind: "fee",
      paid_at_closing: true,
      financed: false,
      is_true_cost: true,
      is_prepaid_or_escrow: false,
      required: false,
      sort_order: 0
    }
  end

  defp document_changeset(current_user, mortgages) do
    current_user
    |> base_document(mortgages)
    |> Loans.change_loan_document()
  end

  defp base_document(current_user, mortgages, attrs \\ %{}) do
    %LoanDocument{
      user_id: current_user.id,
      mortgage_id: Map.get(attrs, "mortgage_id") || first_mortgage_id(mortgages),
      document_type: "loan_estimate",
      content_type: "application/pdf",
      status: "uploaded",
      uploaded_at: DateTime.utc_now()
    }
  end

  defp document_rows(current_user, mortgages) do
    Enum.flat_map(mortgages, fn mortgage ->
      current_user
      |> Loans.list_loan_documents(mortgage, preload: [:extractions])
      |> Enum.map(fn document ->
        %{
          mortgage: mortgage,
          document: document
        }
      end)
    end)
  end

  defp quote_changeset(current_user, mortgages) do
    current_user
    |> base_quote(mortgages)
    |> Loans.change_lender_quote()
  end

  defp base_quote(current_user, mortgages, attrs \\ %{}) do
    %LenderQuote{
      user_id: current_user.id,
      mortgage_id: Map.get(attrs, "mortgage_id") || first_mortgage_id(mortgages),
      quote_source: "manual",
      loan_type: "mortgage",
      product_type: "fixed",
      term_months: 360,
      lock_available: false,
      raw_payload: %{},
      status: "active"
    }
  end

  defp quote_rows(current_user, mortgages) do
    Enum.flat_map(mortgages, fn mortgage ->
      Loans.expire_lender_quotes(current_user, mortgage)

      current_user
      |> Loans.list_lender_quotes(mortgage)
      |> Enum.map(fn quote ->
        %{
          mortgage: mortgage,
          quote: quote
        }
      end)
    end)
  end

  defp alert_rows(current_user, mortgages) do
    Enum.flat_map(mortgages, fn mortgage ->
      current_user
      |> Loans.list_loan_alert_rules(mortgage)
      |> Enum.map(fn rule ->
        %{
          mortgage: mortgage,
          rule: rule
        }
      end)
    end)
  end

  defp default_extraction_form(document_rows) do
    %{
      "loan_document_id" => first_document_id(document_rows),
      "field_name" => "",
      "field_value" => "",
      "confidence" => "",
      "model_name" => "manual",
      "source_note" => ""
    }
  end

  defp default_ollama_extraction_form(document_rows) do
    %{
      "loan_document_id" => first_document_id(document_rows),
      "raw_text" => ""
    }
  end

  defp default_alert_form(mortgages) do
    %{
      "mortgage_id" => first_mortgage_id(mortgages),
      "name" => "Review refinance opportunity",
      "kind" => "monthly_savings_above_threshold",
      "threshold_value" => "",
      "lead_days" => "7",
      "cooldown_hours" => "24",
      "active" => "true"
    }
  end

  defp merge_extraction_form(form, params) do
    Map.merge(form, Map.take(params, Map.keys(default_extraction_form([]))))
  end

  defp merge_ollama_extraction_form(form, params) do
    Map.merge(form, Map.take(params, Map.keys(default_ollama_extraction_form([]))))
  end

  defp merge_alert_form(form, params) do
    Map.merge(form, Map.take(params, Map.keys(default_alert_form([]))))
  end

  defp build_alert_rule_attrs(form) do
    name = String.trim(to_string(form["name"] || ""))
    kind = String.trim(to_string(form["kind"] || ""))
    threshold_value = String.trim(to_string(form["threshold_value"] || ""))

    cond do
      name == "" ->
        {:error, "Enter an alert name before saving."}

      kind == "" ->
        {:error, "Choose an alert kind before saving."}

      alert_uses_threshold?(kind) and threshold_value == "" ->
        {:error, "Enter a threshold before saving this alert."}

      true ->
        {:ok,
         %{
           "name" => name,
           "kind" => kind,
           "active" => form["active"] || "true",
           "threshold_value" => threshold_value,
           "lead_days" => form["lead_days"] || "7",
           "delivery_preferences" => %{
             "cooldown_hours" => form["cooldown_hours"] || "24"
           }
         }}
    end
  end

  defp build_manual_extraction_attrs(form) do
    document_id = String.trim(to_string(form["loan_document_id"] || ""))
    field_name = String.trim(to_string(form["field_name"] || ""))
    field_value = String.trim(to_string(form["field_value"] || ""))
    confidence = String.trim(to_string(form["confidence"] || ""))
    source_note = String.trim(to_string(form["source_note"] || ""))

    cond do
      document_id == "" ->
        {:error, "Choose a document before saving an extraction candidate."}

      field_name == "" ->
        {:error, "Enter a field name before saving an extraction candidate."}

      field_value == "" ->
        {:error, "Enter a field value before saving an extraction candidate."}

      true ->
        {:ok, document_id,
         %{
           extraction_method: "manual",
           model_name: blank_to_nil(form["model_name"]),
           extracted_payload: %{field_name => field_value},
           field_confidence: confidence_payload(field_name, confidence),
           source_citations: source_payload(field_name, source_note)
         }}
    end
  end

  defp build_ollama_extraction_input(form) do
    document_id = String.trim(to_string(form["loan_document_id"] || ""))
    raw_text = String.trim(to_string(form["raw_text"] || ""))

    cond do
      document_id == "" ->
        {:error, "Choose a document before running Ollama extraction."}

      raw_text == "" ->
        {:error, "Paste document text before running Ollama extraction."}

      true ->
        {:ok, document_id, raw_text}
    end
  end

  defp maybe_put_quote_source_note(attrs) do
    source_note = attrs |> Map.get("source_note") |> blank_to_nil()

    attrs = Map.delete(attrs, "source_note")

    if source_note do
      Map.put(attrs, "raw_payload", %{"source_note" => source_note})
    else
      attrs
    end
  end

  defp confidence_payload(_field_name, ""), do: %{}

  defp confidence_payload(field_name, confidence) do
    case Float.parse(confidence) do
      {value, ""} -> %{field_name => value}
      _ -> %{}
    end
  end

  defp source_payload(_field_name, ""), do: %{}
  defp source_payload(field_name, source_note), do: %{field_name => [%{"text" => source_note}]}

  defp blank_to_nil(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp uploaded_document_attrs(socket, current_user, mortgage_id) do
    socket
    |> consume_uploaded_entries(:loan_document_file, fn %{path: path}, entry ->
      case File.read(path) do
        {:ok, content} ->
          file_name = safe_client_name(entry.client_name)
          storage_key = loan_document_storage_key(current_user.id, mortgage_id, file_name)
          destination = Path.join([System.tmp_dir!(), "money_tree", "uploads", storage_key])

          File.mkdir_p!(Path.dirname(destination))
          File.cp!(path, destination)

          {:ok,
           %{
             "original_filename" => file_name,
             "content_type" => entry.client_type || "application/octet-stream",
             "byte_size" => entry.client_size || byte_size(content),
             "storage_key" => storage_key,
             "checksum_sha256" => sha256(content)
           }}

        {:error, _reason} ->
          {:postpone, %{}}
      end
    end)
    |> case do
      [attrs | _] -> attrs
      [] -> %{}
    end
  rescue
    _ -> %{}
  end

  defp maybe_enqueue_uploaded_document_extraction(socket, current_user, document, attrs) do
    if uploaded_file_attrs?(attrs) do
      case Loans.enqueue_loan_document_extraction(current_user, document) do
        {:ok, _job} ->
          :ok

        {:error, reason} ->
          put_flash(socket, :error, "Document extraction could not be queued: #{inspect(reason)}")
          :ok
      end
    else
      :ok
    end
  end

  defp uploaded_file_attrs?(attrs) do
    Map.has_key?(attrs, "checksum_sha256") and Map.has_key?(attrs, "storage_key")
  end

  defp safe_client_name(nil), do: "loan-document"

  defp safe_client_name(name) do
    name
    |> Path.basename()
    |> String.replace(~r/[^A-Za-z0-9._-]/, "-")
    |> case do
      "" -> "loan-document"
      sanitized -> sanitized
    end
  end

  defp loan_document_storage_key(user_id, mortgage_id, file_name) do
    Path.join([
      "loan-documents",
      user_id,
      mortgage_id || "unassigned",
      "#{Ecto.UUID.generate()}-#{file_name}"
    ])
  end

  defp sha256(content) do
    :sha256
    |> :crypto.hash(content)
    |> Base.encode16(case: :lower)
  end

  defp sum_fee_items(fee_items, :true_cost) do
    fee_items
    |> List.wrap()
    |> Enum.reduce(Decimal.new("0"), fn fee_item, acc ->
      if fee_item.is_true_cost and not fee_item.is_prepaid_or_escrow do
        add_signed_fee(acc, fee_item)
      else
        acc
      end
    end)
  end

  defp sum_fee_items(fee_items, :timing_cost) do
    fee_items
    |> List.wrap()
    |> Enum.reduce(Decimal.new("0"), fn fee_item, acc ->
      if fee_item.is_prepaid_or_escrow or fee_item.kind == "timing_cost" do
        add_signed_fee(acc, fee_item)
      else
        acc
      end
    end)
  end

  defp add_signed_fee(acc, fee_item) do
    amount = fee_item.expected_amount || fee_item.fixed_amount || Decimal.new("0")

    if fee_item.kind in ["lender_credit", "escrow_refund", "waived_fee", "other_credit"] do
      Decimal.sub(acc, amount)
    else
      Decimal.add(acc, amount)
    end
  end

  defp mortgage_options(mortgages), do: Enum.map(mortgages, &{&1.property_name, &1.id})

  defp scenario_options(scenario_rows) do
    Enum.map(scenario_rows, fn row -> {row.scenario.name, row.scenario.id} end)
  end

  defp fee_kind_options do
    [
      {"Fee", "fee"},
      {"Timing cost", "timing_cost"},
      {"Lender credit", "lender_credit"},
      {"Escrow refund", "escrow_refund"},
      {"Waived fee", "waived_fee"},
      {"Other credit", "other_credit"}
    ]
  end

  defp document_type_options do
    Enum.map(LoanDocument.document_types(), &{format_label(&1), &1})
  end

  defp quote_source_options do
    Enum.map(LenderQuote.quote_sources(), &{format_label(&1), &1})
  end

  defp quote_status_options do
    Enum.map(LenderQuote.statuses(), &{format_label(&1), &1})
  end

  defp alert_kind_options do
    AlertRule.kinds()
    |> Enum.map(&{format_label(&1), &1})
  end

  defp generic_loan_type_options do
    Loan.loan_types()
    |> Enum.map(&{format_label(&1), &1})
  end

  defp alert_uses_threshold?(kind) do
    kind in [
      "rate_below_threshold",
      "monthly_payment_below_threshold",
      "monthly_savings_above_threshold",
      "break_even_below_months",
      "full_term_cost_savings_above_threshold",
      "expected_horizon_savings_above_threshold"
    ]
  end

  defp alert_threshold_label_for_kind("rate_below_threshold"), do: "Rate threshold"
  defp alert_threshold_label_for_kind("monthly_payment_below_threshold"), do: "Payment threshold"
  defp alert_threshold_label_for_kind("monthly_savings_above_threshold"), do: "Savings threshold"
  defp alert_threshold_label_for_kind("break_even_below_months"), do: "Break-even months"

  defp alert_threshold_label_for_kind("full_term_cost_savings_above_threshold"),
    do: "Savings threshold"

  defp alert_threshold_label_for_kind("expected_horizon_savings_above_threshold"),
    do: "Savings threshold"

  defp alert_threshold_label_for_kind(_kind), do: "Threshold"

  defp document_options(document_rows) do
    Enum.map(document_rows, fn row ->
      {row.document.original_filename, row.document.id}
    end)
  end

  defp stored_document?(%LoanDocument{storage_key: storage_key}) when is_binary(storage_key) do
    String.trim(storage_key) != ""
  end

  defp stored_document?(_document), do: false

  defp first_mortgage_id([%Mortgage{id: id} | _]), do: id
  defp first_mortgage_id(_), do: nil

  defp first_scenario_id([%{scenario: %RefinanceScenario{id: id}} | _]), do: id
  defp first_scenario_id(_), do: nil

  defp first_document_id([%{document: %LoanDocument{id: id}} | _]), do: id
  defp first_document_id(_), do: nil

  defp workspace_title(:detail), do: "Loan overview"
  defp workspace_title(:refinance), do: "Refinance analysis"
  defp workspace_title(:documents), do: "Documents"
  defp workspace_title(:quotes), do: "Lender quotes"
  defp workspace_title(:alerts), do: "Alerts"
  defp workspace_title(_), do: "Loan overview"

  defp workspace_description(:refinance) do
    "Compare deterministic payment, break-even, and full-term cost outputs for this loan."
  end

  defp workspace_description(:documents) do
    "Upload and review loan documents before any extracted values update canonical records."
  end

  defp workspace_description(:quotes) do
    "Track lender-specific quotes separately from benchmark rate estimates."
  end

  defp workspace_description(:alerts) do
    "Create review triggers for rate, payment, break-even, and full-term cost changes."
  end

  defp workspace_description(_) do
    "Review the mortgage-backed loan baseline currently powering Loan Center."
  end

  defp workspace_link_class(current_action, target_action) do
    base = "rounded-full px-3 py-1 font-medium"

    if current_action == target_action do
      "#{base} bg-emerald-600 text-white"
    else
      "#{base} border border-zinc-200 text-zinc-700 hover:bg-zinc-50"
    end
  end

  defp refinance_split_class(true) do
    "grid gap-6 xl:grid-cols-[minmax(0,1.35fr)_minmax(0,1fr)]"
  end

  defp refinance_split_class(false), do: "space-y-6"

  defp workspace_path(:refinance, loan_id), do: ~p"/app/loans/#{loan_id}/refinance"
  defp workspace_path(:documents, loan_id), do: ~p"/app/loans/#{loan_id}/documents"
  defp workspace_path(:quotes, loan_id), do: ~p"/app/loans/#{loan_id}/quotes"
  defp workspace_path(:alerts, loan_id), do: ~p"/app/loans/#{loan_id}/alerts"
  defp workspace_path(_action, loan_id), do: ~p"/app/loans/#{loan_id}"

  defp format_currency(nil), do: "$0.00"

  defp format_currency(value) do
    value
    |> Decimal.to_float()
    |> :erlang.float_to_binary(decimals: 2)
    |> then(&"$#{&1}")
  end

  defp format_percent(nil), do: "0.00%"

  defp format_percent(value) do
    value
    |> Decimal.mult(Decimal.new("100"))
    |> Decimal.to_float()
    |> :erlang.float_to_binary(decimals: 2)
    |> then(&"#{&1}%")
  end

  defp format_signed_percent(nil), do: "0.00%"

  defp format_signed_percent(value) do
    sign =
      case Decimal.compare(value, Decimal.new("0")) do
        :lt -> ""
        _ -> "+"
      end

    sign <> format_percent(value)
  end

  defp format_decimal(nil), do: "Not set"

  defp format_decimal(value) do
    value
    |> Decimal.round(4)
    |> Decimal.to_string(:normal)
    |> trim_trailing_decimal_zeros()
  end

  defp rate_source_label(%RateObservation{rate_source: %{name: name}}) when is_binary(name) do
    name
  end

  defp rate_source_label(_observation), do: "Rate source"

  defp market_rate_value(snapshot, series_key) do
    snapshot
    |> market_rate_observation(series_key)
    |> case do
      %RateObservation{rate: rate} -> format_percent(rate)
      _value -> "Not imported"
    end
  end

  defp market_rate_observation(snapshot, series_key) do
    (snapshot.mortgage_rates ++ snapshot.baseline_rates)
    |> Enum.find(&(&1.series_key == series_key))
  end

  defp market_trend_label(snapshot, series_key, window) do
    case get_in(snapshot.direction, [series_key, window]) do
      %{status: :ok, delta: delta} ->
        "#{format_signed_percent(delta)} vs #{window} days ago"

      %{status: :incomplete_window} ->
        "Not enough history for #{window}-day trend"

      _value ->
        "Trend unavailable"
    end
  end

  defp market_explanation(snapshot) do
    case get_in(snapshot.direction, ["gs10", 30]) do
      %{status: :ok, delta: delta} ->
        case Decimal.compare(delta, Decimal.new("0")) do
          :gt -> "Treasury yields increased over the last 30 days."
          :lt -> "Treasury yields declined over the last 30 days."
          :eq -> "Treasury yields are roughly unchanged over the last 30 days."
        end

      _value ->
        "Import market benchmarks to explain rate movement."
    end
  end

  defp market_snapshot_attribution(snapshot) do
    (snapshot.mortgage_rates ++ snapshot.baseline_rates)
    |> Enum.map(fn observation ->
      case observation.rate_source do
        %RateSource{attribution_label: label} when is_binary(label) and label != "" -> label
        %RateSource{name: name} when is_binary(name) -> name
        _value -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> case do
      [] -> "Market data provider attribution will appear after import"
      labels -> Enum.join(labels, ", ")
    end
  end

  defp rate_source_import_status(%RateSource{last_success_at: %DateTime{} = imported_at}) do
    "Last imported #{format_datetime(imported_at)}"
  end

  defp rate_source_import_status(%RateSource{last_error_at: %DateTime{} = error_at}) do
    "Last error #{format_datetime(error_at)}"
  end

  defp rate_source_import_status(_source), do: "Not imported"

  defp format_months(nil), do: "No break-even"
  defp format_months(months), do: "#{months} months"

  defp format_range_value(value, :months), do: format_months(value)
  defp format_range_value(value, _kind), do: format_currency(value)

  defp quote_lock_status(%LenderQuote{
         lock_available: true,
         lock_expires_at: %DateTime{} = expires_at
       }) do
    "Available until #{format_datetime(expires_at)}"
  end

  defp quote_lock_status(%LenderQuote{lock_available: true}), do: "Available"
  defp quote_lock_status(_quote), do: "No lock"

  defp quote_freshness_label(%LenderQuote{status: "expired"}), do: "Expired"
  defp quote_freshness_label(%LenderQuote{status: "converted"}), do: "Converted"
  defp quote_freshness_label(%LenderQuote{status: "archived"}), do: "Archived"
  defp quote_freshness_label(%LenderQuote{quote_expires_at: nil}), do: "No expiration"

  defp quote_freshness_label(%LenderQuote{quote_expires_at: expires_at}) do
    case DateTime.compare(expires_at, DateTime.utc_now()) do
      :lt -> "Expired"
      _ -> "Active until #{format_datetime(expires_at)}"
    end
  end

  defp quote_convert_disabled?(%LenderQuote{status: status}) do
    status in ["converted", "expired", "archived"]
  end

  defp alert_threshold_label(%AlertRule{kind: "lender_quote_expiring", threshold_config: config}) do
    "#{Map.get(config || %{}, "lead_days", 7)} days"
  end

  defp alert_threshold_label(%AlertRule{kind: "document_review_needed"}), do: "Review queue"

  defp alert_threshold_label(%AlertRule{threshold_config: config}) do
    Map.get(config || %{}, "threshold", "Not set")
  end

  defp alert_cooldown_label(%AlertRule{delivery_preferences: preferences}) do
    "#{Map.get(preferences || %{}, "cooldown_hours", 24)} hours"
  end

  defp alert_delivery_label(%AlertRule{delivery_preferences: preferences}) do
    cooldown = Map.get(preferences || %{}, "cooldown_hours", 24)
    "Durable notifications, #{cooldown}h cooldown"
  end

  defp extraction_summary(%Ecto.Association.NotLoaded{}), do: "Not loaded"
  defp extraction_summary([]), do: "No extraction candidates"

  defp extraction_summary(extractions) when is_list(extractions) do
    extractions
    |> Enum.map(&format_label(&1.status))
    |> Enum.frequencies()
    |> Enum.map(fn {status, count} -> "#{count} #{status}" end)
    |> Enum.join(", ")
  end

  defp extraction_summary(_), do: "No extraction candidates"

  defp extraction_rows(document_rows) do
    Enum.flat_map(document_rows, fn row ->
      row.document.extractions
      |> List.wrap()
      |> Enum.reject(&match?(%Ecto.Association.NotLoaded{}, &1))
      |> Enum.map(fn extraction ->
        %{
          mortgage: row.mortgage,
          document: row.document,
          extraction: extraction
        }
      end)
    end)
  end

  defp payload_fields(payload) when is_map(payload) do
    payload
    |> Enum.sort_by(fn {field, _value} -> to_string(field) end)
  end

  defp payload_fields(_), do: []

  defp field_confidence(confidence, field) when is_map(confidence) do
    case Map.get(confidence, field) || Map.get(confidence, to_string(field)) do
      nil ->
        nil

      value ->
        "Confidence #{format_payload_value(value)}"
    end
  end

  defp field_confidence(_confidence, _field), do: nil

  defp field_citations(citations, field) when is_map(citations) do
    citations
    |> Map.get(field, Map.get(citations, to_string(field), []))
    |> List.wrap()
    |> Enum.flat_map(&format_citation/1)
  end

  defp field_citations(_citations, _field), do: []

  defp format_citation(%{"text" => text} = citation) when is_binary(text) do
    page = Map.get(citation, "page")

    label =
      case page do
        nil -> "Source"
        page -> "Source p. #{page}"
      end

    ["#{label}: #{text}"]
  end

  defp format_citation(%{text: text} = citation) when is_binary(text) do
    format_citation(%{"text" => text, "page" => Map.get(citation, :page)})
  end

  defp format_citation(text) when is_binary(text), do: ["Source: #{text}"]
  defp format_citation(_citation), do: []

  defp extraction_review_context?(extraction) do
    stored_text_artifact(extraction) || stored_text_excerpt(extraction) ||
      raw_text_excerpt(extraction)
  end

  defp stored_text_artifact(%LoanDocumentExtraction{ocr_text_storage_key: storage_key}) do
    blank_to_nil(storage_key)
  end

  defp stored_text_excerpt(%LoanDocumentExtraction{ocr_text_storage_key: storage_key}) do
    storage_key
    |> blank_to_nil()
    |> case do
      nil ->
        nil

      storage_key ->
        storage_key
        |> stored_document_path()
        |> read_text_excerpt()
    end
  end

  defp raw_text_excerpt(%LoanDocumentExtraction{raw_text_excerpt: excerpt}) do
    blank_to_nil(excerpt)
  end

  defp stored_document_path(storage_key) do
    Path.join([System.tmp_dir!(), "money_tree", "uploads", storage_key])
  end

  defp read_text_excerpt(path) do
    with {:ok, text} <- File.read(path),
         text <- String.trim(text),
         false <- text == "" do
      if String.length(text) > 10_000 do
        String.slice(text, 0, 10_000) <> "\n..."
      else
        text
      end
    else
      _ -> nil
    end
  end

  defp extraction_pending_review?(%LoanDocumentExtraction{status: "pending_review"}), do: true
  defp extraction_pending_review?(_extraction), do: false

  defp extraction_confirmed?(%LoanDocumentExtraction{status: "confirmed"}), do: true
  defp extraction_confirmed?(_extraction), do: false

  defp extraction_rejected?(%LoanDocumentExtraction{status: "rejected"}), do: true
  defp extraction_rejected?(_extraction), do: false

  defp format_payload_value(value) when is_binary(value), do: value
  defp format_payload_value(value) when is_integer(value) or is_float(value), do: to_string(value)
  defp format_payload_value(value) when is_boolean(value), do: to_string(value)
  defp format_payload_value(nil), do: ""
  defp format_payload_value(value), do: Jason.encode!(value)

  defp upload_error_message(:too_large), do: "File is too large."
  defp upload_error_message(:too_many_files), do: "Only one file can be uploaded."
  defp upload_error_message(:not_accepted), do: "File type is not accepted."
  defp upload_error_message(error), do: "Upload failed: #{inspect(error)}"

  defp format_label(nil), do: ""

  defp format_label(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp format_datetime(nil), do: nil

  defp format_datetime(%DateTime{} = value) do
    Calendar.strftime(value, "%b %-d, %Y %-I:%M %p")
  end

  defp format_date(nil), do: nil

  defp format_date(%Date{} = value) do
    Calendar.strftime(value, "%b %-d, %Y")
  end

  defp errors_on(changeset, field) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Map.get(field, [])
  end
end
