defmodule SellDataToAI.MixProject do
  use Mix.Project

  def project do
    [
      app: :selldatatoai,
      version: "1.0.0",
      elixir: "~> 1.14",
      description: "Elixir client for the Data Asset Score API from selldatatoai.com: score company domains 0 to 100 for the data AI buyers want, singly or in batches of 100.",
      package: package(),
      deps: deps(),
      docs: [main: "readme", extras: ["README.md"]],
      source_url: "https://github.com/explainableaixai/selldatatoai-elixir",
      homepage_url: "https://www.selldatatoai.com"
    ]
  end

  def application, do: [extra_applications: [:logger, :inets, :ssl, :public_key]]

  defp deps do
    [{:jason, "~> 1.4"}, {:ex_doc, "~> 0.34", only: :dev, runtime: false}]
  end

  defp package do
    [
      licenses: ["MIT"],
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE),
      links: %{
        "Homepage" => "https://www.selldatatoai.com",
        "API docs" => "https://www.selldatatoai.com/api/",
        "GitHub" => "https://github.com/explainableaixai/selldatatoai-elixir"
      }
    ]
  end
end
