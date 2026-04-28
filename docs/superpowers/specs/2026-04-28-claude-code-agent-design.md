# Design : Support de Claude Code comme agent dans Symphony

**Date :** 2026-04-28  
**Statut :** Approuvé  
**Portée :** Ajout de Claude Code CLI comme agent alternatif configurable, en conservant le support Codex existant.

---

## Contexte

Symphony est un orchestrateur Elixir/OTP qui poll Linear, crée des workspaces isolés par issue, et lance un agent de code autonome (actuellement Codex via le protocole app-server JSON-line) pour implémenter les tickets.

L'objectif est d'ajouter Claude Code CLI comme second agent configurable, avec sélection globale ou par workflow, tout en gardant Codex opérationnel.

---

## Architecture générale

```
lib/symphony_elixir/
├── agent.ex                    # NOUVEAU : Behaviour @callback
├── agents/
│   ├── codex.ex               # NOUVEAU : Wrapper de Codex.AppServer
│   └── claude_code.ex         # NOUVEAU : Implémentation Claude Code CLI
├── mcp/
│   └── linear_server.ex       # NOUVEAU : Endpoint MCP SSE pour linear_graphql
├── agent_runner.ex            # MODIFIÉ : utilise le behaviour
└── config/
    └── schema.ex              # MODIFIÉ : agent.provider + section claude_code
```

---

## Composant 1 : Behaviour `SymphonyElixir.Agent`

Interface commune que toutes les implémentations d'agent doivent respecter.

```elixir
defmodule SymphonyElixir.Agent do
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

Le module actif est résolu dynamiquement via `Config.agent_module/0` qui retourne l'atom du module selon `agent.provider`.

---

## Composant 2 : `SymphonyElixir.Agents.Codex`

Wrapper fin autour du `Codex.AppServer` existant, sans modification de ce dernier. Implémente les trois callbacks en déléguant directement, en transmettant tous les opts (y compris `worker_host`) à `AppServer`.

---

## Composant 3 : `SymphonyElixir.Agents.ClaudeCode`

### Différence clé avec Codex

Codex maintient un port stdio persistant entre les turns (protocol app-server bidirectionnel). Claude Code CLI, lui, exit après chaque invocation — la session est continuée via `--resume <session_id>`.

### `start_session/2`

1. Génère un fichier `.symphony_mcp.json` dans le workspace de l'issue pointant vers le serveur MCP de Symphony.
2. Retourne `{:ok, %{workspace: workspace, session_id: nil, mcp_config_path: path}}`.

> **Note :** L'option `worker_host` est ignorée — le support SSH pour Claude Code est hors scope (voir section "Ce qui est hors scope").

Pas de port persistant — le port est ouvert et fermé à chaque `run_turn`.

```elixir
def start_session(workspace, _opts \\ []) do
  mcp_config_path = Path.join(workspace, ".symphony_mcp.json")
  mcp_port = Config.settings!().claude_code.mcp_port

  File.write!(mcp_config_path, Jason.encode!(%{
    "mcpServers" => %{
      "symphony" => %{"type" => "sse", "url" => "http://127.0.0.1:#{mcp_port}/mcp/sse"}
    }
  }))

  {:ok, %{workspace: workspace, session_id: nil, mcp_config_path: mcp_config_path}}
end
```

### `run_turn/4`

Construit la commande CLI, ouvre un Port, envoie le prompt sur stdin, lit le stream JSON ligne par ligne.

```elixir
defp build_command(nil, mcp_config, model, allowed_tools) do
  tools = Enum.join(allowed_tools, ",")
  "claude --output-format stream-json --print --allowedTools #{tools} --mcp-config #{mcp_config}#{model_flag(model)}"
end

defp build_command(session_id, mcp_config, model, allowed_tools) do
  tools = Enum.join(allowed_tools, ",")
  "claude --output-format stream-json --print --resume #{session_id} --allowedTools #{tools} --mcp-config #{mcp_config}#{model_flag(model)}"
end
```

**Événements stream-json surveillés :**

| Type | Sous-type | Action |
|------|-----------|--------|
| `system` | `init` | Capture `session_id` |
| `result` | `success` | Retourne `{:ok, result}` |
| `result` | `error_max_turns` | Retourne `{:error, :max_turns}` |
| Exit status du port | — | Retourne `{:error, {:port_exit, status}}` |

### `stop_session/1`

Supprime le fichier `.symphony_mcp.json` du workspace.

---

## Composant 4 : Serveur MCP pour les outils dynamiques

Les outils dynamiques (ex: `linear_graphql`) sont exposés à Claude Code via MCP plutôt que via le protocole app-server de Codex. Symphony ajoute deux routes Phoenix (Bandit est déjà présent) :

```
GET  /mcp/sse       — SSE stream (connexion MCP initiale)
POST /mcp/messages  — Réception des appels d'outils
```

Le contrôleur délègue à `DynamicTool.execute/2` **sans modification** de ce module. `DynamicTool` continue de servir simultanément Codex (via app-server) et Claude Code (via MCP).

### Méthodes MCP implémentées

- `tools/list` → retourne `DynamicTool.tool_specs()`
- `tools/call` → délègue à `DynamicTool.execute(tool, args)`
- `initialize` / `notifications/initialized` → handshake MCP standard

---

## Composant 5 : Configuration

### Nouveaux champs dans `Config.Schema`

```elixir
# Dans Agent (existant) — ajout du champ provider
field(:provider, :string, default: "codex")   # "codex" | "claude_code"

# Nouveau sous-module ClaudeCode
defmodule ClaudeCode do
  embedded_schema do
    field(:command, :string, default: "claude")
    field(:model, :string)                                # nil = Claude Code choisit
    field(:turn_timeout_ms, :integer, default: 3_600_000)
    field(:allowed_tools, {:array, :string},
      default: ["Bash", "Read", "Write", "Edit", "Glob", "Grep"])
    field(:mcp_port, :integer, default: 4001)
  end
end
```

### Exemple `config.yaml`

```yaml
agent:
  provider: claude_code
  max_concurrent_agents: 5
  max_turns: 20

claude_code:
  model: claude-sonnet-4-6
  mcp_port: 4001
  allowed_tools:
    - Bash
    - Read
    - Write
    - Edit
    - Glob
    - Grep
```

### Override par `WORKFLOW.md`

```yaml
---
agent:
  provider: claude_code
---
Implémente les issues Linear assignées...
```

### Résolution du module

```elixir
# Dans Config
def agent_module(settings \\ settings!()) do
  case settings.agent.provider do
    "claude_code" -> SymphonyElixir.Agents.ClaudeCode
    _ -> SymphonyElixir.Agents.Codex
  end
end
```

---

## Composant 6 : Modifications de `AgentRunner`

### Changements

1. Remplacer `alias SymphonyElixir.Codex.AppServer` par une résolution dynamique via `Config.agent_module()`.
2. Renommer `run_codex_turns` → `run_agent_turns` et `send_codex_update` → `send_agent_update`.
3. Renommer le message envoyé au recipient : `:codex_worker_update` → `:agent_worker_update` (propager dans `Orchestrator` et `DashboardLive`).
4. Mettre à jour le texte du continuation prompt : remplacer `"The previous Codex turn..."` par `"The previous agent turn..."`.

### Ce qui ne change pas

- La logique de retry/continuation par turns reste identique.
- La validation du workspace, les hooks before/after, et la réconciliation d'état sont inchangés.

---

## Flux de données (Claude Code)

```
Orchestrator
  └─ AgentRunner.run(issue)
       └─ ClaudeCode.start_session(workspace)      → génère .symphony_mcp.json
       └─ ClaudeCode.run_turn(session, prompt, ...) → Port.open("claude --output-format stream-json ...")
            ├─ stream JSON ligne par ligne
            ├─ MCP handshake si l'agent appelle linear_graphql
            │    └─ MCPController → DynamicTool.execute("linear_graphql", args)
            └─ {"type":"result","subtype":"success"} → {:ok, turn_result}
       └─ [si issue encore active] run_turn avec --resume <session_id>
       └─ ClaudeCode.stop_session(session)          → supprime .symphony_mcp.json
```

---

## Gestion des erreurs

| Scénario | Comportement |
|----------|-------------|
| `claude` non trouvé dans PATH | `start_session` retourne `{:error, :claude_not_found}` |
| Timeout de turn | `{:error, :turn_timeout}` — backoff exponentiel géré par l'orchestrateur |
| `ANTHROPIC_API_KEY` manquante | Claude Code exit immédiatement avec exit status non-zéro → `{:error, {:port_exit, status}}` |
| MCP server indisponible | Claude Code continue sans l'outil (outils natifs toujours disponibles) |

---

## Tests

- **Unit** : `ClaudeCode.start_session/2` et `stop_session/1` — vérifier création/suppression du fichier MCP.
- **Unit** : `ClaudeCode.await_completion/2` — tester le parsing du stream JSON avec des fixtures.
- **Unit** : `MCPController` — tester `tools/list` et `tools/call` avec `DynamicTool` mocké.
- **Integration** : `AgentRunner` avec un agent mock implémentant le behaviour — vérifier le dispatch correct.
- **E2E** : Conserver les tests E2E existants contre Codex ; ajouter un test E2E optionnel pour Claude Code (nécessite `ANTHROPIC_API_KEY`).

---

## Ce qui est hors scope

- Support SSH pour Claude Code (sera ajouté séparément si nécessaire).
- Métriques de tokens pour Claude Code (le stream-json expose `usage` — peut être ajouté ultérieurement).
- Interface de sélection d'agent dans le dashboard LiveView.
