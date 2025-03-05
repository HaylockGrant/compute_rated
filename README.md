# ComputeRated

A leaky bucket rate limiter optimized for compute time limits.

ComputeRated allows you to:
- Check if adding compute time would exceed a bucket's capacity
- Add compute time to a bucket
- Wait until a bucket has sufficient capacity or is fully depleted
- Track compute time usage over specified time windows

## Installation

The package can be installed by adding `compute_rated` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:compute_rated, "~> 0.1.0"}
  ]
end
```

## Usage

```elixir
# Check if adding 100 units of compute time would exceed a bucket's capacity
{:ok, current, remaining} = ComputeRated.check_rate("my-bucket", 60_000, 1000, 100)

# Add 100 units of compute time to a bucket
{:ok, current, remaining} = ComputeRated.add_compute_time("my-bucket", 60_000, 1000, 100)

# Wait until there's enough capacity for an estimated 200 units
:ok = ComputeRated.wait_for_capacity("my-bucket", 60_000, 1000, 200)

# Wait until the bucket is completely empty
:ok = ComputeRated.wait_for_capacity("my-bucket", 60_000, 1000, nil, true)

# Delete a bucket
:ok = ComputeRated.delete_bucket("my-bucket")
```

## Configuration

ComputeRated can be configured in your `config.exs`:

```elixir
config :compute_rated,
  timeout: 90_000_000,       # bucket maximum lifetime (25 hours)
  cleanup_rate: 60_000,      # cleanup every minute
  ets_table_name: :compute_rated_buckets,  # the registered name of the ETS table
  persistent: false          # whether to persist the buckets to disk
```

## Third-Party Attributions
  This project includes modified code from ExRated by Glenn Rempe (https://github.com/grempe/ex_rated).
  For full attribution and license information, please see the ATTRIBUTION file.
