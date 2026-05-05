defmodule MoneyTree.AI.Config do
  @moduledoc """
  Runtime AI configuration helpers.
  """

  @default_provider "ollama"
  @default_timeout_ms 60_000
  @default_max_input_transactions 200
  @default_ollama_base_url "http://localhost:11434"
  @default_ollama_model "llama3.1:8b"

  @spec config() :: keyword()
  def config do
    Application.get_env(:money_tree, MoneyTree.AI, [])
  end

  @spec enabled?() :: boolean()
  def enabled? do
    config()
    |> Keyword.get(:enabled, false)
  end

  @spec require_confirmation?() :: boolean()
  def require_confirmation? do
    config()
    |> Keyword.get(:require_confirmation, true)
  end

  @spec default_provider() :: String.t()
  def default_provider do
    config()
    |> Keyword.get(:default_provider, @default_provider)
    |> to_string()
  end

  @spec max_input_transactions() :: pos_integer()
  def max_input_transactions do
    config()
    |> Keyword.get(:max_input_transactions, @default_max_input_transactions)
    |> normalize_positive_integer(@default_max_input_transactions)
  end

  @spec provider_module(String.t()) :: module()
  def provider_module(provider) when is_binary(provider) do
    modules =
      config()
      |> Keyword.get(:provider_modules, %{
        "ollama" => MoneyTree.AI.Providers.Ollama
      })

    Map.get(modules, provider, MoneyTree.AI.Providers.Ollama)
  end

  @spec provider_settings(String.t()) :: map()
  def provider_settings("ollama") do
    ollama = config() |> Keyword.get(:ollama, [])

    %{
      provider: "ollama",
      base_url: Keyword.get(ollama, :base_url, @default_ollama_base_url),
      model: Keyword.get(ollama, :model, @default_ollama_model),
      timeout_ms:
        normalize_positive_integer(Keyword.get(ollama, :timeout_ms), @default_timeout_ms)
    }
  end

  def provider_settings(provider) when is_binary(provider) do
    %{
      provider: provider,
      timeout_ms: @default_timeout_ms
    }
  end

  defp normalize_positive_integer(value, _fallback) when is_integer(value) and value > 0,
    do: value

  defp normalize_positive_integer(value, fallback) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _rest} when parsed > 0 -> parsed
      _ -> fallback
    end
  end

  defp normalize_positive_integer(_value, fallback), do: fallback
end
