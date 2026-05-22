defmodule MoneyTreeWeb.EvaluationController do
  use MoneyTreeWeb, :controller

  alias MoneyTree.Evaluations

  def status_summary(%{assigns: %{current_user: current_user}} = conn, _params) do
    summary = Evaluations.status_summary(current_user)

    json(conn, %{
      data: %{
        generated_at: DateTime.to_iso8601(summary.generated_at),
        counts: summary.counts,
        items: Enum.map(summary.items, &serialize_item/1)
      }
    })
  end

  defp serialize_item(item) do
    %{
      id: item.id,
      domain: item.domain,
      resource_id: item.resource_id,
      status: item.status,
      severity: item.severity,
      title: item.title,
      summary: item.summary,
      reasons: item.reasons,
      source: item.source,
      target_path: item.target_path
    }
  end
end
