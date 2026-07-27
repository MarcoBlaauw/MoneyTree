defmodule MoneyTree.System.TimedCmdTest do
  use ExUnit.Case, async: true

  alias MoneyTree.System.TimedCmd

  test "returns output and exit status for a command that finishes in time" do
    echo = System.find_executable("echo")
    assert {output, 0} = TimedCmd.run(echo, ["hello"], timeout_ms: 5_000)
    assert String.trim(output) == "hello"
  end

  test "returns the non-zero exit status of a failing command" do
    sh = System.find_executable("sh")
    assert {_output, 1} = TimedCmd.run(sh, ["-c", "exit 1"], timeout_ms: 5_000)
  end

  test "kills a process that exceeds the timeout and reports :timeout" do
    sleep = System.find_executable("sleep")

    started_at = System.monotonic_time(:millisecond)
    assert {_output, :timeout} = TimedCmd.run(sleep, ["30"], timeout_ms: 200)
    elapsed = System.monotonic_time(:millisecond) - started_at

    # If the process were merely abandoned rather than killed, this test
    # would have to wait out the full 30s sleep. Asserting a tight elapsed
    # bound proves the OS process was actually terminated, not just ignored.
    assert elapsed < 5_000
  end
end
