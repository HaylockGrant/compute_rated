defmodule ComputeRated.Mixfile do
  use Mix.Project

  def project do
    [
      app: :compute_rated,
      version: "0.1.1",
      elixir: "~> 1.7",
      description: description(),
      package: package(),
      deps: deps(),
      name: "ComputeRated",
      source_url: "https://github.com/HaylockGrant/compute_rated",
      aliases: [test: "test --no-start"],
      docs: [extras: ["README.md"]]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      env: [timeout: 90_000_000, cleanup_rate: 60_000, ets_table_name: :compute_rated_buckets],
      mod: {ComputeRated.App, []}
    ]
  end

  defp deps do
    [
      {:ex2ms, "~> 1.5"},
      {:ex_doc, "~> 0.19", only: :dev}
    ]
  end

  defp description do
    """
    ComputeRated, a leaky bucket rate limiter optimized for compute time limits.
    
    This library allows you to rate-limit operations based on compute time,
    with support for checking capacity, adding compute time, and waiting
    for capacity to be available.
    """
  end

  defp package do
    [
      files: ["lib", "mix.exs", "README.md", "LICENSE"],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/HaylockGrant/compute_rated"}
    ]
  end
end
