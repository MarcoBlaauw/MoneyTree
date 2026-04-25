defmodule MoneyTreeWeb.MortgageController do
  use MoneyTreeWeb, :controller

  alias Ecto.Changeset
  alias MoneyTree.Mortgages
  alias MoneyTree.Mortgages.EscrowProfile
  alias MoneyTree.Mortgages.Mortgage

  def index(%{assigns: %{current_user: current_user}} = conn, _params) do
    mortgages =
      current_user
      |> Mortgages.list_mortgages()
      |> Enum.map(&serialize_mortgage/1)

    json(conn, %{data: mortgages})
  end

  def show(%{assigns: %{current_user: current_user}} = conn, %{"id" => id}) do
    case Mortgages.fetch_mortgage(current_user, id) do
      {:ok, mortgage} ->
        json(conn, %{data: serialize_mortgage(mortgage)})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "mortgage not found"})
    end
  end

  def create(%{assigns: %{current_user: current_user}} = conn, params) do
    case Mortgages.create_mortgage(current_user, params) do
      {:ok, mortgage} ->
        conn
        |> put_status(:created)
        |> json(%{data: serialize_mortgage(mortgage)})

      {:error, %Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: Changeset.traverse_errors(changeset, &translate_error/1)})
    end
  end

  def update(%{assigns: %{current_user: current_user}} = conn, %{"id" => id} = params) do
    case Mortgages.update_mortgage(current_user, id, Map.delete(params, "id")) do
      {:ok, mortgage} ->
        json(conn, %{data: serialize_mortgage(mortgage)})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "mortgage not found"})

      {:error, %Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: Changeset.traverse_errors(changeset, &translate_error/1)})
    end
  end

  def delete(%{assigns: %{current_user: current_user}} = conn, %{"id" => id}) do
    case Mortgages.delete_mortgage(current_user, id) do
      {:ok, _mortgage} ->
        send_resp(conn, :no_content, "")

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "mortgage not found"})
    end
  end

  defp serialize_mortgage(%Mortgage{} = mortgage) do
    %{
      id: mortgage.id,
      nickname: mortgage.nickname,
      property_name: mortgage.property_name,
      street_line_1: mortgage.street_line_1,
      street_line_2: mortgage.street_line_2,
      city: mortgage.city,
      state_region: mortgage.state_region,
      postal_code: mortgage.postal_code,
      country_code: mortgage.country_code,
      occupancy_type: mortgage.occupancy_type,
      loan_type: mortgage.loan_type,
      servicer_name: mortgage.servicer_name,
      lender_name: mortgage.lender_name,
      original_loan_amount: mortgage.original_loan_amount,
      current_balance: mortgage.current_balance,
      original_interest_rate: mortgage.original_interest_rate,
      current_interest_rate: mortgage.current_interest_rate,
      original_term_months: mortgage.original_term_months,
      remaining_term_months: mortgage.remaining_term_months,
      monthly_principal_interest: mortgage.monthly_principal_interest,
      monthly_payment_total: mortgage.monthly_payment_total,
      home_value_estimate: mortgage.home_value_estimate,
      pmi_mip_monthly: mortgage.pmi_mip_monthly,
      hoa_monthly: mortgage.hoa_monthly,
      flood_insurance_monthly: mortgage.flood_insurance_monthly,
      has_escrow: mortgage.has_escrow,
      escrow_included_in_payment: mortgage.escrow_included_in_payment,
      linked_obligation_id: mortgage.linked_obligation_id,
      status: mortgage.status,
      source: mortgage.source,
      last_reviewed_at: mortgage.last_reviewed_at,
      escrow_profile: serialize_escrow_profile(mortgage.escrow_profile),
      inserted_at: mortgage.inserted_at,
      updated_at: mortgage.updated_at
    }
  end

  defp serialize_escrow_profile(nil), do: nil

  defp serialize_escrow_profile(%EscrowProfile{} = escrow_profile) do
    %{
      id: escrow_profile.id,
      property_tax_monthly: escrow_profile.property_tax_monthly,
      homeowners_insurance_monthly: escrow_profile.homeowners_insurance_monthly,
      flood_insurance_monthly: escrow_profile.flood_insurance_monthly,
      other_escrow_monthly: escrow_profile.other_escrow_monthly,
      escrow_cushion_months: escrow_profile.escrow_cushion_months,
      expected_old_escrow_refund: escrow_profile.expected_old_escrow_refund,
      annual_tax_growth_rate: escrow_profile.annual_tax_growth_rate,
      annual_insurance_growth_rate: escrow_profile.annual_insurance_growth_rate,
      source: escrow_profile.source,
      confidence_score: escrow_profile.confidence_score,
      inserted_at: escrow_profile.inserted_at,
      updated_at: escrow_profile.updated_at
    }
  end

  defp translate_error({msg, opts}) do
    Gettext.dgettext(MoneyTreeWeb.Gettext, "errors", msg, opts)
  end

  defp translate_error(msg) when is_binary(msg), do: msg
end
