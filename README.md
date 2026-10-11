# SellDataToAI for Elixir

An Elixir client for the AI Data Value Score API at [www.selldatatoai.com](https://www.selldatatoai.com/). Give it a company website and it returns that company's AI Data Value Score, a number from 0 to 100 that estimates how much of the data AI buyers want the company holds.

```elixir
def deps do
  [{:selldatatoai, "~> 1.0"}]
end
```

- HTTP through OTP's built-in `:httpc`, with peer verification on.
- One runtime dependency: `jason`.
- Elixir 1.14 or newer, OTP 25 or newer.
- Tagged tuples everywhere: `{:ok, map}` or `{:error, %SellDataToAI.Error{}}`.

## Why a score per company

Every AI data deal starts with a list of possible sellers. Most of those companies are the wrong fit: too young, too small, no exportable systems, or already shutting down. The score sorts that list before anyone spends time on it.

Answers come from an index of 120 million domains, 99.99% of the active internet, with domain history. Each answer names the systems of record the company runs and the data types it likely holds, so you know what to pitch, not just whom.

If you are building a brokerage around this, the guide on [how to become an AI data broker](https://www.selldatatoai.com/how-to-become-an-ai-data-broker/) is frank about the economics. The companion piece on the [data broker business model](https://www.selldatatoai.com/data-broker-business-model/) shows how the money moves and when it arrives.

## Getting started

```elixir
client = SellDataToAI.new(System.fetch_env!("SDA_API_KEY"))

{:ok, s} = SellDataToAI.score(client, "example.com")

IO.puts("#{s["domain"]}: #{s["data_asset_score"]} (#{s["grade"]})")

for sys <- s["data_systems"] do
  IO.puts("  #{sys["system"]} holds #{sys["data_type"]}")
end
```

Maps keep the API's string keys exactly, so what you read in the [endpoint reference](https://www.selldatatoai.com/api/) is what you pattern match on:

```elixir
case SellDataToAI.score(client, website) do
  {:ok, %{"verified_active" => true, "grade" => g} = s} when g in ["A", "B"] ->
    {:shortlist, s}

  {:ok, %{"status" => "winding_down_or_acquired"} = s} ->
    {:watch, s}

  {:ok, s} ->
    {:skip, s}

  {:error, %SellDataToAI.Error{status: 400}} ->
    {:invalid, website}

  {:error, err} ->
    {:retry_later, err}
end
```

Options for `new/2`:

| Option | Default | Meaning |
|---|---|---|
| `:base_url` | `https://www.selldatatoai.com/api/v1` | API root |
| `:timeout` | `60_000` | per request, ms |
| `:poll_interval` | `5_000` | between batch polls, ms |
| `:max_wait` | `300_000` | longest wait for one batch, ms |

## Functions

| Function | Endpoint | Lookups |
|---|---|---|
| `score(client, domain)` | `GET /api/v1/score` | 1 |
| `submit_batch(client, domains)` | `POST /api/v1/score/batch` | 1 per valid, unique domain |
| `get_batch(client, id)` | `GET /api/v1/score/batch?id=` | 0 |
| `wait_for_batch(client, id)` | polls `get_batch` | 0 |
| `score_many(client, domains)` | batches of 100, in order | 1 per valid, unique domain |
| `usage(client)` | `GET /api/v1/usage` | 0 |
| `batch_max()` | | the limit, 100 |

## The error struct

```elixir
%SellDataToAI.Error{
  status: 429,                         # HTTP status, or 0 for transport and local checks
  code: "monthly_limit_reached",       # API error string
  message: "...",
  body: %{...}                         # decoded answer when there was one
}
```

API error strings and what they mean:

- `invalid_domain` (400): the input is not a domain.
- `no_domains`, `too_many_domains` (400): batches take 1 to 100 entries.
- `missing_api_key`, `invalid_api_key` (401): key absent or plan inactive.
- `batch_not_found` (404): unknown id, or older than 7 days.
- `not_available` (410): company lists are not served by the API.
- `monthly_limit_reached` (429): monthly lookups used; reset on the 1st, UTC.
- `batch_busy` (429): three batches already open for this key.

Local codes, with `status: 0`: `bad_input` for a batch outside 1 to 100, `batch_timeout` when `max_wait` runs out, `transport` for network failures.

## Patterns

### Concurrent single lookups with Task.async_stream

```elixir
domains
|> Task.async_stream(&SellDataToAI.score(client, &1),
     max_concurrency: 4, timeout: 70_000, on_timeout: :kill_task)
|> Enum.zip(domains)
|> Enum.map(fn
  {{:ok, {:ok, s}}, _d} -> {s["domain"], s["data_asset_score"]}
  {{:ok, {:error, e}}, d} -> {d, {:error, e.code}}
  {{:exit, reason}, d} -> {d, {:exit, reason}}
end)
```

Keep `max_concurrency` modest. The batch endpoint is the better tool past a few dozen domains.

### A GenServer that scores sign-ups in the background

```elixir
defmodule MyApp.PartnerScorer do
  use GenServer

  def start_link(key), do: GenServer.start_link(__MODULE__, key, name: __MODULE__)
  def score_later(partner_id, website), do: GenServer.cast(__MODULE__, {:score, partner_id, website})

  @impl true
  def init(key), do: {:ok, SellDataToAI.new(key)}

  @impl true
  def handle_cast({:score, id, website}, client) do
    case SellDataToAI.score(client, website) do
      {:ok, s} -> MyApp.Partners.save_score(id, s["data_asset_score"], s["grade"], s["data_systems"])
      {:error, e} -> require Logger; Logger.warning("score failed for #{id}: #{e.code || e.message}")
    end
    {:noreply, client}
  end
end
```

Add it to your supervision tree with the key from runtime config. A Phoenix controller can then call `MyApp.PartnerScorer.score_later/2` and answer the user at once.

### A batch run from a Mix task

```elixir
defmodule Mix.Tasks.Score.File do
  use Mix.Task

  @shortdoc "Score a file of domains into a CSV"
  def run([input, output]) do
    Application.ensure_all_started(:selldatatoai)
    client = SellDataToAI.new(System.fetch_env!("SDA_API_KEY"))

    domains =
      input |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)

    {:ok, %{"remaining" => left}} = SellDataToAI.usage(client)
    if length(domains) > left, do: Mix.raise("#{length(domains)} domains, #{left} lookups left")

    {:ok, items} = SellDataToAI.score_many(client, domains)

    rows =
      for it <- items do
        r = it["result"] || %{}
        [it["input"], r["data_asset_score"], r["grade"], it["status"],
         get_in(r, ["history", "years_online"])]
        |> Enum.map_join(",", &to_string/1)
      end

    File.write!(output, Enum.join(["domain,score,grade,status,years_online" | rows], "\n"))
    Mix.shell().info("wrote #{length(rows)} rows to #{output}")
  end
end
```

## Configuration in an application

Read the key at runtime, never at compile time, so releases do not bake it in:

```elixir
# config/runtime.exs
config :my_app, :sda_api_key, System.get_env("SDA_API_KEY")
```

```elixir
# anywhere in your app
client = SellDataToAI.new(Application.fetch_env!(:my_app, :sda_api_key), timeout: 30_000)
```

The client struct is plain data with no process behind it. Build it once and pass it around, or rebuild it per call; both are cheap.

`:httpc` runs inside the `:inets` application. The package lists `:inets`, `:ssl` and `:public_key` as extra applications, so they start with your release.

## Testing your code

Point `:base_url` at a local server and your tests stay offline and free. With Bypass:

```elixir
setup do
  bypass = Bypass.open()
  client = SellDataToAI.new("test", base_url: "http://localhost:#{bypass.port}/v1", poll_interval: 10)
  {:ok, bypass: bypass, client: client}
end

test "shortlists A grades", %{bypass: bypass, client: client} do
  Bypass.expect_once(bypass, "GET", "/v1/score", fn conn ->
    Plug.Conn.resp(conn, 200, ~s({"domain":"example.com","data_asset_score":84,"grade":"A","verified_active":true}))
  end)

  assert {:shortlist, _} = MyApp.Triage.classify(client, "example.com")
end
```

Cover a 400 answer and a batch that answers `processing` before `done`, and your error handling is tested too.

## What the fields mean for a deal

AI labs pay most for real operational records, written by people doing real work. The overview of [what data AI labs want](https://www.selldatatoai.com/what-data-ai-labs-want/) ranks the types and explains why some are worth little.

The response maps to that directly:

- `data_systems`: systems the company is seen to run, with the record type each holds, for example a ticketing system holding work tickets.
- `likely_data_assets`: types the company probably holds given its sector and footprint.
- `history.pre_ai_years`: years online before 2023. Older archives carry no AI-written text.
- `status` and `verified_active`: whether there is still a company to sign with.
- `strengths`: up to three factor groups where the company scores best.
- `data_coverage`: `full`, `partial` or `limited`, for how complete the signals were.

Some buyers ask for one record type across many sectors. For customer relationship data, a ready file of US [companies with CRM records](https://www.selldatatoai.com/lists/data-type/crm-records/) exists alongside the sector lists. Lists are one-time purchases and never come through the API.

## Single calls or batches?

| Situation | Use |
|---|---|
| One company at a time, as it arrives | `score/2` |
| A handful, and you want each answer as soon as it is ready | `Task.async_stream` over `score/2` |
| A list of dozens to thousands | `score_many/2` |
| You run your own job queue and want control over polling | `submit_batch/2` and `get_batch/2` |

Both paths cost the same: one lookup per company. Batches save connections and let the server do the parallel work.

## Batches in detail

1. Submit 1 to 100 domains. Invalid ones come back as `invalid_domain` and cost nothing.
2. Each valid, unique domain is charged one lookup at submit.
3. Domains scored in the last 30 days are `done` in the first answer.
4. The rest usually finish within a minute.
5. Polling with `get_batch/2` is free.
6. Results keep input order and are kept for 7 days.
7. A key may hold three open batches. `score_many/2` sends one at a time.

## Plans

- Basic, $99 a month: 5,000 lookups.
- Pro, $299 a month: 25,000 lookups and batch scoring.
- Scale, $799 a month: 100,000 lookups and batch scoring.

No free plan and no trial. If you want to see output before you subscribe, you can [score a company domain](https://www.selldatatoai.com/data-asset-score/) in the website demo, 5 checks a day. Monthly limits reset on the first day of each month, UTC.

## FAQ

### What is the selldatatoai Hex package?

The selldatatoai Hex package is the Elixir client for the AI Data Value Score API at selldatatoai.com. It scores company websites from 0 to 100 for the data AI buyers want and returns plain maps with grade, status, data systems and history.

### Why `:httpc` and not Req or Finch?

So the package adds nothing heavy to your tree. If you already run Finch, the API is four plain JSON endpoints and easy to call directly.

### Is a cached answer cheaper?

No. Each scored domain is one lookup, whether it was scored now or within the last 30 days. `"cached" => true` tells you which.

### Can I score full URLs?

Yes. The API takes the domain out of any URL you pass.

### Are the scoring weights public?

The factor groups are described on the website. The weights and rules are not published.

## Links

- Hex docs: [hexdocs.pm](https://hexdocs.pm/selldatatoai)
- Elixir getting started guide: [elixir-lang.org](https://elixir-lang.org/getting-started/introduction.html)
- Service and pricing: https://www.selldatatoai.com/
- Source: https://github.com/explainableaixai/selldatatoai-elixir

## License

MIT. Copyright (c) 2026 Alpha Quantum (info@alpha-quantum.com).
