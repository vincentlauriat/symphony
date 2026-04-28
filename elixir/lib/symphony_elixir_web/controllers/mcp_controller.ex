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

  def sse(conn, _params) do
    messages_url = build_messages_url(conn)

    conn
    |> put_resp_header("content-type", "text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> send_chunked(200)
    |> send_sse_event("endpoint", messages_url)
  end

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
