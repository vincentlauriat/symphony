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
