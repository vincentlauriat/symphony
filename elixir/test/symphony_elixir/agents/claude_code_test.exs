defmodule SymphonyElixir.Agents.ClaudeCodeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Agents.ClaudeCode

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-claude-code-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)
    {:ok, workspace: workspace}
  end

  test "start_session crée le fichier MCP config dans le workspace", %{workspace: workspace} do
    write_workflow_file!(Workflow.workflow_file_path(), claude_code_mcp_port: 4001)

    assert {:ok, session} = ClaudeCode.start_session(workspace)

    mcp_path = Path.join(workspace, ".symphony_mcp.json")
    assert File.exists?(mcp_path)

    config = mcp_path |> File.read!() |> Jason.decode!()
    assert get_in(config, ["mcpServers", "symphony", "type"]) == "sse"
    assert get_in(config, ["mcpServers", "symphony", "url"]) =~ "4001/mcp/sse"

    assert session.workspace == workspace
    assert is_nil(session.session_id)
    assert session.mcp_config_path == mcp_path
  end

  test "start_session utilise le port MCP configuré", %{workspace: workspace} do
    write_workflow_file!(Workflow.workflow_file_path(), claude_code_mcp_port: 5500)

    {:ok, _session} = ClaudeCode.start_session(workspace)

    config = workspace |> Path.join(".symphony_mcp.json") |> File.read!() |> Jason.decode!()
    assert get_in(config, ["mcpServers", "symphony", "url"]) =~ "5500/mcp/sse"
  end

  test "start_session ignore l'option worker_host", %{workspace: workspace} do
    write_workflow_file!(Workflow.workflow_file_path())
    assert {:ok, _session} = ClaudeCode.start_session(workspace, worker_host: "remote.host")
  end

  test "stop_session supprime le fichier MCP config", %{workspace: workspace} do
    write_workflow_file!(Workflow.workflow_file_path())

    {:ok, session} = ClaudeCode.start_session(workspace)
    assert File.exists?(session.mcp_config_path)

    assert :ok = ClaudeCode.stop_session(session)
    refute File.exists?(session.mcp_config_path)
  end

  test "stop_session est idempotent si le fichier n'existe plus", %{workspace: workspace} do
    session = %{
      workspace: workspace,
      session_id: nil,
      mcp_config_path: Path.join(workspace, ".symphony_mcp.json")
    }

    assert :ok = ClaudeCode.stop_session(session)
  end
end
