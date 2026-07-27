defmodule MoneyTree.AI.Providers.OllamaTest do
  use ExUnit.Case, async: true

  alias MoneyTree.AI.Providers.Ollama

  describe "SSRF guard integration" do
    test "health_check refuses a link-local destination without making a request" do
      settings = %{base_url: "http://169.254.169.254", timeout_ms: 100}

      assert {:error, :destination_not_allowed} = Ollama.health_check(settings)
    end

    test "list_models refuses a link-local destination without making a request" do
      settings = %{base_url: "http://169.254.169.254", timeout_ms: 100}

      assert {:error, :destination_not_allowed} = Ollama.list_models(settings)
    end

    test "generate_json refuses a link-local destination without making a request" do
      settings = %{base_url: "http://169.254.169.254", model: "llama3.1:8b", timeout_ms: 100}

      assert {:error, :destination_not_allowed} = Ollama.generate_json(settings, "prompt")
    end
  end
end
