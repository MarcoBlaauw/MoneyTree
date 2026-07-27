defmodule MoneyTree.Secrets do
  @moduledoc """
  Narrow runtime secret access boundary.

  This facade keeps runtime configuration from scattering secret reads through
  application code or browser-facing surfaces.
  """

  alias MoneyTree.Secrets.Env
  alias MoneyTree.Secrets.OpenBao

  @providers %{
    "env" => Env,
    "openbao" => OpenBao
  }
  @fallback_telemetry_event [:money_tree, :secrets, :provider, :fallback]

  @type provider :: module()

  @spec provider_from_env() :: provider()
  def provider_from_env do
    {mode, selected_by} = backend_mode_from_env()

    case Map.fetch(@providers, mode) do
      {:ok, provider} ->
        provider

      :error ->
        :telemetry.execute(
          @fallback_telemetry_event,
          %{count: 1},
          %{requested_mode: mode, selected_by: selected_by, fallback_backend: :env}
        )

        Env
    end
  end

  @spec provider(String.t() | nil) :: provider()
  def provider(nil), do: Env
  def provider(""), do: Env

  def provider(mode) when is_binary(mode) do
    mode = String.downcase(String.trim(mode))
    Map.get(@providers, mode, Env)
  end

  @spec get(String.t(), provider()) :: String.t() | nil
  def get(key, provider \\ provider_from_env()) when is_binary(key) do
    provider.get(key)
  end

  @spec get_group(atom(), provider()) :: map()
  def get_group(group, provider \\ provider_from_env()) when is_atom(group) do
    provider.get_group(group)
  end

  defp backend_mode_from_env do
    cond do
      mode = System.get_env("MONEYTREE_SECRET_BACKEND") ->
        {normalize_mode(mode), "MONEYTREE_SECRET_BACKEND"}

      mode = System.get_env("SECRET_BACKEND_MODE") ->
        {normalize_mode(mode), "SECRET_BACKEND_MODE"}

      true ->
        {"env", "default"}
    end
  end

  defp normalize_mode(mode) do
    mode
    |> String.trim()
    |> String.downcase()
  end
end
