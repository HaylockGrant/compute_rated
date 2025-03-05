defmodule ComputeRated do
  use GenServer

  @moduledoc """
  A leaky bucket rate limiter optimized for compute time limits.

  This module provides a rate limiter that tracks compute time usage and allows
  checking and waiting for available capacity. It's based on the leaky bucket
  algorithm where compute time gradually drains from the bucket over time.
  """

  ## Client API

  @doc """
  Starts the ComputeRated server.
  """
  def start_link(args \\ [], opts \\ []) do
    GenServer.start_link(__MODULE__, Keyword.merge(app_args_with_defaults(), args), opts)
  end

  @doc false
  def child_spec(args_opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, args_opts}}
  end

  @doc """
  Check if adding the specified amount of compute time would exceed the bucket's limit.

  ## Arguments:

  - `id` (Erlang term()) name of the bucket
  - `scale` (Integer) time in ms over which the bucket drains
  - `limit` (Integer) the max amount of compute time the bucket can hold
  - `amount` (Integer) the amount of compute time to check for

  ## Examples

      # Check if adding 100 units of compute time would exceed a bucket with limit 1000
      iex> ComputeRated.check_rate("my-bucket", 60_000, 1000, 100)
      {:ok, 100, 900}

      # When it would exceed the limit
      iex> ComputeRated.check_rate("my-bucket", 60_000, 1000, 1100)
      {:error, 1000, 0}
  """
  @spec check_rate(id :: any, scale :: integer, limit :: integer, amount :: integer) ::
          {:ok, current :: integer, remaining :: integer} | {:error, current :: integer, remaining :: integer}
  def check_rate(id, scale, limit, amount) do
    GenServer.call(:compute_rated, {:check_rate, id, scale, limit, amount})
  end

  @doc """
  Add compute time to the bucket.

  ## Arguments:

  - `id` (Erlang term()) name of the bucket
  - `scale` (Integer) time in ms over which the bucket drains
  - `limit` (Integer) the max amount of compute time the bucket can hold
  - `amount` (Integer) the amount of compute time to add

  ## Examples

      # Add 100 units of compute time to a bucket
      iex> ComputeRated.add_compute_time("my-bucket", 60_000, 1000, 100)
      {:ok, 100, 900}
  """
  @spec add_compute_time(id :: any, scale :: integer, limit :: integer, amount :: integer) ::
          {:ok, current :: integer, remaining :: integer}
  def add_compute_time(id, scale, limit, amount) do
    GenServer.call(:compute_rated, {:add_compute_time, id, scale, limit, amount})
  end

  @doc """
  Sleep until there's enough capacity in the bucket for the specified amount,
  or optionally until the bucket is fully depleted.

  ## Arguments:

  - `id` (Erlang term()) name of the bucket
  - `scale` (Integer) time in ms over which the bucket drains
  - `limit` (Integer) the max amount of compute time the bucket can hold
  - `estimated_cost` (Integer, optional) the estimated amount that will be added after waiting
  - `wait_for_full_depletion` (Boolean, optional) if true, waits until bucket is empty

  ## Examples

      # Wait until there's enough capacity for 100 units
      iex> ComputeRated.wait_for_capacity("my-bucket", 60_000, 1000, 100)
      :ok

      # Wait until the bucket is completely empty
      iex> ComputeRated.wait_for_capacity("my-bucket", 60_000, 1000, nil, true)
      :ok
  """
  @spec wait_for_capacity(id :: any, scale :: integer, limit :: integer, estimated_cost :: integer | nil, wait_for_full_depletion :: boolean) ::
          :ok
  def wait_for_capacity(id, scale, limit, estimated_cost \\ nil, wait_for_full_depletion \\ false) do
    GenServer.call(:compute_rated, {:wait_for_capacity, id, scale, limit, estimated_cost, wait_for_full_depletion})
  end

  @doc """
  Delete bucket to reset the compute time counter.

  ## Arguments:

  - `id` (String) name of the bucket

  ## Example - Reset counter for my-bucket

      iex> ComputeRated.delete_bucket("my-bucket")
      :ok
  """
  @spec delete_bucket(id :: String.t()) :: :ok | :error
  def delete_bucket(id) do
    GenServer.call(:compute_rated, {:delete_bucket, id})
  end

  @doc """
  Stop the rate limit counter server.
  """
  def stop(server) do
    GenServer.call(server, :stop)
  end

  ## Server Callbacks

  @doc false
  def init(args) do
    Process.flag(:trap_exit, true)

    [
      {:timeout, timeout},
      {:cleanup_rate, cleanup_rate},
      {:persistent, persistent}
    ] = args

    open_table(ets_table_name(), persistent || false)
    :timer.send_interval(cleanup_rate, :prune)
    {:ok, %{timeout: timeout, cleanup_rate: cleanup_rate, persistent: persistent}}
  end

  def handle_call(:stop, _from, state) do
    {:stop, :normal, :ok, state}
  end

  def handle_call({:check_rate, id, scale, limit, amount}, _from, state) do
    ets_table_name = ets_table_name()
    result = check_and_get_capacity(id, scale, limit, amount, ets_table_name, false)
    {:reply, result, state}
  end

  def handle_call({:add_compute_time, id, scale, limit, amount}, _from, state) do
    ets_table_name = ets_table_name()
    result = add_compute_time(id, scale, limit, amount, ets_table_name)
    {:reply, result, state}
  end

  def handle_call({:wait_for_capacity, id, scale, limit, estimated_cost, wait_for_full_depletion}, _from, state) do
    result = do_wait_for_capacity(id, scale, limit, estimated_cost, wait_for_full_depletion)
    {:reply, result, state}
  end

  def handle_call({:delete_bucket, id}, _from, state) do
    ets_table_name = ets_table_name()
    result = delete_bucket(id, ets_table_name)
    {:reply, result, state}
  end

  def handle_call(_msg, _from, state) do
    {:reply, :ok, state}
  end

  def handle_cast(_msg, state) do
    {:noreply, state}
  end

  def handle_info(:prune, state) do
    %{timeout: timeout} = state
    ets_table_name = ets_table_name()
    prune_expired_buckets(timeout, ets_table_name)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  def terminate(_reason, state) do
    # if persistent is true save ETS table on disk and then close DETS table
    if persistent?(state), do: persist_and_close(state)

    :ok
  end

  def code_change(_old_version, state, _extra) do
    {:ok, state}
  end

  ## Private Functions

  defp open_table(ets_table_name, false) do
    :ets.new(ets_table_name, [
      :named_table,
      :ordered_set,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])
  end

  defp open_table(ets_table_name, true) do
    open_table(ets_table_name, false)
    :dets.open_file(ets_table_name, [{:file, ets_table_name}, {:repair, true}])
    :ets.delete_all_objects(ets_table_name)
    :ets.from_dets(ets_table_name, ets_table_name)
  end

  defp persistent?(state) do
    Map.get(state, :persistent) == true
  end

  defp persist(_state) do
    ets_table_name = ets_table_name()
    :ets.to_dets(ets_table_name, ets_table_name)
  end

  defp persist_and_close(state) do
    persist(state)
    :dets.close(ets_table_name())
  end

  # Check capacity without adding
  defp check_and_get_capacity(id, scale, limit, amount, ets_table_name, update_time) do
    {stamp, key} = stamp_key(id, scale)

    case :ets.member(ets_table_name, key) do
      false ->
        # Bucket doesn't exist, so there's full capacity
        if update_time do
          # Insert empty bucket if we're supposed to update the time
          true = :ets.insert(ets_table_name, {key, 0, stamp, stamp})
        end
        {:ok, 0, limit}

      true ->
        # Calculate how much has leaked since the last update
        [{_, current_amount, created_at, updated_at}] = :ets.lookup(ets_table_name, key)

        # Calculate time elapsed since last update and how much should leak out
        elapsed = stamp - updated_at
        leak_rate = limit / scale
        leaked_amount = min(current_amount, elapsed * leak_rate)

        # Calculate the new amount with leaking
        new_amount = max(0, current_amount - leaked_amount)

        # Update the last updated timestamp if requested
        if update_time do
          true = :ets.insert(ets_table_name, {key, new_amount, created_at, stamp})
        end

        # Check if adding the amount would exceed the limit
        remaining = limit - new_amount

        if new_amount + amount <= limit do
          {:ok, trunc(new_amount), trunc(remaining)}
        else
          {:error, trunc(new_amount), trunc(remaining)}
        end
    end
  end

  # Add compute time to the bucket
  defp add_compute_time(id, scale, limit, amount, ets_table_name) do
    {stamp, key} = stamp_key(id, scale)

    case :ets.member(ets_table_name, key) do
      false ->
        # Bucket doesn't exist, create it with the specified amount
        true = :ets.insert(ets_table_name, {key, amount, stamp, stamp})
        {:ok, amount, limit - amount}

      true ->
        # Calculate how much has leaked since the last update
        [{_, current_amount, created_at, _}] = :ets.lookup(ets_table_name, key)

        # Calculate time elapsed since last update and how much should leak out
        elapsed = stamp - :ets.lookup_element(ets_table_name, key, 4)
        leak_rate = limit / scale
        leaked_amount = min(current_amount, elapsed * leak_rate)

        # Calculate the new amount with leaking and addition
        new_amount = max(0, current_amount - leaked_amount) + amount
        remaining = max(0, limit - new_amount)

        # Update the bucket
        true = :ets.insert(ets_table_name, {key, new_amount, created_at, stamp})

        {:ok, trunc(new_amount), trunc(remaining)}
    end
  end

  # Wait for capacity to be available
  defp do_wait_for_capacity(id, scale, limit, estimated_cost, wait_for_full_depletion) do
    ets_table_name = ets_table_name()

    # If waiting for full depletion, we need the bucket to be empty
    target_amount = if wait_for_full_depletion, do: 0, else: estimated_cost || 0

    # Check current capacity
    case check_and_get_capacity(id, scale, limit, target_amount, ets_table_name, true) do
      {:ok, _, _} ->
        # We already have enough capacity
        :ok

      {:error, current, _} ->
        # Calculate how much time we need to wait for enough capacity
        leak_rate = limit / scale

        # How much needs to leak out to have space for our target amount
        needed_leak = if wait_for_full_depletion do
          current
        else
          current + (estimated_cost || 0) - limit
        end

        # Calculate sleep time in milliseconds
        sleep_time = ceil(needed_leak / leak_rate)

        # Sleep and then recurse to check again
        Process.sleep(sleep_time)
        do_wait_for_capacity(id, scale, limit, estimated_cost, wait_for_full_depletion)
    end
  end

  defp delete_bucket(id, ets_table_name) do
    import Ex2ms

    case :ets.select_delete(
           ets_table_name,
           fun do
             {{bucket_number, bid}, _, _, _} when bid == ^id -> true
           end
         ) do
      1 -> :ok
      _ -> :error
    end
  end

  defp stamp_key(id, scale) do
    stamp = timestamp()
    # with scale = 1 bucket changes every millisecond
    bucket_number = trunc(stamp / scale)
    key = {bucket_number, id}
    {stamp, key}
  end

  # Removes old buckets and returns the number removed.
  defp prune_expired_buckets(timeout, ets_table_name) do
    import Ex2ms
    now_stamp = timestamp()

    :ets.select_delete(
      ets_table_name,
      fun do
        {_, _, _, updated_at} when updated_at < ^now_stamp - ^timeout -> true
      end
    )
  end

  # Returns Erlang Time as milliseconds since 00:00 GMT, January 1, 1970
  defp timestamp do
    :erlang.system_time(:millisecond)
  end

  defp ets_table_name do
    Application.get_env(:compute_rated, :ets_table_name) || :compute_rated_buckets
  end

  # Fetch configured args
  defp app_args_with_defaults do
    [
      timeout: Application.get_env(:compute_rated, :timeout) || 90_000_000,
      cleanup_rate: Application.get_env(:compute_rated, :cleanup_rate) || 60_000,
      persistent: Application.get_env(:compute_rated, :persistent) || false
    ]
  end
end
