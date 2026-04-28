defmodule SymphonyElixir.Agents.ClaudeCode do
  @moduledoc """
  Implémentation du behaviour Agent utilisant Claude Code CLI.

  Chaque turn lance un process `claude` indépendant via Port.
  La continuité de session est assurée via --resume <session_id>.
  Les outils dynamiques sont exposés via le serveur MCP de Symphony.
  """

  @behaviour SymphonyElixir.Agent

  require Logger

  alias SymphonyElixir.Config

  @port_line_bytes 1_048_576

  @impl true
  @spec start_session(Path.t(), keyword()) :: {:ok, SymphonyElixir.Agent.session()} | {:error, term()}
  def start_session(workspace, _opts \\ []) do
    mcp_config_path = Path.join(workspace, ".symphony_mcp.json")
    mcp_port = Config.settings!().claude_code.mcp_port

    mcp_config = %{
      "mcpServers" => %{
        "symphony" => %{
          "type" => "sse",
          "url" => "http://127.0.0.1:#{mcp_port}/mcp/sse"
        }
      }
    }

    with {:ok, json} <- Jason.encode(mcp_config),
         :ok <- File.write(mcp_config_path, json) do
      {:ok, %{workspace: workspace, session_id: nil, mcp_config_path: mcp_config_path}}
    else
      {:error, reason} -> {:error, {:mcp_config_failed, reason}}
    end
  end

  @impl true
  @spec run_turn(SymphonyElixir.Agent.session(), String.t(), map(), keyword()) ::
          {:ok, SymphonyElixir.Agent.turn_result()} | {:error, term()}
  def run_turn(session, prompt, issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, fn _msg -> :ok end)
    settings = Config.settings!().claude_code
    command = build_command(session.session_id, session.mcp_config_path, settings)

    case find_executable(settings.command) do
      {:ok, executable} ->
        port = open_port(executable, command, session.workspace)
        Port.command(port, prompt <> "\n")

        try do
          case await_completion(port, settings.turn_timeout_ms, on_message, issue) do
            {:ok, session_id, result} ->
              {:ok, %{session_id: session_id, result: result}}

            {:error, reason} ->
              {:error, reason}
          end
        after
          close_port(port)
        end

      {:error, :not_found} ->
        {:error, :claude_not_found}
    end
  end

  @impl true
  @spec stop_session(SymphonyElixir.Agent.session()) :: :ok
  def stop_session(%{mcp_config_path: path}) do
    File.rm(path)
    :ok
  end

  defp build_command(session_id, mcp_config_path, settings) do
    tools = Enum.join(settings.allowed_tools, ",")

    base = [
      "--output-format", "stream-json",
      "--print",
      "--allowedTools", tools,
      "--mcp-config", mcp_config_path
    ]

    with_model =
      case settings.model do
        nil -> base
        model -> base ++ ["--model", model]
      end

    case session_id do
      nil -> with_model
      id -> with_model ++ ["--resume", id]
    end
  end

  defp find_executable(command) do
    case System.find_executable(command) do
      nil -> {:error, :not_found}
      path -> {:ok, path}
    end
  end

  defp close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp open_port(executable, args, workspace) do
    Port.open(
      {:spawn_executable, String.to_charlist(executable)},
      [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: Enum.map(args, &String.to_charlist/1),
        cd: String.to_charlist(workspace),
        line: @port_line_bytes
      ]
    )
  end

  defp await_completion(port, timeout_ms, on_message, issue) do
    read_stream(port, timeout_ms, on_message, issue, nil, "")
  end

  defp read_stream(port, timeout_ms, on_message, issue, session_id, pending_line) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_stream_line(port, timeout_ms, on_message, issue, session_id, complete_line)

      {^port, {:data, {:noeol, chunk}}} ->
        read_stream(port, timeout_ms, on_message, issue, session_id, pending_line <> to_string(chunk))

      {^port, {:exit_status, 0}} ->
        {:error, :unexpected_exit}

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        close_port(port)
        {:error, :turn_timeout}
    end
  end

  defp handle_stream_line(port, timeout_ms, on_message, issue, session_id, line) do
    case Jason.decode(line) do
      {:ok, %{"type" => "system", "subtype" => "init", "session_id" => new_id}} ->
        Logger.debug("Claude Code session initiated session_id=#{new_id} issue=#{issue_context(issue)}")
        read_stream(port, timeout_ms, on_message, issue, new_id, "")

      {:ok, %{"type" => "result", "subtype" => "success"} = payload} ->
        on_message.(%{event: :turn_completed, payload: payload, timestamp: DateTime.utc_now()})
        {:ok, session_id, :turn_completed}

      {:ok, %{"type" => "result", "subtype" => subtype} = payload} ->
        on_message.(%{event: :turn_ended_with_error, reason: subtype, payload: payload, timestamp: DateTime.utc_now()})
        {:error, {:turn_failed, subtype}}

      {:ok, %{"type" => "assistant"} = payload} ->
        on_message.(%{event: :notification, payload: payload, timestamp: DateTime.utc_now()})
        read_stream(port, timeout_ms, on_message, issue, session_id, "")

      {:ok, payload} ->
        on_message.(%{event: :other_message, payload: payload, timestamp: DateTime.utc_now()})
        read_stream(port, timeout_ms, on_message, issue, session_id, "")

      {:error, _} ->
        line_trimmed = String.trim(line)

        if line_trimmed != "" do
          if String.match?(line_trimmed, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
            Logger.warning("Claude Code output: #{String.slice(line_trimmed, 0, 500)}")
          else
            Logger.debug("Claude Code output: #{String.slice(line_trimmed, 0, 500)}")
          end
        end

        read_stream(port, timeout_ms, on_message, issue, session_id, "")
    end
  end

  defp issue_context(%{id: id, identifier: identifier}), do: "issue_id=#{id} issue_identifier=#{identifier}"
  defp issue_context(issue) when is_map(issue), do: inspect(issue)
end
