defmodule ComputeRated.App do
  @moduledoc false
  use Application

  def start(_type, _args) do
    children = [
      {ComputeRated, [[], [name: :compute_rated]]}
    ]

    opts = [strategy: :one_for_one, name: ComputeRated.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
