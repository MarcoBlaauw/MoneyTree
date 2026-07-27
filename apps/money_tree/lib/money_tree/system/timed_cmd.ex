defmodule MoneyTree.System.TimedCmd do
  @moduledoc """
  Runs an external executable with a hard wall-clock timeout, killing the
  underlying OS process if it's exceeded.

  `System.cmd/3` has no timeout option: a hung or pathologically slow
  external tool (e.g. an OCR utility fed a crafted PDF) blocks the calling
  process indefinitely, which -- in a background worker -- can tie up worker
  capacity for the whole queue. This runs the process via a raw `Port` so a
  timeout can both stop waiting and terminate the OS process itself, rather
  than just abandoning it as an orphan.
  """

  @default_timeout_ms :timer.minutes(2)

  @type result :: {output :: String.t(), exit_status :: non_neg_integer() | :timeout}

  @spec run(String.t(), [String.t()], keyword()) :: result()
  def run(executable, args, opts \\ [])
      when is_binary(executable) and is_list(args) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    stderr_to_stdout? = Keyword.get(opts, :stderr_to_stdout, false)

    port_opts =
      [:binary, :exit_status, :use_stdio, args: args]
      |> maybe_add_stderr_to_stdout(stderr_to_stdout?)

    port = Port.open({:spawn_executable, executable}, port_opts)
    collect(port, timeout, [])
  end

  defp maybe_add_stderr_to_stdout(opts, true), do: [:stderr_to_stdout | opts]
  defp maybe_add_stderr_to_stdout(opts, false), do: opts

  defp collect(port, timeout, acc) do
    receive do
      {^port, {:data, data}} ->
        collect(port, timeout, [data | acc])

      {^port, {:exit_status, status}} ->
        {acc |> Enum.reverse() |> IO.iodata_to_binary(), status}
    after
      timeout ->
        kill(port)
        {acc |> Enum.reverse() |> IO.iodata_to_binary(), :timeout}
    end
  end

  defp kill(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> System.cmd("kill", ["-9", to_string(os_pid)], stderr_to_stdout: true)
      nil -> :ok
    end
  catch
    :error, _reason -> :ok
  after
    catch_close(port)
  end

  defp catch_close(port) do
    Port.close(port)
  catch
    :error, _reason -> :ok
  end
end
