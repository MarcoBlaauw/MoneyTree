defmodule MoneyTree.Net.SsrfGuardTest do
  use ExUnit.Case, async: true

  alias MoneyTree.Net.SsrfGuard

  describe "validate/1" do
    test "allows loopback (the common self-hosted Ollama case)" do
      assert :ok = SsrfGuard.validate("http://localhost:11434")
      assert :ok = SsrfGuard.validate("http://127.0.0.1:11434")
    end

    test "allows private/LAN addresses" do
      assert :ok = SsrfGuard.validate("http://192.168.1.50:11434")
      assert :ok = SsrfGuard.validate("http://10.0.0.5:11434")
    end

    test "allows a public IP literal" do
      assert :ok = SsrfGuard.validate("http://93.184.216.34")
    end

    test "rejects the IPv4 link-local range where cloud metadata services live" do
      assert {:error, :destination_not_allowed} = SsrfGuard.validate("http://169.254.169.254")
    end

    test "rejects IPv6 link-local and multicast" do
      assert {:error, :destination_not_allowed} = SsrfGuard.validate("http://[fe80::1]")
      assert {:error, :destination_not_allowed} = SsrfGuard.validate("http://[ff02::1]")
    end

    test "rejects unsupported schemes" do
      assert {:error, :invalid_url} = SsrfGuard.validate("file:///etc/passwd")
      assert {:error, :invalid_url} = SsrfGuard.validate("gopher://example.com")
    end

    test "rejects malformed input" do
      assert {:error, :invalid_url} = SsrfGuard.validate("not a url")
      assert {:error, :invalid_url} = SsrfGuard.validate(nil)
    end

    test "rejects a hostname that fails to resolve" do
      assert {:error, :resolution_failed} =
               SsrfGuard.validate("http://this-host-should-not-resolve.invalid")
    end
  end
end
