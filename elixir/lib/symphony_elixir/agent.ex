defmodule SymphonyElixir.Agent do
  @moduledoc """
  Behaviour commun pour tous les agents (Codex, Claude Code, etc.).
  """

  @type session :: map()
  @type turn_result :: %{
          session_id: String.t(),
          result: term()
        }

  @callback start_session(workspace :: Path.t(), opts :: keyword()) ::
              {:ok, session()} | {:error, term()}

  @callback run_turn(session(), prompt :: String.t(), issue :: map(), opts :: keyword()) ::
              {:ok, turn_result()} | {:error, term()}

  @callback stop_session(session()) :: :ok
end
