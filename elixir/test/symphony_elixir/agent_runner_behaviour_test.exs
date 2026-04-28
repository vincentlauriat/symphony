defmodule SymphonyElixir.AgentRunnerBehaviourTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue

  defmodule MockAgent do
    @behaviour SymphonyElixir.Agent

    @impl true
    def start_session(_workspace, _opts), do: {:ok, %{session_id: nil}}

    @impl true
    def run_turn(_session, _prompt, _issue, opts) do
      on_message = Keyword.get(opts, :on_message, fn _ -> :ok end)
      on_message.(%{event: :turn_completed, timestamp: DateTime.utc_now()})
      {:ok, %{session_id: "mock-session-abc", result: :turn_completed}}
    end

    @impl true
    def stop_session(_session), do: :ok
  end

  test "AgentRunner utilise Config.agent_module() pour dispatcher" do
    workspace_root =
      Path.join(System.tmp_dir!(), "symphony-runner-behaviour-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace_root)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    issue = %Issue{
      id: "issue-behaviour-test",
      identifier: "BT-1",
      title: "Test behaviour dispatch",
      description: "desc",
      state: "In Progress",
      url: "https://example.org/BT-1",
      labels: []
    }

    issue_state_fetcher = fn _ids -> {:ok, [%{issue | state: "Done"}]} end

    on_exit(fn -> File.rm_rf(workspace_root) end)

    assert :ok =
             AgentRunner.run(issue, self(), [
               agent_module: MockAgent,
               issue_state_fetcher: issue_state_fetcher,
               max_turns: 1
             ])

    assert_receive {:agent_worker_update, "issue-behaviour-test", %{event: :turn_completed}}, 500
  end
end
