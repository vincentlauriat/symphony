defmodule SymphonyElixirWeb.MCPControllerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool

  setup do
    start_supervised!({SymphonyElixir.HttpServer, [host: "127.0.0.1", port: 0]})
    port = wait_for_bound_port()
    {:ok, port: port}
  end

  defp wait_for_bound_port(attempts \\ 20)
  defp wait_for_bound_port(0), do: raise("Timeout waiting for HTTP server port")
  defp wait_for_bound_port(attempts) do
    case HttpServer.bound_port() do
      port when is_integer(port) -> port
      _ ->
        Process.sleep(25)
        wait_for_bound_port(attempts - 1)
    end
  end

  test "tools/list retourne les tool_specs de DynamicTool", %{port: port} do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list", "params" => %{}})

    response = Req.post!("http://127.0.0.1:#{port}/mcp/messages",
      headers: [{"content-type", "application/json"}],
      body: body)

    assert response.status == 200
    decoded = response.body

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

    response = Req.post!("http://127.0.0.1:#{port}/mcp/messages",
      headers: [{"content-type", "application/json"}],
      body: body)

    assert response.status == 200
    decoded = response.body

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

    response = Req.post!("http://127.0.0.1:#{port}/mcp/messages",
      headers: [{"content-type", "application/json"}],
      body: body)

    assert response.status == 200
    decoded = response.body

    assert decoded["id"] == 0
    assert decoded["result"]["protocolVersion"] == "2024-11-05"
    assert is_map(decoded["result"]["capabilities"])
  end

  test "méthode inconnue retourne une erreur JSON-RPC", %{port: port} do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 99, "method" => "unknown/method", "params" => %{}})

    response = Req.post!("http://127.0.0.1:#{port}/mcp/messages",
      headers: [{"content-type", "application/json"}],
      body: body)

    assert response.status == 200
    decoded = response.body

    assert decoded["id"] == 99
    assert is_map(decoded["error"])
    assert decoded["error"]["code"] == -32601
  end
end
