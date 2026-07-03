defmodule CircuitsUsb.Transfer do
  @moduledoc """
  Asynchronous transfer engine (Part B5).

  A GenServer that owns one device handle and drives transfers through the
  shim's async primitives (`submit_*` -> `select` -> `reap` -> `discard`).
  Submission is non-blocking; completions arrive via `enif_select` readiness on
  the usbfs fd and are drained with the non-blocking reap. No scheduler thread
  is ever blocked waiting on a transfer.

  ## The primitive: submit / message / cancel

  `submit/3` hands a transfer to the engine and returns `{:ok, ref}`
  immediately. The completion is delivered as a message to the submitting
  process (or `opts[:reply_to]`):

      {:circuits_usb, ref, {:ok, result} | {:error, reason}}

  where `result` is the received binary (IN), the byte count written (OUT), or
  `{:iso, data_or_bytes, [{actual_length, status}, ...]}` for isochronous.
  `cancel/2` discards an in-flight transfer (its completion then arrives as
  `{:error, :cancelled}`), and `await/3` blocks on a single completion.

  All transfer kinds -- control, bulk, interrupt, isochronous -- go through
  this one path as async URBs, so no request ever blocks the engine: one
  process can pipeline many transfers, stream isochronous URBs, or fold
  completions into its own receive loop.

  ## The conveniences: synchronous calls

  `bulk_in/4`, `bulk_out/5`, `interrupt_in/4`, `interrupt_out/5`,
  `control_transfer/7`, `iso_in/4`, `iso_out/5` and friends are `submit/3` +
  `await/3`, nothing more. They block only the caller; the engine keeps
  serving everyone else.

  ## Caveats

    * A `timeout` of `0` (or `:infinity`) means *no timeout*: no engine timer
      is armed, so the completion waits until the device answers. Prefer a
      finite timeout unless you truly want to wait forever (you can always
      `cancel/2`).
    * If the process that should receive a completion dies first, the engine
      discards the transfer and drops the completion.
  """

  use GenServer

  alias CircuitsUsb.Shim

  @type server :: GenServer.server()

  @typedoc """
  A transfer request for `submit/3`. Direction is bit 7 of the endpoint
  address (bulk/interrupt/iso) or of `request_type` (control): IN variants
  take a byte count to read, OUT variants take iodata to send.
  """
  @type request ::
          {:bulk_in, 0..255, non_neg_integer()}
          | {:bulk_out, 0..255, iodata()}
          | {:interrupt_in, 0..255, non_neg_integer()}
          | {:interrupt_out, 0..255, iodata()}
          | {:control, 0..255, 0..255, 0..0xFFFF, 0..0xFFFF, iodata() | non_neg_integer()}
          | {:iso_in, 0..255, [0..0xFFFF]}
          | {:iso_out, 0..255, [0..0xFFFF], iodata()}

  @typedoc "Per-packet isochronous outcome: `{actual_length, status}`."
  @type iso_packet :: {non_neg_integer(), :ok | atom()}

  @typedoc "A completed transfer's result, as delivered in `{:circuits_usb, ref, result}`."
  @type result ::
          {:ok,
           binary() | non_neg_integer() | {:iso, binary() | non_neg_integer(), [iso_packet()]}}
          | {:error, atom()}

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

  # A transfer timeout is a non-negative integer in ms (0 = no timeout) or
  # :infinity. Anything else (negative, float, atom) raises at the call site
  # instead of silently meaning "wait forever".
  defguardp valid_timeout(t) when t == :infinity or (is_integer(t) and t >= 0)

  # ---- the async primitive -------------------------------------------------

  @doc """
  Submit a transfer asynchronously. Returns `{:ok, ref}` at once; the
  completion arrives later as `{:circuits_usb, ref, result}` (see `t:result/0`).

  Options:

    * `:timeout` - ms until the engine cancels the transfer and delivers
      `{:error, :timeout}`; `0` or `:infinity` (the default) arms no timer.
    * `:reply_to` - pid to receive the completion (default: the caller). If it
      dies while the transfer is in flight, the engine discards the transfer.
    * `:zero_packet` - append a terminating zero-length packet (OUT bulk and
      interrupt only).

  Returns `{:error, reason}` if the kernel refuses the submission (nothing is
  in flight and no message will arrive). A malformed request (direction and
  payload disagree) is `{:error, :einval}`.
  """
  @spec submit(server(), request(), keyword()) :: {:ok, reference()} | {:error, atom()}
  def submit(server, request, opts \\ []) when is_tuple(request) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, :infinity)
    reply_to = Keyword.get(opts, :reply_to, self())
    zero_packet = Keyword.get(opts, :zero_packet, false)

    if not valid_timeout(timeout),
      do: raise(ArgumentError, "invalid :timeout #{inspect(timeout)}")

    if not is_pid(reply_to),
      do: raise(ArgumentError, "invalid :reply_to #{inspect(reply_to)}")

    GenServer.call(server, {:submit, request, reply_to, timeout, zero_packet})
  end

  @doc """
  Cancel an in-flight transfer by its `submit/3` ref. The completion is still
  delivered, as `{:error, :cancelled}` (or the real result if it had already
  finished when the cancel arrived).
  """
  @spec cancel(server(), reference()) :: :ok | {:error, :not_found}
  def cancel(server, ref) when is_reference(ref), do: GenServer.call(server, {:cancel, ref})

  @doc """
  Block until the completion for `ref` arrives and return its result.

  `timeout` here bounds the *wait*, not the transfer (use `submit/3`'s
  `:timeout` for that). Exits like `GenServer.call/3` if the engine dies or
  the wait times out, except that a gracefully stopped engine delivers
  `{:error, :closed}` first.
  """
  @spec await(server(), reference(), timeout()) :: result()
  def await(server, ref, timeout \\ :infinity) when is_reference(ref) do
    case GenServer.whereis(server) do
      nil ->
        # Engine already gone: its terminate/2 delivered {:error, :closed}
        # completions before dying, so honor one if present.
        receive do
          {:circuits_usb, ^ref, result} -> result
        after
          0 -> exit({:noproc, {__MODULE__, :await, [server, ref, timeout]}})
        end

      pid ->
        mon = Process.monitor(pid)

        receive do
          {:circuits_usb, ^ref, result} ->
            Process.demonitor(mon, [:flush])
            result

          {:DOWN, ^mon, :process, _pid, reason} ->
            exit({reason, {__MODULE__, :await, [server, ref, timeout]}})
        after
          timeout ->
            Process.demonitor(mon, [:flush])
            exit({:timeout, {__MODULE__, :await, [server, ref, timeout]}})
        end
    end
  end

  # ---- synchronous conveniences (submit + await) ---------------------------

  @doc """
  Control transfer with an explicit `request_type` (`bmRequestType`), for
  class/vendor and non-device-recipient requests. Direction is bit 7 of
  `request_type` (IN takes a length, OUT takes iodata). Blocks the caller;
  runs as an async URB so it never blocks the engine.
  """
  @spec control_transfer(
          server(),
          0..255,
          0..255,
          0..0xFFFF,
          0..0xFFFF,
          iodata() | non_neg_integer(),
          timeout()
        ) :: {:ok, binary()} | {:ok, non_neg_integer()} | {:error, atom()}
  def control_transfer(
        server,
        request_type,
        request,
        value,
        index,
        data_or_length,
        timeout_ms \\ 1000
      )
      when valid_timeout(timeout_ms),
      do:
        sync(server, {:control, request_type, request, value, index, data_or_length}, timeout_ms)

  @doc "Standard device-recipient control IN. See `control_transfer/7`."
  @spec control_in(server(), 0..255, 0..0xFFFF, 0..0xFFFF, non_neg_integer(), timeout()) ::
          {:ok, binary()} | {:error, atom()}
  def control_in(server, request, value, index, length, timeout_ms \\ 1000),
    do: control_transfer(server, 0x80, request, value, index, length, timeout_ms)

  @doc "Standard device-recipient control OUT. See `control_transfer/7`."
  @spec control_out(server(), 0..255, 0..0xFFFF, 0..0xFFFF, iodata(), timeout()) ::
          {:ok, non_neg_integer()} | {:error, atom()}
  def control_out(server, request, value, index, data, timeout_ms \\ 1000),
    do: control_transfer(server, 0x00, request, value, index, data, timeout_ms)

  @doc """
  Bulk IN transfer on an IN endpoint address (bit 7 set). Blocks the caller
  until it completes, times out, or fails.
  Returns `{:ok, binary}` / `{:error, :timeout}` / `{:error, errno_atom}`.
  """
  @spec bulk_in(server(), 0..255, non_neg_integer(), timeout()) ::
          {:ok, binary()} | {:error, term()}
  def bulk_in(server, endpoint, length, timeout \\ 1000) when valid_timeout(timeout),
    do: sync(server, {:bulk_in, endpoint, length}, timeout)

  @doc """
  Bulk OUT transfer on an OUT endpoint address (bit 7 clear). Blocks the caller
  until it completes, times out, or fails. `opts[:zero_packet]` appends a
  terminating zero-length packet.
  Returns `{:ok, bytes_written}` / `{:error, :timeout}` / `{:error, errno_atom}`.
  """
  @spec bulk_out(server(), 0..255, iodata(), timeout(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def bulk_out(server, endpoint, data, timeout \\ 1000, opts \\ []) when valid_timeout(timeout),
    do: sync(server, {:bulk_out, endpoint, data}, timeout, Keyword.take(opts, [:zero_packet]))

  @doc """
  Interrupt IN transfer on an IN endpoint address. Blocks the caller until it
  completes, times out, or fails. Returns `{:ok, binary}` / `{:error, :timeout}`
  / `{:error, errno_atom}`.
  """
  @spec interrupt_in(server(), 0..255, non_neg_integer(), timeout()) ::
          {:ok, binary()} | {:error, term()}
  def interrupt_in(server, endpoint, length, timeout \\ 1000) when valid_timeout(timeout),
    do: sync(server, {:interrupt_in, endpoint, length}, timeout)

  @doc """
  Interrupt OUT transfer on an OUT endpoint address. Blocks the caller until it
  completes, times out, or fails. Returns `{:ok, bytes_written}` /
  `{:error, :timeout}` / `{:error, errno_atom}`.
  """
  @spec interrupt_out(server(), 0..255, iodata(), timeout(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def interrupt_out(server, endpoint, data, timeout \\ 1000, opts \\ [])
      when valid_timeout(timeout),
      do:
        sync(
          server,
          {:interrupt_out, endpoint, data},
          timeout,
          Keyword.take(opts, [:zero_packet])
        )

  @doc """
  Isochronous IN transfer: one URB whose packet sizes are `packet_lengths`.
  Blocks the caller. Returns `{:ok, {:iso, data, packets}}` where `data` is the
  whole buffer (each packet's bytes at its requested-length offset, gaps
  zero-filled) and `packets` the per-packet `{actual_length, status}` list.
  For sustained streaming prefer `submit/3` with several URBs in flight.
  """
  @spec iso_in(server(), 0..255, [0..0xFFFF], timeout()) ::
          {:ok, {:iso, binary(), [iso_packet()]}} | {:error, term()}
  def iso_in(server, endpoint, packet_lengths, timeout \\ 1000) when valid_timeout(timeout),
    do: sync(server, {:iso_in, endpoint, packet_lengths}, timeout)

  @doc """
  Isochronous OUT transfer: `data` must be exactly the sum of `packet_lengths`.
  Blocks the caller. Returns `{:ok, {:iso, bytes_written, packets}}`.
  For sustained streaming prefer `submit/3` with several URBs in flight.
  """
  @spec iso_out(server(), 0..255, [0..0xFFFF], iodata(), timeout()) ::
          {:ok, {:iso, non_neg_integer(), [iso_packet()]}} | {:error, term()}
  def iso_out(server, endpoint, packet_lengths, data, timeout \\ 1000)
      when valid_timeout(timeout),
      do: sync(server, {:iso_out, endpoint, packet_lengths, data}, timeout)

  defp sync(server, request, timeout, opts \\ []) do
    case submit(server, request, [timeout: timeout] ++ opts) do
      {:ok, ref} -> await(server, ref, call_timeout(timeout))
      {:error, _} = err -> err
    end
  end

  # Give the await some slack beyond the transfer timeout so the engine's own
  # timeout completion always wins the race.
  defp call_timeout(ms) when is_integer(ms) and ms > 0, do: ms + 5000
  defp call_timeout(_zero_or_infinity), do: :infinity

  # ---- server ------------------------------------------------------------

  @impl true
  def init(opts) do
    # Trap exits so a crashing linked owner still runs terminate/2 (which closes
    # the fd). Without this, an armed enif_select pins the resource -- and thus
    # the fd and URB memory -- until VM shutdown, since the GC destructor cannot
    # run while a select is outstanding.
    Process.flag(:trap_exit, true)

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

  # Map a request tuple onto the shim submit for a given URB tag. A
  # direction/payload mismatch (or a malformed tuple) must become a typed
  # error, so callers of submit/3 handle rescue/fallback around this.
  defp do_submit({:bulk_in, ep, len}, h, tag, _zlp), do: Shim.submit_bulk(h, tag, ep, len)

  defp do_submit({:bulk_out, ep, data}, h, tag, zlp),
    do: Shim.submit_bulk(h, tag, ep, data, zlp_opts(zlp))

  defp do_submit({:interrupt_in, ep, len}, h, tag, _zlp),
    do: Shim.submit_interrupt(h, tag, ep, len)

  defp do_submit({:interrupt_out, ep, data}, h, tag, zlp),
    do: Shim.submit_interrupt(h, tag, ep, data, zlp_opts(zlp))

  defp do_submit({:control, rtype, req, value, index, dl}, h, tag, _zlp),
    do: Shim.submit_control(h, tag, rtype, req, value, index, dl)

  defp do_submit({:iso_in, ep, lengths}, h, tag, _zlp),
    do: Shim.submit_iso(h, tag, ep, lengths, nil)

  defp do_submit({:iso_out, ep, lengths, data}, h, tag, _zlp),
    do: Shim.submit_iso(h, tag, ep, lengths, data)

  defp do_submit(_other, _h, _tag, _zlp), do: {:error, :einval}

  defp zlp_opts(true), do: [zero_packet: true]
  defp zlp_opts(_), do: []

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

  def handle_call({:submit, request, reply_to, timeout, zero_packet}, _from, state) do
    tag = state.next_tag

    # A direction/payload mismatch makes the NIF raise badarg; turn it into a
    # typed error for this caller rather than crashing the engine and every
    # in-flight transfer.
    result =
      try do
        do_submit(request, state.handle, tag, zero_packet)
      rescue
        ArgumentError -> {:error, :einval}
      end

    case result do
      :ok ->
        ref = make_ref()

        timer =
          if is_integer(timeout) and timeout > 0,
            do: Process.send_after(self(), {:timeout, tag}, timeout)

        entry = %{
          ref: ref,
          reply_to: reply_to,
          # Monitor the receiver so a dead one cannot strand an in-flight URB
          # (no timer would ever clean an :infinity submission).
          mon: Process.monitor(reply_to),
          timer: timer,
          timed_out: false,
          cancelled: false
        }

        pending = Map.put(state.pending, tag, entry)
        {:reply, {:ok, ref}, arm(%{state | next_tag: tag + 1, pending: pending})}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:cancel, ref}, _from, state) do
    case Enum.find(state.pending, fn {_tag, e} -> e.ref == ref end) do
      nil ->
        {:reply, {:error, :not_found}, state}

      {tag, entry} ->
        # Discard the URB; it reaps with the cancel signature and deliver/2
        # translates it into {:error, :cancelled} (or the real result if it
        # completed first).
        Shim.discard(state.handle, tag)
        pending = Map.put(state.pending, tag, %{entry | cancelled: true})
        {:reply, :ok, %{state | pending: pending}}
    end
  end

  @impl true
  def handle_info({:select, _handle, ref, :ready_output}, %{ref: ref} = state) do
    {:noreply, state |> reap() |> rearm()}
  end

  # Stale select message (ref from a previous arm); ignore.
  def handle_info({:select, _handle, _other_ref, _}, state), do: {:noreply, state}

  # A trapped exit from the linked owner: shut down so terminate/2 closes the fd.
  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  def handle_info({:timeout, tag}, state) do
    case Map.get(state.pending, tag) do
      nil ->
        {:noreply, state}

      entry ->
        # Cancel the URB; it completes with a reset status and is reaped below,
        # where we translate it into {:error, :timeout}.
        Shim.discard(state.handle, tag)
        {:noreply, %{state | pending: Map.put(state.pending, tag, %{entry | timed_out: true})}}
    end
  end

  # A completion receiver died: discard its transfer and orphan the entry (the
  # reap still needs it to reclaim the URB, but there is nobody to notify).
  def handle_info({:DOWN, mon, :process, _pid, _reason}, state) do
    case Enum.find(state.pending, fn {_tag, e} -> e.mon == mon end) do
      nil ->
        {:noreply, state}

      {tag, entry} ->
        if entry.timer, do: Process.cancel_timer(entry.timer)
        Shim.discard(state.handle, tag)

        pending =
          Map.put(state.pending, tag, %{entry | cancelled: true, reply_to: nil, timer: nil})

        {:noreply, %{state | pending: pending}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    # Deliver a typed completion to any in-flight receivers before closing, so
    # a graceful stop never strands an `await` (matches the "no crash on
    # teardown" contract).
    Enum.each(state.pending, fn {_tag, e} ->
      if e.timer, do: Process.cancel_timer(e.timer)
      if e.reply_to, do: send(e.reply_to, {:circuits_usb, e.ref, {:error, :closed}})
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

      {entry, rest} ->
        if entry.timer, do: Process.cancel_timer(entry.timer)
        Process.demonitor(entry.mon, [:flush])

        if entry.reply_to,
          do: send(entry.reply_to, {:circuits_usb, entry.ref, result_for(entry, status, payload)})

        %{state | pending: rest}
    end
  end

  # A discard reaps as the cancellation signature (ENOENT or ECONNRESET, per
  # the kernel's timing -- libusb treats both as cancelled). Report it as
  # :cancelled for an explicit cancel/2, :timeout for an engine timer. If the
  # discard merely raced a real completion (the URB had already finished),
  # honor the actual result instead of dropping its data.
  defp result_for(%{cancelled: true}, status, _payload) when status in [:econnreset, :enoent],
    do: {:error, :cancelled}

  defp result_for(%{timed_out: true}, status, _payload) when status in [:econnreset, :enoent],
    do: {:error, :timeout}

  defp result_for(_entry, :ok, payload), do: {:ok, payload}
  defp result_for(_entry, status, _payload), do: {:error, status}
end
