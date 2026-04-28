# Intégration Claude Code comme agent alternatif — Plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ajouter Claude Code CLI comme agent configurable dans Symphony, en parallèle de Codex, via un behaviour Elixir commun.

**Architecture:** Un behaviour `SymphonyElixir.Agent` définit l'interface (`start_session/2`, `run_turn/4`, `stop_session/1`). `Agents.Codex` wrappe l'`AppServer` existant sans le modifier. `Agents.ClaudeCode` lance `claude` CLI via Port et expose les outils dynamiques via un endpoint MCP SSE ajouté à Phoenix/Bandit. La sélection de l'agent se fait dans `agent.provider` (config globale ou override `WORKFLOW.md`).

**Tech Stack:** Elixir/OTP, ExUnit, Phoenix/Bandit (déjà présent), Claude Code CLI, protocole MCP (SSE + JSON-RPC).

---

## Structure des fichiers

| Fichier | Action | Rôle |
|---------|--------|------|
| `elixir/lib/symphony_elixir/config/schema.ex` | Modifier | Ajouter `Agent.provider` + sous-module `ClaudeCode` |
| `elixir/lib/symphony_elixir/config.ex` | Modifier | Ajouter `agent_module/0` |
| `elixir/test/support/test_support.exs` | Modifier | Ajouter champs config pour les nouveaux paramètres |
| `elixir/lib/symphony_elixir/agent.ex` | Créer | Behaviour `@callback` |
| `elixir/lib/symphony_elixir/agents/codex.ex` | Créer | Wrapper `Codex.AppServer` |
| `elixir/lib/symphony_elixir/agent_runner.ex` | Modifier | Utiliser `Config.agent_module()`, renommer messages |
| `elixir/lib/symphony_elixir/orchestrator.ex` | Modifier | Renommer `:codex_worker_update` → `:agent_worker_update` |
| `elixir/test/symphony_elixir/orchestrator_status_test.exs` | Modifier | Renommer atom dans les tests |
| `elixir/test/symphony_elixir/core_test.exs` | Modifier | Renommer atom dans les tests |
| `elixir/test/symphony_elixir/live_e2e_test.exs` | Modifier | Renommer atom dans les tests |
| `elixir/lib/symphony_elixir_web/controllers/mcp_controller.ex` | Créer | Endpoint MCP SSE + messages |
| `elixir/lib/symphony_elixir_web/router.ex` | Modifier | Routes `/mcp/sse` et `/mcp/messages` |
| `elixir/lib/symphony_elixir/agents/claude_code.ex` | Créer | Implémentation complète Claude Code |
| `elixir/test/symphony_elixir/agents/claude_code_test.exs` | Créer | Tests unitaires ClaudeCode |
| `elixir/test/symphony_elixir/mcp_controller_test.exs` | Créer | Tests contrôleur MCP |

---

## Tâche 1 : Config Schema — `agent.provider` + sous-module `ClaudeCode`

**Fichiers :**
- Modifier : `elixir/lib/symphony_elixir/config/schema.ex`
- Modifier : `elixir/lib/symphony_elixir/config.ex`
- Test : `elixir/test/symphony_elixir/workspace_and_config_test.exs`

- [ ] **Étape 1.1 : Écrire les tests qui vont échouer**

Dans `elixir/test/symphony_elixir/workspace_and_config_test.exs`, ajouter à la fin du fichier :

```elixir
test "agent.provider defaults to codex" do
  write_workflow_file!(Workflow.workflow_file_path())
  assert Config.settings!().agent.provider == "codex"
  assert Config.agent_module() == SymphonyElixir.Agents.Codex
end

test "agent.provider claude_code resolves to ClaudeCode module" do
  write_workflow_file!(Workflow.workflow_file_path(), agent_provider: "claude_code")
  assert Config.agent_module() == SymphonyElixir.Agents.ClaudeCode
end

test "claude_code config has expected defaults" do
  write_workflow_file!(Workflow.workflow_file_path())
  cc = Config.settings!().claude_code
  assert cc.command == "claude"
  assert cc.turn_timeout_ms == 3_600_000
  assert cc.mcp_port == 4001
  assert "Bash" in cc.allowed_tools
end

test "claude_code.mcp_port is configurable" do
  write_workflow_file!(Workflow.workflow_file_path(), claude_code_mcp_port: 5500)
  assert Config.settings!().claude_code.mcp_port == 5500
end
```

- [ ] **Étape 1.2 : Vérifier que les tests échouent**

```bash
cd elixir && mix test test/symphony_elixir/workspace_and_config_test.exs 2>&1 | tail -20
```

Attendu : erreurs de compilation ou `** (KeyError) key :provider not found`.

- [ ] **Étape 1.3 : Ajouter `provider` dans `Schema.Agent` et le nouveau sous-module `ClaudeCode`**

Dans `elixir/lib/symphony_elixir/config/schema.ex`, modifier le module `Agent` pour ajouter `provider` :

```elixir
defmodule Agent do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias SymphonyElixir.Config.Schema

  @primary_key false
  embedded_schema do
    field(:max_concurrent_agents, :integer, default: 10)
    field(:max_turns, :integer, default: 20)
    field(:max_retry_backoff_ms, :integer, default: 300_000)
    field(:max_concurrent_agents_by_state, :map, default: %{})
    field(:provider, :string, default: "codex")
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(
      attrs,
      [:max_concurrent_agents, :max_turns, :max_retry_backoff_ms, :max_concurrent_agents_by_state, :provider],
      empty_values: []
    )
    |> validate_number(:max_concurrent_agents, greater_than: 0)
    |> validate_number(:max_turns, greater_than: 0)
    |> validate_number(:max_retry_backoff_ms, greater_than: 0)
    |> update_change(:max_concurrent_agents_by_state, &Schema.normalize_state_limits/1)
    |> Schema.validate_state_limits(:max_concurrent_agents_by_state)
    |> validate_inclusion(:provider, ["codex", "claude_code"])
  end
end
```

Puis ajouter le nouveau sous-module `ClaudeCode` après le module `Codex` existant :

```elixir
defmodule ClaudeCode do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:command, :string, default: "claude")
    field(:model, :string)
    field(:turn_timeout_ms, :integer, default: 3_600_000)
    field(:allowed_tools, {:array, :string},
      default: ["Bash", "Read", "Write", "Edit", "Glob", "Grep"])
    field(:mcp_port, :integer, default: 4001)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:command, :model, :turn_timeout_ms, :allowed_tools, :mcp_port], empty_values: [])
    |> validate_required([:command])
    |> validate_number(:turn_timeout_ms, greater_than: 0)
    |> validate_number(:mcp_port, greater_than: 0)
  end
end
```

Dans le `embedded_schema` racine, ajouter après la ligne `embeds_one(:codex, ...)` :

```elixir
embeds_one(:claude_code, ClaudeCode, on_replace: :update, defaults_to_struct: true)
```

Dans la fonction `changeset/1` privée, ajouter après `cast_embed(:codex, ...)` :

```elixir
|> cast_embed(:claude_code, with: &ClaudeCode.changeset/2)
```

- [ ] **Étape 1.4 : Ajouter `agent_module/0` dans `Config`**

Dans `elixir/lib/symphony_elixir/config.ex`, ajouter cette fonction publique après `max_concurrent_agents_for_state/1` :

```elixir
@spec agent_module() :: module()
def agent_module do
  case settings!().agent.provider do
    "claude_code" -> SymphonyElixir.Agents.ClaudeCode
    _ -> SymphonyElixir.Agents.Codex
  end
end
```

- [ ] **Étape 1.5 : Mettre à jour `test_support.exs` pour les nouveaux champs**

Dans `elixir/test/support/test_support.exs`, dans la liste des overrides par défaut de `workflow_content`, ajouter :

```elixir
agent_provider: "codex",
claude_code_command: "claude",
claude_code_model: nil,
claude_code_turn_timeout_ms: 3_600_000,
claude_code_allowed_tools: ["Bash", "Read", "Write", "Edit", "Glob", "Grep"],
claude_code_mcp_port: 4001,
```

Dans la même fonction, extraire ces valeurs :

```elixir
agent_provider = Keyword.get(config, :agent_provider)
claude_code_command = Keyword.get(config, :claude_code_command)
claude_code_model = Keyword.get(config, :claude_code_model)
claude_code_turn_timeout_ms = Keyword.get(config, :claude_code_turn_timeout_ms)
claude_code_allowed_tools = Keyword.get(config, :claude_code_allowed_tools)
claude_code_mcp_port = Keyword.get(config, :claude_code_mcp_port)
```

Dans la liste `sections`, modifier la section `agent:` pour inclure `provider` :

```elixir
"agent:",
"  max_concurrent_agents: #{yaml_value(max_concurrent_agents)}",
"  max_turns: #{yaml_value(max_turns)}",
"  max_retry_backoff_ms: #{yaml_value(max_retry_backoff_ms)}",
"  max_concurrent_agents_by_state: #{yaml_value(max_concurrent_agents_by_state)}",
"  provider: #{yaml_value(agent_provider)}",
```

Et ajouter la section `claude_code:` après la section `codex:` :

```elixir
"claude_code:",
"  command: #{yaml_value(claude_code_command)}",
"  model: #{yaml_value(claude_code_model)}",
"  turn_timeout_ms: #{yaml_value(claude_code_turn_timeout_ms)}",
"  allowed_tools: #{yaml_value(claude_code_allowed_tools)}",
"  mcp_port: #{yaml_value(claude_code_mcp_port)}",
```

- [ ] **Étape 1.6 : Vérifier que les tests passent**

```bash
cd elixir && mix test test/symphony_elixir/workspace_and_config_test.exs 2>&1 | tail -20
```

Attendu : tous les tests passent.

- [ ] **Étape 1.7 : Vérifier que la suite complète ne régresse pas**

```bash
cd elixir && mix test 2>&1 | tail -10
```

Attendu : 0 failures.

- [ ] **Étape 1.8 : Commit**

```bash
cd elixir && rtk git add lib/symphony_elixir/config/schema.ex lib/symphony_elixir/config.ex test/support/test_support.exs test/symphony_elixir/workspace_and_config_test.exs
rtk git commit -m "feat(config): ajouter agent.provider et sous-module ClaudeCode"
```

---

## Tâche 2 : Behaviour `SymphonyElixir.Agent` + Wrapper `Agents.Codex`

**Fichiers :**
- Créer : `elixir/lib/symphony_elixir/agent.ex`
- Créer : `elixir/lib/symphony_elixir/agents/codex.ex`

- [ ] **Étape 2.1 : Créer le behaviour**

Créer `elixir/lib/symphony_elixir/agent.ex` :

```elixir
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
```

- [ ] **Étape 2.2 : Créer le wrapper `Agents.Codex`**

Créer `elixir/lib/symphony_elixir/agents/codex.ex` :

```elixir
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
```

- [ ] **Étape 2.3 : Vérifier la compilation**

```bash
cd elixir && mix compile 2>&1 | tail -10
```

Attendu : `Compiled lib/symphony_elixir/agent.ex` et `Compiled lib/symphony_elixir/agents/codex.ex`, 0 warnings.

- [ ] **Étape 2.4 : Commit**

```bash
cd elixir && rtk git add lib/symphony_elixir/agent.ex lib/symphony_elixir/agents/codex.ex
rtk git commit -m "feat(agent): behaviour Agent + wrapper Agents.Codex"
```

---

## Tâche 3 : `AgentRunner` + `Orchestrator` — migration behaviour et renommage messages

**Fichiers :**
- Modifier : `elixir/lib/symphony_elixir/agent_runner.ex`
- Modifier : `elixir/lib/symphony_elixir/orchestrator.ex`
- Modifier : `elixir/test/symphony_elixir/orchestrator_status_test.exs` (10 occurrences)
- Modifier : `elixir/test/symphony_elixir/core_test.exs` (1 occurrence)
- Modifier : `elixir/test/symphony_elixir/live_e2e_test.exs` (1 occurrence)

- [ ] **Étape 3.1 : Remplacer tous les `:codex_worker_update` par `:agent_worker_update` dans les tests**

```bash
cd elixir && sed -i '' 's/:codex_worker_update/:agent_worker_update/g' \
  test/symphony_elixir/orchestrator_status_test.exs \
  test/symphony_elixir/core_test.exs \
  test/symphony_elixir/live_e2e_test.exs
```

- [ ] **Étape 3.2 : Vérifier qu'aucune occurrence `:codex_worker_update` ne subsiste dans les tests**

```bash
cd elixir && grep -r "codex_worker_update" test/ || echo "OK: aucune occurrence"
```

Attendu : `OK: aucune occurrence`.

- [ ] **Étape 3.3 : Mettre à jour `agent_runner.ex`**

Remplacer le contenu de `elixir/lib/symphony_elixir/agent_runner.ex` par :

```elixir
defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with the configured agent.
  """

  require Logger
  alias SymphonyElixir.{Config, Linear.Issue, PromptBuilder, Tracker, Workspace}

  @type worker_host :: String.t() | nil

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, agent_update_recipient \\ nil, opts \\ []) do
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, agent_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, agent_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(agent_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            run_agent_turns(workspace, issue, agent_update_recipient, opts, worker_host)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp agent_message_handler(recipient, issue) do
    fn message ->
      send_agent_update(recipient, issue, message)
    end
  end

  defp send_agent_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:agent_worker_update, issue_id, message})
    :ok
  end

  defp send_agent_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp run_agent_turns(workspace, issue, agent_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)
    agent_mod = Config.agent_module()

    with {:ok, session} <- agent_mod.start_session(workspace, worker_host: worker_host) do
      try do
        do_run_agent_turns(agent_mod, session, workspace, issue, agent_update_recipient, opts, issue_state_fetcher, 1, max_turns)
      after
        agent_mod.stop_session(session)
      end
    end
  end

  defp do_run_agent_turns(agent_mod, session, workspace, issue, agent_update_recipient, opts, issue_state_fetcher, turn_number, max_turns) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    with {:ok, turn_session} <-
           agent_mod.run_turn(
             session,
             prompt,
             issue,
             on_message: agent_message_handler(agent_update_recipient, issue)
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      case continue_with_issue?(issue, issue_state_fetcher) do
        {:continue, refreshed_issue} when turn_number < max_turns ->
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

          do_run_agent_turns(
            agent_mod,
            session,
            workspace,
            refreshed_issue,
            agent_update_recipient,
            opts,
            issue_state_fetcher,
            turn_number + 1,
            max_turns
          )

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")
          :ok

        {:done, _refreshed_issue} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous agent turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
```

- [ ] **Étape 3.4 : Mettre à jour `orchestrator.ex` — renommer les deux clauses `handle_info`**

Dans `elixir/lib/symphony_elixir/orchestrator.ex`, remplacer les deux clauses :

```elixir
# Remplacer cette clause (ligne ~183)
def handle_info(
      {:codex_worker_update, issue_id, %{event: _, timestamp: _} = update},
      %{running: running} = state
    ) do
```

par :

```elixir
def handle_info(
      {:agent_worker_update, issue_id, %{event: _, timestamp: _} = update},
      %{running: running} = state
    ) do
```

Et remplacer la clause catch-all (ligne ~204) :

```elixir
def handle_info({:codex_worker_update, _issue_id, _update}, state), do: {:noreply, state}
```

par :

```elixir
def handle_info({:agent_worker_update, _issue_id, _update}, state), do: {:noreply, state}
```

- [ ] **Étape 3.5 : Vérifier qu'aucune occurrence `:codex_worker_update` ne subsiste dans les sources**

```bash
cd elixir && grep -r "codex_worker_update" lib/ || echo "OK: aucune occurrence"
```

Attendu : `OK: aucune occurrence`.

- [ ] **Étape 3.6 : Lancer toute la suite de tests**

```bash
cd elixir && mix test 2>&1 | tail -15
```

Attendu : 0 failures.

- [ ] **Étape 3.7 : Commit**

```bash
cd elixir && rtk git add lib/symphony_elixir/agent_runner.ex lib/symphony_elixir/orchestrator.ex \
  test/symphony_elixir/orchestrator_status_test.exs \
  test/symphony_elixir/core_test.exs \
  test/symphony_elixir/live_e2e_test.exs
rtk git commit -m "refactor(runner): migrer vers behaviour Agent, renommer codex_worker_update"
```

---

## Tâche 4 : Serveur MCP — contrôleur + routes

**Fichiers :**
- Créer : `elixir/lib/symphony_elixir_web/controllers/mcp_controller.ex`
- Modifier : `elixir/lib/symphony_elixir_web/router.ex`
- Test : `elixir/test/symphony_elixir/mcp_controller_test.exs`

- [ ] **Étape 4.1 : Écrire les tests qui vont échouer**

Créer `elixir/test/symphony_elixir/mcp_controller_test.exs` :

```elixir
defmodule SymphonyElixirWeb.MCPControllerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool

  setup do
    {:ok, pid} = SymphonyElixir.HttpServer.start_link(port: 0)
    port = SymphonyElixir.HttpServer.port(pid)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {:ok, port: port}
  end

  test "tools/list retourne les tool_specs de DynamicTool", %{port: port} do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list", "params" => %{}})

    {:ok, response} = :httpc.request(:post,
      {~c"http://127.0.0.1:#{port}/mcp/messages", [], ~c"application/json", body},
      [], [body_format: :binary])

    {{_, 200, _}, _headers, resp_body} = response
    decoded = Jason.decode!(resp_body)

    assert decoded["id"] == 1
    assert is_list(decoded["result"]["tools"])
    assert Enum.any?(decoded["result"]["tools"], &(&1["name"] == "linear_graphql"))
  end

  test "tools/call linear_graphql délègue à DynamicTool", %{port: port} do
    body = Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => 2,
      "method" => "tools/call",
      "params" => %{
        "name" => "linear_graphql",
        "arguments" => %{"query" => "{ viewer { id } }"}
      }
    })

    {:ok, response} = :httpc.request(:post,
      {~c"http://127.0.0.1:#{port}/mcp/messages", [], ~c"application/json", body},
      [], [body_format: :binary])

    {{_, 200, _}, _headers, resp_body} = response
    decoded = Jason.decode!(resp_body)

    assert decoded["id"] == 2
    assert is_map(decoded["result"])
  end

  test "initialize répond avec les capacités du serveur", %{port: port} do
    body = Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => 0,
      "method" => "initialize",
      "params" => %{"protocolVersion" => "2024-11-05", "capabilities" => %{}}
    })

    {:ok, response} = :httpc.request(:post,
      {~c"http://127.0.0.1:#{port}/mcp/messages", [], ~c"application/json", body},
      [], [body_format: :binary])

    {{_, 200, _}, _headers, resp_body} = response
    decoded = Jason.decode!(resp_body)

    assert decoded["id"] == 0
    assert decoded["result"]["protocolVersion"] == "2024-11-05"
    assert is_map(decoded["result"]["capabilities"])
  end

  test "méthode inconnue retourne une erreur JSON-RPC", %{port: port} do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 99, "method" => "unknown/method", "params" => %{}})

    {:ok, response} = :httpc.request(:post,
      {~c"http://127.0.0.1:#{port}/mcp/messages", [], ~c"application/json", body},
      [], [body_format: :binary])

    {{_, 200, _}, _headers, resp_body} = response
    decoded = Jason.decode!(resp_body)

    assert decoded["id"] == 99
    assert is_map(decoded["error"])
    assert decoded["error"]["code"] == -32601
  end
end
```

- [ ] **Étape 4.2 : Vérifier que les tests échouent**

```bash
cd elixir && mix test test/symphony_elixir/mcp_controller_test.exs 2>&1 | tail -10
```

Attendu : erreur de compilation (module inexistant).

- [ ] **Étape 4.3 : Créer le contrôleur MCP**

Créer `elixir/lib/symphony_elixir_web/controllers/mcp_controller.ex` :

```elixir
defmodule SymphonyElixirWeb.MCPController do
  @moduledoc """
  Endpoint MCP (Model Context Protocol) pour exposer les outils dynamiques de Symphony à Claude Code.
  Implémente un sous-ensemble minimal du protocole MCP 2024-11-05 via JSON-RPC 2.0.
  """

  use Phoenix.Controller, formats: [:json]

  alias SymphonyElixir.Codex.DynamicTool

  @protocol_version "2024-11-05"
  @server_name "symphony-mcp"
  @server_version "1.0.0"

  @doc """
  SSE stream pour l'établissement de la connexion MCP.
  Claude Code se connecte ici pour récupérer l'URL de l'endpoint de messages.
  """
  def sse(conn, _params) do
    messages_url = build_messages_url(conn)

    conn
    |> put_resp_header("content-type", "text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> send_chunked(200)
    |> send_sse_event("endpoint", messages_url)
  end

  @doc """
  Endpoint JSON-RPC 2.0 pour les appels d'outils MCP.
  """
  def message(conn, _params) do
    with {:ok, body, conn} <- read_body(conn),
         {:ok, request} <- Jason.decode(body) do
      response = handle_request(request)
      json(conn, response)
    else
      _ ->
        conn
        |> put_status(400)
        |> json(%{"jsonrpc" => "2.0", "id" => nil, "error" => %{"code" => -32700, "message" => "Parse error"}})
    end
  end

  defp handle_request(%{"method" => "initialize", "id" => id}) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "protocolVersion" => @protocol_version,
        "capabilities" => %{"tools" => %{}},
        "serverInfo" => %{"name" => @server_name, "version" => @server_version}
      }
    }
  end

  defp handle_request(%{"method" => "notifications/initialized"}) do
    %{"jsonrpc" => "2.0", "id" => nil, "result" => %{}}
  end

  defp handle_request(%{"method" => "tools/list", "id" => id}) do
    tools =
      DynamicTool.tool_specs()
      |> Enum.map(fn spec ->
        %{
          "name" => spec["name"],
          "description" => spec["description"],
          "inputSchema" => spec["inputSchema"]
        }
      end)

    %{"jsonrpc" => "2.0", "id" => id, "result" => %{"tools" => tools}}
  end

  defp handle_request(%{"method" => "tools/call", "id" => id, "params" => %{"name" => tool, "arguments" => args}}) do
    result = DynamicTool.execute(tool, args)

    content = [%{"type" => "text", "text" => Map.get(result, "output", inspect(result))}]

    is_error = Map.get(result, "success") == false

    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "content" => content,
        "isError" => is_error
      }
    }
  end

  defp handle_request(%{"id" => id, "method" => method}) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{
        "code" => -32601,
        "message" => "Method not found: #{method}"
      }
    }
  end

  defp handle_request(_request) do
    %{
      "jsonrpc" => "2.0",
      "id" => nil,
      "error" => %{"code" => -32600, "message" => "Invalid Request"}
    }
  end

  defp build_messages_url(conn) do
    scheme = if conn.scheme == :https, do: "https", else: "http"
    "#{scheme}://#{conn.host}:#{conn.port}/mcp/messages"
  end

  defp send_sse_event(conn, event_name, data) do
    chunk(conn, "event: #{event_name}\ndata: #{data}\n\n")
    conn
  end
end
```

- [ ] **Étape 4.4 : Ajouter les routes MCP dans `router.ex`**

Dans `elixir/lib/symphony_elixir_web/router.ex`, ajouter un nouveau scope avant le scope API final :

```elixir
scope "/mcp", SymphonyElixirWeb do
  get("/sse", MCPController, :sse)
  post("/messages", MCPController, :message)
end
```

Ce scope doit être ajouté **avant** le scope `match(:*, "/*path", ...)` existant.

Le router complet doit ressembler à :

```elixir
defmodule SymphonyElixirWeb.Router do
  @moduledoc """
  Router for Symphony's observability dashboard and API.
  """

  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {SymphonyElixirWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", SymphonyElixirWeb do
    get("/dashboard.css", StaticAssetController, :dashboard_css)
    get("/vendor/phoenix_html/phoenix_html.js", StaticAssetController, :phoenix_html_js)
    get("/vendor/phoenix/phoenix.js", StaticAssetController, :phoenix_js)
    get("/vendor/phoenix_live_view/phoenix_live_view.js", StaticAssetController, :phoenix_live_view_js)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:browser)

    live("/", DashboardLive, :index)
  end

  scope "/mcp", SymphonyElixirWeb do
    get("/sse", MCPController, :sse)
    post("/messages", MCPController, :message)
  end

  scope "/", SymphonyElixirWeb do
    get("/api/v1/state", ObservabilityApiController, :state)

    match(:*, "/", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/state", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/refresh", ObservabilityApiController, :refresh)
    match(:*, "/api/v1/refresh", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/:issue_identifier", ObservabilityApiController, :issue)
    match(:*, "/api/v1/:issue_identifier", ObservabilityApiController, :method_not_allowed)
    match(:*, "/*path", ObservabilityApiController, :not_found)
  end
end
```

- [ ] **Étape 4.5 : Lancer les tests MCP**

```bash
cd elixir && mix test test/symphony_elixir/mcp_controller_test.exs 2>&1 | tail -15
```

Attendu : tous les tests passent.

- [ ] **Étape 4.6 : Vérifier la suite complète**

```bash
cd elixir && mix test 2>&1 | tail -10
```

Attendu : 0 failures.

- [ ] **Étape 4.7 : Commit**

```bash
cd elixir && rtk git add lib/symphony_elixir_web/controllers/mcp_controller.ex \
  lib/symphony_elixir_web/router.ex \
  test/symphony_elixir/mcp_controller_test.exs
rtk git commit -m "feat(mcp): endpoint SSE+JSON-RPC pour exposer les outils dynamiques à Claude Code"
```

---

## Tâche 5 : `Agents.ClaudeCode` — `start_session` + `stop_session`

**Fichiers :**
- Créer : `elixir/lib/symphony_elixir/agents/claude_code.ex`
- Test : `elixir/test/symphony_elixir/agents/claude_code_test.exs`

- [ ] **Étape 5.1 : Écrire les tests qui vont échouer**

Créer `elixir/test/symphony_elixir/agents/claude_code_test.exs` :

```elixir
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
```

- [ ] **Étape 5.2 : Vérifier que les tests échouent**

```bash
cd elixir && mix test test/symphony_elixir/agents/claude_code_test.exs 2>&1 | tail -10
```

Attendu : erreur de compilation (module inexistant).

- [ ] **Étape 5.3 : Créer `Agents.ClaudeCode` avec `start_session` et `stop_session`**

Créer `elixir/lib/symphony_elixir/agents/claude_code.ex` :

```elixir
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

    case Jason.encode(mcp_config) do
      {:ok, json} ->
        case File.write(mcp_config_path, json) do
          :ok ->
            {:ok,
             %{
               workspace: workspace,
               session_id: nil,
               mcp_config_path: mcp_config_path
             }}

          {:error, reason} ->
            {:error, {:mcp_config_write_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:mcp_config_encode_failed, reason}}
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

        case await_completion(port, settings.turn_timeout_ms, on_message, issue) do
          {:ok, session_id, result} ->
            {:ok, %{session_id: session_id, result: result}}

          {:error, reason} ->
            {:error, reason}
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
        Port.close(port)
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
        reason = String.to_atom(subtype)
        on_message.(%{event: :turn_ended_with_error, reason: reason, payload: payload, timestamp: DateTime.utc_now()})
        {:error, {:turn_failed, reason}}

      {:ok, %{"type" => "assistant"} = payload} ->
        on_message.(%{event: :notification, payload: payload, timestamp: DateTime.utc_now()})
        read_stream(port, timeout_ms, on_message, issue, session_id, "")

      {:ok, payload} ->
        on_message.(%{event: :other_message, payload: payload, timestamp: DateTime.utc_now()})
        read_stream(port, timeout_ms, on_message, issue, session_id, "")

      {:error, _} ->
        line_trimmed = String.trim(line)

        unless line_trimmed == "" do
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
```

- [ ] **Étape 5.4 : Lancer les tests `start_session` / `stop_session`**

```bash
cd elixir && mix test test/symphony_elixir/agents/claude_code_test.exs 2>&1 | tail -15
```

Attendu : tous les tests passent.

- [ ] **Étape 5.5 : Vérifier la suite complète**

```bash
cd elixir && mix test 2>&1 | tail -10
```

Attendu : 0 failures.

- [ ] **Étape 5.6 : Commit**

```bash
cd elixir && rtk git add lib/symphony_elixir/agents/claude_code.ex \
  test/symphony_elixir/agents/claude_code_test.exs
rtk git commit -m "feat(claude-code): implémentation Agents.ClaudeCode avec start/run_turn/stop"
```

---

## Tâche 6 : Tests d'intégration `AgentRunner` avec mock du behaviour

**Fichiers :**
- Test : `elixir/test/symphony_elixir/agent_runner_behaviour_test.exs`

- [ ] **Étape 6.1 : Créer les tests d'intégration**

Créer `elixir/test/symphony_elixir/agent_runner_behaviour_test.exs` :

```elixir
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

    assert_receive {:agent_worker_update, "issue-behaviour-test", %{event: :turn_completed}}, 2_000
  end
end
```

> **Note :** Pour que ce test fonctionne, `AgentRunner.run_agent_turns/5` doit lire `agent_module` depuis les opts si fourni (pour les tests), sinon depuis `Config.agent_module()`. Ajouter dans `agent_runner.ex` :
>
> ```elixir
> defp run_agent_turns(workspace, issue, agent_update_recipient, opts, worker_host) do
>   max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
>   issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)
>   agent_mod = Keyword.get(opts, :agent_module, Config.agent_module())   # ← ajout
>   ...
> end
> ```

- [ ] **Étape 6.2 : Appliquer le changement dans `agent_runner.ex`**

Dans `elixir/lib/symphony_elixir/agent_runner.ex`, dans `run_agent_turns/5`, remplacer :

```elixir
agent_mod = Config.agent_module()
```

par :

```elixir
agent_mod = Keyword.get(opts, :agent_module, Config.agent_module())
```

- [ ] **Étape 6.3 : Lancer le test d'intégration**

```bash
cd elixir && mix test test/symphony_elixir/agent_runner_behaviour_test.exs 2>&1 | tail -15
```

Attendu : test passe.

- [ ] **Étape 6.4 : Vérifier la suite complète**

```bash
cd elixir && mix test 2>&1 | tail -10
```

Attendu : 0 failures.

- [ ] **Étape 6.5 : Commit**

```bash
cd elixir && rtk git add lib/symphony_elixir/agent_runner.ex \
  test/symphony_elixir/agent_runner_behaviour_test.exs
rtk git commit -m "test(runner): test d'intégration AgentRunner avec mock du behaviour Agent"
```

---

## Récapitulatif des commits attendus

1. `feat(config): ajouter agent.provider et sous-module ClaudeCode`
2. `feat(agent): behaviour Agent + wrapper Agents.Codex`
3. `refactor(runner): migrer vers behaviour Agent, renommer codex_worker_update`
4. `feat(mcp): endpoint SSE+JSON-RPC pour exposer les outils dynamiques à Claude Code`
5. `feat(claude-code): implémentation Agents.ClaudeCode avec start/run_turn/stop`
6. `test(runner): test d'intégration AgentRunner avec mock du behaviour Agent`

## Vérification finale

```bash
cd elixir && mix compile --warnings-as-errors && mix test
```

Attendu : 0 warnings, 0 failures.
