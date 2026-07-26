defmodule MoneyTree.Secrets.Health do
  @moduledoc """
  Secret backend status reporting without exposing secret values.
  """

  alias MoneyTree.Secrets
  alias MoneyTree.Secrets.Env
  alias MoneyTree.Secrets.OpenBao

  @groups Env.groups()
  @telemetry_event [:money_tree, :secrets, :health, :summary]

  @spec summary(keyword()) :: map()
  def summary(opts \\ []) do
    live? = Keyword.get(opts, :live?, false)
    provider = Secrets.provider_from_env()

    summary = %{
      backend: backend_name(provider),
      selected_by: selected_by(),
      status: status(provider),
      live: live?,
      groups: group_summaries(provider, live?)
    }

    :telemetry.execute(
      @telemetry_event,
      %{count: 1},
      %{
        backend: String.to_atom(summary.backend),
        status: String.to_atom(summary.status),
        live: summary.live
      }
    )

    summary
  end

  defp status(OpenBao) do
    case OpenBao.config() do
      {:ok, _config} -> "configured"
      {:error, _errors} -> "not_configured"
    end
  end

  defp status(_provider), do: "configured"

  defp group_summaries(OpenBao, false) do
    case OpenBao.config() do
      {:ok, _config} ->
        Map.new(@groups, fn group ->
          {Atom.to_string(group), %{status: "not_checked"}}
        end)

      {:error, errors} ->
        Map.new(@groups, fn group ->
          {Atom.to_string(group), %{status: "not_configured", errors: errors}}
        end)
    end
  end

  defp group_summaries(OpenBao, true) do
    case OpenBao.config() do
      {:ok, _config} ->
        Map.new(@groups, fn group ->
          {Atom.to_string(group), summarize_live_group(OpenBao, group)}
        end)

      {:error, errors} ->
        Map.new(@groups, fn group ->
          {Atom.to_string(group), %{status: "not_configured", errors: errors}}
        end)
    end
  end

  defp group_summaries(provider, _live?) do
    Map.new(@groups, fn group ->
      keys = Env.keys_for_group(group)
      secrets = provider.get_group(group)
      present_keys = Enum.count(keys, fn key -> present?(Map.get(secrets, key)) end)
      missing_keys = Enum.reject(keys, fn key -> present?(Map.get(secrets, key)) end)

      status =
        if present_keys > 0 or missing_keys == [] do
          "configured"
        else
          "missing"
        end

      {Atom.to_string(group),
       %{
         status: status,
         present_keys: present_keys,
         missing_keys: missing_keys
       }}
    end)
  end

  defp summarize_live_group(provider, group) do
    secrets = provider.get_group(group)
    keys = Env.keys_for_group(group)
    present_keys = Enum.count(keys, fn key -> present?(Map.get(secrets, key)) end)
    missing_keys = Enum.reject(keys, fn key -> present?(Map.get(secrets, key)) end)

    %{
      status: if(missing_keys == [], do: "configured", else: "partial"),
      present_keys: present_keys,
      missing_keys: missing_keys
    }
  rescue
    error ->
      %{status: "error", error: Exception.message(error)}
  end

  defp selected_by do
    cond do
      present?(System.get_env("MONEYTREE_SECRET_BACKEND")) -> "MONEYTREE_SECRET_BACKEND"
      present?(System.get_env("SECRET_BACKEND_MODE")) -> "SECRET_BACKEND_MODE"
      true -> "default"
    end
  end

  defp backend_name(Env), do: "env"
  defp backend_name(OpenBao), do: "openbao"

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
