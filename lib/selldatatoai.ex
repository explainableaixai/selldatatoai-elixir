defmodule SellDataToAI do
  @moduledoc """
  Elixir client for the AI Data Value Score API at https://www.selldatatoai.com/api/ .

      client = SellDataToAI.new(System.fetch_env!("SDA_API_KEY"))
      {:ok, score} = SellDataToAI.score(client, "example.com")
      score["data_asset_score"]

  Every function returns `{:ok, map}` or `{:error, %SellDataToAI.Error{}}`.
  Maps keep the API field names as string keys.
  """

  @version Mix.Project.config()[:version]
  @default_base "https://www.selldatatoai.com/api/v1"
  @batch_max 100

  defstruct api_key: nil, base_url: @default_base, timeout: 60_000, poll_interval: 5_000, max_wait: 300_000

  @type t :: %__MODULE__{}

  defmodule Error do
    @moduledoc "Non-2xx answer (`status` > 0) or transport failure (`status` 0)."
    defexception [:status, :code, :message, :body]
  end

  @doc "Build a client. Options: `:base_url`, `:timeout`, `:poll_interval`, `:max_wait` (milliseconds)."
  @spec new(String.t(), keyword) :: t
  def new(api_key, opts \\ []) when is_binary(api_key) and api_key != "" do
    struct!(__MODULE__, Keyword.put(opts, :api_key, api_key))
  end

  @doc "The largest batch the API accepts."
  def batch_max, do: @batch_max

  @doc "Score one company domain. Full URLs are accepted."
  def score(%__MODULE__{} = c, domain) when is_binary(domain) do
    request(c, :get, "/score", [domain: String.trim(domain)], nil)
  end

  @doc "Submit 1 to 100 domains. One lookup per valid, unique domain."
  def submit_batch(%__MODULE__{} = c, domains) when is_list(domains) do
    n = length(domains)

    if n == 0 or n > @batch_max do
      {:error, %Error{status: 0, code: "bad_input", message: "a batch takes 1 to #{@batch_max} domains"}}
    else
      request(c, :post, "/score/batch", [], %{"domains" => domains})
    end
  end

  @doc "Poll a batch. Polling is free."
  def get_batch(%__MODULE__{} = c, id), do: request(c, :get, "/score/batch", [id: id], nil)

  @doc "Poll until the batch status is `done` or `max_wait` passes."
  def wait_for_batch(%__MODULE__{} = c, id) do
    deadline = System.monotonic_time(:millisecond) + c.max_wait
    poll(c, id, deadline)
  end

  defp poll(c, id, deadline) do
    case get_batch(c, id) do
      {:ok, %{"status" => "done"} = b} ->
        {:ok, b}

      {:ok, b} ->
        if System.monotonic_time(:millisecond) > deadline do
          {:error, %Error{status: 0, code: "batch_timeout", message: "batch #{id} still processing", body: b}}
        else
          Process.sleep(c.poll_interval)
          poll(c, id, deadline)
        end

      err ->
        err
    end
  end

  @doc "Score any number of domains in batches of 100. Returns the result items in input order."
  def score_many(%__MODULE__{} = c, domains) when is_list(domains) do
    domains
    |> Enum.chunk_every(@batch_max)
    |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, acc} ->
      with {:ok, sent} <- submit_batch(c, chunk),
           {:ok, done} <- finish(c, sent) do
        {:cont, {:ok, acc ++ Map.get(done, "results", [])}}
      else
        err -> {:halt, err}
      end
    end)
  end

  defp finish(_c, %{"status" => "done"} = b), do: {:ok, b}
  defp finish(c, %{"id" => id}), do: wait_for_batch(c, id)

  @doc "Plan, lookups used this month and lookups remaining."
  def usage(%__MODULE__{} = c), do: request(c, :get, "/usage", [], nil)

  defp request(c, method, path, query, body) do
    :inets.start()
    :ssl.start()
    qs = if query == [], do: "", else: "?" <> URI.encode_query(query)
    url = String.to_charlist(String.trim_trailing(c.base_url, "/") <> path <> qs)

    headers = [
      {~c"x-api-key", String.to_charlist(c.api_key)},
      {~c"accept", ~c"application/json"},
      {~c"user-agent", String.to_charlist("selldatatoai-elixir/#{@version} (+https://www.selldatatoai.com)")}
    ]

    req =
      case body do
        nil -> {url, headers}
        b -> {url, headers, ~c"application/json", Jason.encode!(b)}
      end

    http_opts = [timeout: c.timeout, ssl: ssl_opts()]

    case :httpc.request(method, req, http_opts, body_format: :binary) do
      {:ok, {{_, status, _}, _h, resp}} -> decode(status, resp)
      {:error, reason} -> {:error, %Error{status: 0, code: "transport", message: inspect(reason)}}
    end
  end

  defp ssl_opts do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 4,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  defp decode(status, resp) do
    data =
      case Jason.decode(resp) do
        {:ok, d} -> d
        _ -> nil
      end

    cond do
      status in 200..299 and is_map(data) ->
        {:ok, data}

      is_map(data) ->
        {:error, %Error{status: status, code: data["error"], message: data["message"] || "HTTP #{status}", body: data}}

      true ->
        {:error, %Error{status: status, code: nil, message: "HTTP #{status}", body: resp}}
    end
  end
end
