defmodule CircuitsUsb.Transfer do
  @moduledoc """
  Asynchronous transfer engine (Part B5).

  A GenServer that owns one device handle and drives transfers through the
  shim's async primitives (`submit_bulk` -> `select` -> `reap` -> `discard`).
  Submission is non-blocking; completions arrive via `enif_select` readiness on
  the usbfs fd and are drained with the non-blocking reap. No scheduler thread is
  ever blocked waiting on a transfer.

  The public API is synchronous (`bulk_in/4`, `bulk_out/4` block the *caller*
  until their transfer completes), but many callers can have transfers in flight
  at once -- the engine pipelines them. Per-transfer timeouts are enforced in the
  engine by cancelling (`discard`) the URB, since async URBs have no kernel-level
  timeout.
  """

  use GenServer

  alias CircuitsUsb.Shim

  @type server :: GenServer.server()

  @doc """
  Start an engine. Options:

    * `:node` - usbfs path to open (`O_RDWR`), or
    * `:handle` - an already-open shim handle to adopt
    * `:name` - optional GenServer name
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @spec stop(server()) :: :ok
  def stop(server), do: GenServer.stop(server)

  @doc "Claim an interface on the engine's handle."
  @spec claim_interface(server(), non_neg_integer()) :: :ok | {:error, atom()}
  def claim_interface(server, iface), do: GenServer.call(server, {:claim, iface})

  @doc "Release an interface on the engine's handle."
  @spec release_interface(server(), non_neg_integer()) :: :ok | {:error, atom()}
  def release_interface(server, iface), do: GenServer.call(server, {:release, iface})

  @doc "Name of the kernel driver bound to an interface (or `{:error, :enodata}`)."
  @spec get_driver(server(), non_neg_integer()) :: {:ok, binary()} | {:error, atom()}
  def get_driver(server, iface), do: GenServer.call(server, {:get_driver, iface})

  @doc "Detach the kernel driver from an interface so it can be claimed."
  @spec detach_driver(server(), non_neg_integer()) :: :ok | {:error, atom()}
  def detach_driver(server, iface), do: GenServer.call(server, {:detach, iface})

  @doc "Reattach the kernel driver to an interface."
  @spec attach_driver(server(), non_neg_integer()) :: :ok | {:error, atom()}
  def attach_driver(server, iface), do: GenServer.call(server, {:attach, iface})

  @doc "Clear an endpoint's halt/stall (recovery after an `:epipe` transfer)."
  @spec clear_halt(server(), 0..255) :: :ok | {:error, atom()}
  def clear_halt(server, endpoint), do: GenServer.call(server, {:clear_halt, endpoint})

  @doc "Reset the device. The handle may be stale afterwards."
  @spec reset(server()) :: :ok | {:error, atom()}
  def reset(server), do: GenServer.call(server, :reset)

  @doc "Select an interface's alternate setting."
  @spec set_interface(server(), non_neg_integer(), non_neg_integer()) :: :ok | {:error, atom()}
  def set_interface(server, iface, alt), do: GenServer.call(server, {:set_interface, iface, alt})

  @doc "Control IN transfer (synchronous). See `CircuitsUsb.Shim.control_in/6`."
  @spec control_in(server(), 0..255, 0..0xFFFF, 0..0xFFFF, non_neg_integer(), timeout()) ::
          {:ok, binary()} | {:error, atom()}
  def control_in(server, request, value, index, length, timeout_ms \\ 1000),
    do:
      GenServer.call(server, {:control_in, request, value, index, length, timeout_ms}, :infinity)

  @doc "Control OUT transfer (synchronous). See `CircuitsUsb.Shim.control_out/6`."
  @spec control_out(server(), 0..255, 0..0xFFFF, 0..0xFFFF, iodata(), timeout()) ::
          {:ok, non_neg_integer()} | {:error, atom()}
  def control_out(server, request, value, index, data, timeout_ms \\ 1000),
    do: GenServer.call(server, {:control_out, request, value, index, data, timeout_ms}, :infinity)

  @doc """
  Bulk IN transfer on an IN endpoint address (bit 7 set). Blocks the caller
  until it completes, times out, or fails.
  Returns `{:ok, binary}` / `{:error, :timeout}` / `{:error, errno_atom}`.
  """
  @spec bulk_in(server(), 0..255, non_neg_integer(), timeout()) ::
          {:ok, binary()} | {:error, term()}
  def bulk_in(server, endpoint, length, timeout \\ 1000) do
    GenServer.call(server, {:transfer, :bulk, endpoint, length, timeout, []}, call_timeout(timeout))
  end

  @doc """
  Bulk OUT transfer on an OUT endpoint address (bit 7 clear). Blocks the caller
  until it completes, times out, or fails. `opts[:zero_packet]` appends a
  terminating zero-length packet.
  Returns `{:ok, bytes_written}` / `{:error, :timeout}` / `{:error, errno_atom}`.
  """
  @spec bulk_out(server(), 0..255, iodata(), timeout(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def bulk_out(server, endpoint, data, timeout \\ 1000, opts \\ []) do
    GenServer.call(server, {:transfer, :bulk, endpoint, data, timeout, opts}, call_timeout(timeout))
  end

  @doc """
  Interrupt IN transfer on an IN endpoint address. Blocks the caller until it
  completes, times out, or fails. Returns `{:ok, binary}` / `{:error, :timeout}`
  / `{:error, errno_atom}`.
  """
  @spec interrupt_in(server(), 0..255, non_neg_integer(), timeout()) ::
          {:ok, binary()} | {:error, term()}
  def interrupt_in(server, endpoint, length, timeout \\ 1000) do
    GenServer.call(
      server,
      {:transfer, :interrupt, endpoint, length, timeout, []},
      call_timeout(timeout)
    )
  end

  @doc """
  Interrupt OUT transfer on an OUT endpoint address. Blocks the caller until it
  completes, times out, or fails. Returns `{:ok, bytes_written}` /
  `{:error, :timeout}` / `{:error, errno_atom}`.
  """
  @spec interrupt_out(server(), 0..255, iodata(), timeout(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def interrupt_out(server, endpoint, data, timeout \\ 1000, opts \\ []) do
    GenServer.call(
      server,
      {:transfer, :interrupt, endpoint, data, timeout, opts},
      call_timeout(timeout)
    )
  end

  # Give the GenServer call some slack beyond the transfer timeout so the
  # engine's own timeout/reply always wins the race.
  defp call_timeout(:infinity), do: :infinity
  defp call_timeout(ms) when is_integer(ms) and ms > 0, do: ms + 5000
  defp call_timeout(_), do: :infinity

  # ---- server ------------------------------------------------------------

  @impl true
  def init(opts) do
    case open(opts) do
      {:ok, handle} ->
        {:ok, %{handle: handle, ref: make_ref(), armed: false, next_tag: 1, pending: %{}}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp open(opts) do
    cond do
      handle = opts[:handle] -> {:ok, handle}
      node = opts[:node] -> Shim.open(node, [:rdwr])
      true -> {:error, :no_node}
    end
  end

  defp submit(:bulk, handle, tag, endpoint, data, opts),
    do: Shim.submit_bulk(handle, tag, endpoint, data, opts)

  defp submit(:interrupt, handle, tag, endpoint, data, opts),
    do: Shim.submit_interrupt(handle, tag, endpoint, data, opts)

  @impl true
  def handle_call({:claim, iface}, _from, state),
    do: {:reply, Shim.claim_interface(state.handle, iface), state}

  def handle_call({:release, iface}, _from, state),
    do: {:reply, Shim.release_interface(state.handle, iface), state}

  def handle_call({:get_driver, iface}, _from, state),
    do: {:reply, Shim.get_driver(state.handle, iface), state}

  def handle_call({:detach, iface}, _from, state),
    do: {:reply, Shim.detach_driver(state.handle, iface), state}

  def handle_call({:attach, iface}, _from, state),
    do: {:reply, Shim.attach_driver(state.handle, iface), state}

  def handle_call({:clear_halt, endpoint}, _from, state),
    do: {:reply, Shim.clear_halt(state.handle, endpoint), state}

  def handle_call(:reset, _from, state),
    do: {:reply, Shim.reset(state.handle), state}

  def handle_call({:set_interface, iface, alt}, _from, state),
    do: {:reply, Shim.set_interface(state.handle, iface, alt), state}

  def handle_call({:control_in, request, value, index, length, timeout}, _from, state),
    do: {:reply, Shim.control_in(state.handle, request, value, index, length, timeout), state}

  def handle_call({:control_out, request, value, index, data, timeout}, _from, state),
    do: {:reply, Shim.control_out(state.handle, request, value, index, data, timeout), state}

  def handle_call({:transfer, kind, endpoint, data_or_length, timeout, opts}, from, state) do
    tag = state.next_tag

    case submit(kind, state.handle, tag, endpoint, data_or_length, opts) do
      :ok ->
        timer =
          if is_integer(timeout) and timeout > 0,
            do: Process.send_after(self(), {:timeout, tag}, timeout)

        pending = Map.put(state.pending, tag, %{from: from, timer: timer, timed_out: false})
        {:noreply, arm(%{state | next_tag: tag + 1, pending: pending})}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:select, _handle, ref, :ready_output}, %{ref: ref} = state) do
    {:noreply, state |> reap() |> rearm()}
  end

  # Stale select message (ref from a previous arm); ignore.
  def handle_info({:select, _handle, _other_ref, _}, state), do: {:noreply, state}

  def handle_info({:timeout, tag}, state) do
    case Map.get(state.pending, tag) do
      nil ->
        {:noreply, state}

      pending ->
        # Cancel the URB; it completes with a reset status and is reaped below,
        # where we translate it into {:error, :timeout}.
        Shim.discard(state.handle, tag)
        {:noreply, %{state | pending: Map.put(state.pending, tag, %{pending | timed_out: true})}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    # Reply to any in-flight callers before closing so they get a typed result
    # instead of a GenServer exit (matches the "no crash on teardown" contract).
    Enum.each(state.pending, fn {_tag, p} ->
      if p.timer, do: Process.cancel_timer(p.timer)
      GenServer.reply(p.from, {:error, :closed})
    end)

    Shim.close(state.handle)
    :ok
  end

  # ---- select arming -----------------------------------------------------

  # enif_select is one-shot per readiness: after a notification we must re-arm.
  defp arm(%{armed: true} = state), do: state

  defp arm(state) do
    case Shim.select(state.handle, state.ref) do
      :ok -> %{state | armed: true}
      {:error, _} -> state
    end
  end

  defp rearm(state) do
    state = %{state | armed: false}
    if map_size(state.pending) > 0, do: arm(state), else: state
  end

  # ---- reaping -----------------------------------------------------------

  defp reap(state) do
    state.handle
    |> Shim.reap()
    |> Enum.reduce(state, &deliver/2)
  end

  defp deliver({tag, status, payload}, state) do
    case Map.pop(state.pending, tag) do
      {nil, _} ->
        state

      {pending, rest} ->
        if pending.timer, do: Process.cancel_timer(pending.timer)
        GenServer.reply(pending.from, result_for(pending, status, payload))
        %{state | pending: rest}
    end
  end

  defp result_for(%{timed_out: true}, _status, _payload), do: {:error, :timeout}
  defp result_for(_pending, :ok, payload), do: {:ok, payload}
  defp result_for(_pending, status, _payload), do: {:error, status}
end
