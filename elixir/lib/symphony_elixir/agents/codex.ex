defmodule SymphonyElixir.Agents.Codex do
  @moduledoc """
  Implémentation du behaviour Agent utilisant Codex app-server.
  """

  @behaviour SymphonyElixir.Agent

  alias SymphonyElixir.Codex.AppServer

  @impl true
  def start_session(workspace, opts \\ []) do
    AppServer.start_session(workspace, opts)
  end

  @impl true
  def run_turn(session, prompt, issue, opts \\ []) do
    AppServer.run_turn(session, prompt, issue, opts)
  end

  @impl true
  def stop_session(session) do
    AppServer.stop_session(session)
  end
end
