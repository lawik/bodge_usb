# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule BodgeUSB do
  @moduledoc """
  Host-side USB for Elixir on Linux, over a usbfs-scoped syscall NIF.

  Each open device is one `BodgeUSB` process that owns the usbfs fd and runs
  an asynchronous URB engine (submit -> `enif_select` readiness -> reap): no
  scheduler thread is ever blocked on a transfer, and one process can
  pipeline many transfers at once.

  ## Example

      {:ok, dev} = BodgeUSB.open(0x0525, 0xA4A0)
      BodgeUSB.detach_driver(dev, 0)
      :ok = BodgeUSB.claim_interface(dev, 0)
      {:ok, data} = BodgeUSB.bulk_in(dev, 0x81, 512)
      {:ok, _n} = BodgeUSB.bulk_out(dev, 0x02, data)
      BodgeUSB.close(dev)

  ## The async primitive

  `submit/3` hands a transfer to the engine and returns `{:ok, ref}`
  immediately; the completion arrives as a message (see `t:result/0`):

      {:bodge_usb, ref, {:ok, result} | {:error, reason}}

  `cancel/2` discards an in-flight transfer (its completion then arrives as
  `{:error, :cancelled}`) and `await/3` blocks on one completion. The
  blocking calls (`bulk_in/4` and friends) are submit + await, nothing more:
  they block only the caller, never the engine.

  Watch devices come and go with `watch_hotplug/1`.

  ## Caveats

    * Everything is Linux-only and needs access to `/dev/bus/usb` (root or
      udev rules); hotplug additionally needs the netlink uevent socket
      (root).
    * If the process that should receive a completion dies first, the engine
      discards the transfer and drops the completion.
    * The engine traps exits, so a linked owner crashing, `close/1`, or an
      ordinary exit still runs `terminate/2`, which closes the fd. A `:kill`
      exit is the exception: it bypasses `terminate/2`, and while a select is
      armed the fd and its URB memory stay pinned by the NIF resource until
      the VM shuts down, because the GC destructor cannot run with an
      outstanding select. Close with `close/1`; do not brutal-kill.
  """

  use GenServer

  alias BodgeUSB.Descriptor
  alias BodgeUSB.DeviceRef
  alias BodgeUSB.Enumeration
  alias BodgeUSB.Hotplug
  alias BodgeUSB.Nif

  @typedoc "An open device (an engine process)."
  @type device :: GenServer.server()

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

  @typedoc """
  A completed transfer's result, as delivered in `{:bodge_usb, ref, result}`:
  the received binary (IN), the byte count written (OUT), or
  `{:iso, data_or_bytes, packets}` for isochronous. Iso IN `data` is the
  received packets' bytes concatenated in order; split it with the
  per-packet `actual_length` list.
  """
  @type result ::
          {:ok,
           binary() | non_neg_integer() | {:iso, binary() | non_neg_integer(), [iso_packet()]}}
          | {:error, atom()}

  # ---- discovery -----------------------------------------------------------

  @doc "List all USB devices under `/dev/bus/usb` with parsed descriptors."
  @spec list_devices() :: [DeviceRef.t()]
  defdelegate list_devices(), to: Enumeration

  @doc "Find the first device matching `vendor_id`/`product_id`, or `nil`."
  @spec find_device(0..0xFFFF, 0..0xFFFF) :: DeviceRef.t() | nil
  def find_device(vendor_id, product_id) do
    Enum.find(Enumeration.list_devices(), fn ref ->
      match?(
        {:ok, %Descriptor.Device{vendor_id: ^vendor_id, product_id: ^product_id}},
        ref.descriptor
      )
    end)
  end

  # ---- lifecycle -----------------------------------------------------------

  @doc """
  Open a device and start its engine. Accepts a `t:BodgeUSB.DeviceRef.t/0`, a
  usbfs path, or a `vendor_id, product_id` pair. Returns `{:ok, device}`.

  The engine is linked to the caller, so the fd is released if the caller
  dies. The fd is opened before the engine is started, so a device that
  cannot be opened (permissions, unplugged, busy) returns `{:error, reason}`
  without starting a process to crash a non-trapping caller through the
  link. (Contrast `start_link/1` with a `:node`, which opens inside `init`
  and so exits the caller on failure; that is the right shape under a
  supervisor.)
  """
  @spec open(DeviceRef.t() | Path.t()) :: GenServer.on_start()
  def open(%DeviceRef{path: path}), do: open(path)

  def open(path) when is_binary(path) do
    with {:ok, handle} <- Nif.open(path, [:rdwr]) do
      start_link(handle: handle)
    end
  end

  @spec open(0..0xFFFF, 0..0xFFFF) :: GenServer.on_start() | {:error, :not_found}
  def open(vendor_id, product_id) do
    case find_device(vendor_id, product_id) do
      nil -> {:error, :not_found}
      ref -> open(ref)
    end
  end

  @doc """
  Start an engine directly, for supervision trees. Options:

    * `:node` - usbfs path to open (`O_RDWR`) inside `init` (a failed open
      exits the caller through the link; prefer `open/1` outside a
      supervisor), or
    * `:handle` - an already-open NIF handle to adopt
    * `:name` - optional GenServer name
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc "Close a device: stops its engine, releasing the fd."
  @spec close(device()) :: :ok
  def close(device), do: GenServer.stop(device)

  # ---- interfaces and drivers ------------------------------------------------

  @doc "Claim an interface so its endpoints can be used for transfers."
  @spec claim_interface(device(), non_neg_integer()) :: :ok | {:error, atom()}
  def claim_interface(device, iface), do: GenServer.call(device, {:claim, iface})

  @doc "Release a claimed interface."
  @spec release_interface(device(), non_neg_integer()) :: :ok | {:error, atom()}
  def release_interface(device, iface), do: GenServer.call(device, {:release, iface})

  @doc "Select an interface's alternate setting."
  @spec set_interface(device(), non_neg_integer(), non_neg_integer()) :: :ok | {:error, atom()}
  def set_interface(device, iface, alt), do: GenServer.call(device, {:set_interface, iface, alt})

  @doc "Name of the kernel driver bound to an interface (or `{:error, :enodata}`)."
  @spec get_driver(device(), non_neg_integer()) :: {:ok, binary()} | {:error, atom()}
  def get_driver(device, iface), do: GenServer.call(device, {:get_driver, iface})

  @doc "Detach the kernel driver from an interface so it can be claimed."
  @spec detach_driver(device(), non_neg_integer()) :: :ok | {:error, atom()}
  def detach_driver(device, iface), do: GenServer.call(device, {:detach, iface})

  @doc "Reattach the kernel driver to an interface."
  @spec attach_driver(device(), non_neg_integer()) :: :ok | {:error, atom()}
  def attach_driver(device, iface), do: GenServer.call(device, {:attach, iface})

  # ---- recovery --------------------------------------------------------------

  @doc "Clear an endpoint's halt/stall (recovery after an `:epipe` transfer)."
  @spec clear_halt(device(), 0..255) :: :ok | {:error, atom()}
  def clear_halt(device, endpoint), do: GenServer.call(device, {:clear_halt, endpoint})

  @doc "Reset the device. The device re-enumerates, so the handle may be stale afterwards."
  @spec reset(device()) :: :ok | {:error, atom()}
  def reset(device), do: GenServer.call(device, :reset)

  # ---- the async primitive ---------------------------------------------------

  # A transfer timeout is a positive integer in ms or :infinity (no engine
  # timer armed; you can always cancel/2).
  defguardp valid_timeout(t) when t == :infinity or (is_integer(t) and t > 0)

  @doc """
  Submit a transfer asynchronously. Returns `{:ok, ref}` at once; the
  completion arrives later as `{:bodge_usb, ref, result}` (see `t:result/0`).

  Options:

    * `:timeout` - ms until the engine cancels the transfer and delivers
      `{:error, :timeout}`; `:infinity` (the default) arms no timer.
    * `:reply_to` - pid to receive the completion (default: the caller). If it
      dies while the transfer is in flight, the engine discards the transfer.
    * `:zero_packet` - append a terminating zero-length packet (OUT bulk and
      interrupt only).

  A malformed request (unknown tuple, direction and payload disagreeing,
  out-of-range fields) raises `ArgumentError` in the caller. Returns
  `{:error, reason}` if the kernel refuses the submission (nothing is in
  flight and no message will arrive).
  """
  @spec submit(device(), request(), keyword()) :: {:ok, reference()} | {:error, atom()}
  def submit(device, request, opts \\ []) when is_list(opts) do
    validate_request!(request)
    timeout = Keyword.get(opts, :timeout, :infinity)
    reply_to = Keyword.get(opts, :reply_to, self())
    zero_packet = Keyword.get(opts, :zero_packet, false)

    if not valid_timeout(timeout),
      do: raise(ArgumentError, "invalid :timeout #{inspect(timeout)}")

    if not is_pid(reply_to),
      do: raise(ArgumentError, "invalid :reply_to #{inspect(reply_to)}")

    GenServer.call(device, {:submit, request, reply_to, timeout, zero_packet})
  end

  @doc """
  Cancel an in-flight transfer by its `submit/3` ref. The completion is still
  delivered, as `{:error, :cancelled}` (or the real result if it had already
  finished when the cancel arrived).
  """
  @spec cancel(device(), reference()) :: :ok | {:error, :not_found}
  def cancel(device, ref) when is_reference(ref), do: GenServer.call(device, {:cancel, ref})

  @doc """
  Block until the completion for `ref` arrives and return its result.

  `timeout` here bounds the *wait*, not the transfer (use `submit/3`'s
  `:timeout` for that). Exits like `GenServer.call/3` if the engine dies or
  the wait times out, except that a gracefully closed engine delivers
  `{:error, :closed}` first.
  """
  @spec await(device(), reference(), timeout()) :: result()
  def await(device, ref, timeout \\ :infinity) when is_reference(ref) do
    case GenServer.whereis(device) do
      nil ->
        # Engine already gone: its terminate/2 delivered {:error, :closed}
        # completions before dying, so honor one if present.
        receive do
          {:bodge_usb, ^ref, result} -> result
        after
          0 -> exit({:noproc, {__MODULE__, :await, [device, ref, timeout]}})
        end

      pid ->
        mon = Process.monitor(pid)

        receive do
          {:bodge_usb, ^ref, result} ->
            Process.demonitor(mon, [:flush])
            result

          {:DOWN, ^mon, :process, _pid, reason} ->
            exit({reason, {__MODULE__, :await, [device, ref, timeout]}})
        after
          timeout ->
            Process.demonitor(mon, [:flush])
            exit({:timeout, {__MODULE__, :await, [device, ref, timeout]}})
        end
    end
  end

  # ---- blocking conveniences (submit + await) --------------------------------

  @doc """
  Control transfer with an explicit `request_type` (`bmRequestType`), for
  class/vendor and non-device-recipient requests. Direction is bit 7 of
  `request_type` (IN takes a length and returns `{:ok, binary}`, OUT takes
  iodata and returns `{:ok, bytes_written}`).
  """
  @spec control_transfer(
          device(),
          0..255,
          0..255,
          0..0xFFFF,
          0..0xFFFF,
          iodata() | non_neg_integer(),
          timeout()
        ) :: {:ok, binary()} | {:ok, non_neg_integer()} | {:error, atom()}
  def control_transfer(
        device,
        request_type,
        request,
        value,
        index,
        data_or_length,
        timeout \\ 1000
      )
      when valid_timeout(timeout),
      do: sync(device, {:control, request_type, request, value, index, data_or_length}, timeout)

  @doc "Standard device-recipient control IN. See `control_transfer/7`."
  @spec control_in(device(), 0..255, 0..0xFFFF, 0..0xFFFF, non_neg_integer(), timeout()) ::
          {:ok, binary()} | {:error, atom()}
  def control_in(device, request, value, index, length, timeout \\ 1000),
    do: control_transfer(device, 0x80, request, value, index, length, timeout)

  @doc "Standard device-recipient control OUT. See `control_transfer/7`."
  @spec control_out(device(), 0..255, 0..0xFFFF, 0..0xFFFF, iodata(), timeout()) ::
          {:ok, non_neg_integer()} | {:error, atom()}
  def control_out(device, request, value, index, data, timeout \\ 1000),
    do: control_transfer(device, 0x00, request, value, index, data, timeout)

  @doc """
  Bulk IN transfer on an IN endpoint address (bit 7 set). Blocks the caller
  until it completes, times out, or fails.
  Returns `{:ok, binary}` / `{:error, :timeout}` / `{:error, errno_atom}`.
  """
  @spec bulk_in(device(), 0..255, non_neg_integer(), timeout()) ::
          {:ok, binary()} | {:error, atom()}
  def bulk_in(device, endpoint, length, timeout \\ 1000) when valid_timeout(timeout),
    do: sync(device, {:bulk_in, endpoint, length}, timeout)

  @doc """
  Bulk OUT transfer on an OUT endpoint address (bit 7 clear). Blocks the
  caller until it completes, times out, or fails. `opts[:zero_packet]`
  appends a terminating zero-length packet.
  Returns `{:ok, bytes_written}` / `{:error, :timeout}` / `{:error, errno_atom}`.
  """
  @spec bulk_out(device(), 0..255, iodata(), timeout(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, atom()}
  def bulk_out(device, endpoint, data, timeout \\ 1000, opts \\ []) when valid_timeout(timeout),
    do: sync(device, {:bulk_out, endpoint, data}, timeout, Keyword.take(opts, [:zero_packet]))

  @doc "Interrupt IN transfer on an IN endpoint address. Blocks like `bulk_in/4`."
  @spec interrupt_in(device(), 0..255, non_neg_integer(), timeout()) ::
          {:ok, binary()} | {:error, atom()}
  def interrupt_in(device, endpoint, length, timeout \\ 1000) when valid_timeout(timeout),
    do: sync(device, {:interrupt_in, endpoint, length}, timeout)

  @doc "Interrupt OUT transfer on an OUT endpoint address. Blocks like `bulk_out/5`."
  @spec interrupt_out(device(), 0..255, iodata(), timeout(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, atom()}
  def interrupt_out(device, endpoint, data, timeout \\ 1000, opts \\ [])
      when valid_timeout(timeout),
      do:
        sync(
          device,
          {:interrupt_out, endpoint, data},
          timeout,
          Keyword.take(opts, [:zero_packet])
        )

  @doc """
  Read and decode the device's string descriptor `index` (1..255). Returns
  `{:error, :no_string}` for index 0 (the LANGID list) or a device with no
  such string.
  """
  @spec string(device(), 0..255, 0..0xFFFF) :: {:ok, String.t()} | {:error, atom()}
  def string(device, index, langid \\ 0x0409)
  def string(_device, 0, _langid), do: {:error, :no_string}

  def string(device, index, langid) when index in 1..255 do
    # GET_DESCRIPTOR(String, index): wValue = STRING type (0x03) in the high
    # byte, index in the low byte; wIndex = langid.
    case control_in(device, 0x06, 0x0300 + index, langid, 255, 1000) do
      {:ok, <<_len, 0x03, _::binary>> = bytes} -> Descriptor.decode_string(bytes)
      {:ok, _} -> {:error, :not_a_string_descriptor}
      {:error, _} = err -> err
    end
  end

  defp sync(device, request, timeout, opts \\ []) do
    case submit(device, request, [timeout: timeout] ++ opts) do
      {:ok, ref} -> await(device, ref, call_timeout(timeout))
      {:error, _} = err -> err
    end
  end

  # Give the await some slack beyond the transfer timeout so the engine's own
  # timeout completion always wins the race.
  defp call_timeout(ms) when is_integer(ms), do: ms + 5000
  defp call_timeout(:infinity), do: :infinity

  # ---- hotplug ---------------------------------------------------------------

  @doc """
  Start watching for hotplug events over the kernel netlink uevent socket
  (usually needs root). `opts[:notify]` (a pid or list of pids, default: the
  caller) receives device-level add/remove events as `{:usb_hotplug, event}`,
  where `event` is a map:

      %{action: :add | :remove | :bind | :unbind | :change | :unknown,
        busnum: integer | nil, devnum: integer | nil,
        devname: "/dev/bus/usb/BBB/DDD" | nil, devpath: String.t(),
        product: String.t() | nil}

  The socket is opened before the watcher starts, so a failed open returns
  `{:error, reason}` without disturbing a non-trapping caller. Stop it with
  `GenServer.stop/1`.
  """
  @spec watch_hotplug(keyword()) :: GenServer.on_start()
  defdelegate watch_hotplug(opts \\ []), to: Hotplug, as: :start_link

  # ---- request validation ------------------------------------------------

  # Direction is bit 7 of the endpoint address / bmRequestType, so IN is
  # 0x80..0xFF and OUT is 0x00..0x7F.
  defp validate_request!({:bulk_in, ep, len})
       when ep in 0x80..0xFF and is_integer(len) and len >= 0,
       do: :ok

  defp validate_request!({:bulk_out, ep, data}) when ep in 0x00..0x7F,
    do: validate_iodata!(data)

  defp validate_request!({:interrupt_in, ep, len})
       when ep in 0x80..0xFF and is_integer(len) and len >= 0,
       do: :ok

  defp validate_request!({:interrupt_out, ep, data}) when ep in 0x00..0x7F,
    do: validate_iodata!(data)

  defp validate_request!({:control, rtype, req, value, index, dl})
       when rtype in 0..255 and req in 0..255 and value in 0..0xFFFF and index in 0..0xFFFF do
    if rtype >= 0x80 do
      if is_integer(dl) and dl >= 0, do: :ok, else: bad_request({:control, :length, dl})
    else
      validate_iodata!(dl)
    end
  end

  defp validate_request!({:iso_in, ep, lengths})
       when ep in 0x80..0xFF and is_list(lengths) and lengths != [] do
    if Enum.all?(lengths, &(is_integer(&1) and &1 in 0..0xFFFF)),
      do: :ok,
      else: bad_request({:iso_in, :packet_lengths, lengths})
  end

  defp validate_request!({:iso_out, ep, lengths, data})
       when ep in 0x00..0x7F and is_list(lengths) and lengths != [] do
    validate_iodata!(data)

    if Enum.all?(lengths, &(is_integer(&1) and &1 in 0..0xFFFF)),
      do: :ok,
      else: bad_request({:iso_out, :packet_lengths, lengths})
  end

  defp validate_request!(other), do: bad_request(other)

  # IO.iodata_length walks the structure and raises ArgumentError on
  # non-iodata, which is exactly the contract here.
  defp validate_iodata!(data) do
    _ = IO.iodata_length(data)
    :ok
  end

  @spec bad_request(term()) :: no_return()
  defp bad_request(detail) do
    raise ArgumentError,
          "malformed transfer request (check endpoint direction bit and payload): " <>
            inspect(detail)
  end

  # ---- engine ----------------------------------------------------------------

  @impl true
  def init(opts) do
    # Trap exits so a crashing linked owner still runs terminate/2 (which
    # closes the fd). Without this, an armed enif_select pins the resource --
    # and thus the fd and URB memory -- until VM shutdown, since the GC
    # destructor cannot run while a select is outstanding.
    Process.flag(:trap_exit, true)

    case open_from_opts(opts) do
      {:ok, handle} ->
        {:ok, %{handle: handle, ref: make_ref(), armed: false, next_tag: 1, pending: %{}}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp open_from_opts(opts) do
    cond do
      handle = opts[:handle] -> {:ok, handle}
      node = opts[:node] -> Nif.open(node, [:rdwr])
      true -> {:error, :no_node}
    end
  end

  # Map a validated request tuple onto the NIF submit for a given URB tag.
  defp do_submit({:bulk_in, ep, len}, h, tag, _zlp), do: Nif.submit_bulk(h, tag, ep, len)

  defp do_submit({:bulk_out, ep, data}, h, tag, zlp),
    do: Nif.submit_bulk(h, tag, ep, data, zlp_opts(zlp))

  defp do_submit({:interrupt_in, ep, len}, h, tag, _zlp),
    do: Nif.submit_interrupt(h, tag, ep, len)

  defp do_submit({:interrupt_out, ep, data}, h, tag, zlp),
    do: Nif.submit_interrupt(h, tag, ep, data, zlp_opts(zlp))

  defp do_submit({:control, rtype, req, value, index, dl}, h, tag, _zlp),
    do: Nif.submit_control(h, tag, rtype, req, value, index, dl)

  defp do_submit({:iso_in, ep, lengths}, h, tag, _zlp),
    do: Nif.submit_iso(h, tag, ep, lengths, nil)

  defp do_submit({:iso_out, ep, lengths, data}, h, tag, _zlp),
    do: Nif.submit_iso(h, tag, ep, lengths, data)

  defp zlp_opts(true), do: [zero_packet: true]
  defp zlp_opts(_), do: []

  @impl true
  def handle_call({:claim, iface}, _from, state),
    do: {:reply, Nif.claim_interface(state.handle, iface), state}

  def handle_call({:release, iface}, _from, state),
    do: {:reply, Nif.release_interface(state.handle, iface), state}

  def handle_call({:get_driver, iface}, _from, state),
    do: {:reply, Nif.get_driver(state.handle, iface), state}

  def handle_call({:detach, iface}, _from, state),
    do: {:reply, Nif.detach_driver(state.handle, iface), state}

  def handle_call({:attach, iface}, _from, state),
    do: {:reply, Nif.attach_driver(state.handle, iface), state}

  def handle_call({:clear_halt, endpoint}, _from, state),
    do: {:reply, Nif.clear_halt(state.handle, endpoint), state}

  def handle_call(:reset, _from, state),
    do: {:reply, Nif.reset(state.handle), state}

  def handle_call({:set_interface, iface, alt}, _from, state),
    do: {:reply, Nif.set_interface(state.handle, iface, alt), state}

  def handle_call({:submit, request, reply_to, timeout, zero_packet}, _from, state) do
    tag = state.next_tag

    case do_submit(request, state.handle, tag, zero_packet) do
      :ok ->
        ref = make_ref()

        timer =
          if is_integer(timeout),
            do: Process.send_after(self(), {:timeout, tag}, timeout)

        entry = %{
          ref: ref,
          reply_to: reply_to,
          # Monitor the receiver so a dead one cannot strand an in-flight URB
          # (no timer would ever clean an :infinity submission).
          mon: Process.monitor(reply_to),
          timer: timer,
          timed_out: false,
          cancelled: false,
          # iso IN completions are compacted using the requested lengths.
          iso_lengths: iso_lengths(request)
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
        Nif.discard(state.handle, tag)
        pending = Map.put(state.pending, tag, %{entry | cancelled: true})
        {:reply, :ok, %{state | pending: pending}}
    end
  end

  defp iso_lengths({:iso_in, _ep, lengths}), do: lengths
  defp iso_lengths(_request), do: nil

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
        Nif.discard(state.handle, tag)
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
        Nif.discard(state.handle, tag)

        pending =
          Map.put(state.pending, tag, %{entry | cancelled: true, reply_to: nil, timer: nil})

        {:noreply, %{state | pending: pending}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    # Deliver a typed completion to any in-flight receivers before closing, so
    # a graceful close never strands an `await`.
    Enum.each(state.pending, fn {_tag, e} ->
      if e.timer, do: Process.cancel_timer(e.timer)
      if e.reply_to, do: send(e.reply_to, {:bodge_usb, e.ref, {:error, :closed}})
    end)

    Nif.close(state.handle)
    :ok
  end

  # ---- select arming -----------------------------------------------------

  # enif_select is one-shot per readiness: after a notification we must re-arm.
  defp arm(%{armed: true} = state), do: state

  defp arm(state) do
    case Nif.select(state.handle, state.ref) do
      :ok ->
        %{state | armed: true}

      {:error, reason} ->
        # Completions could never be delivered again, so crash: terminate/2
        # fails the pending transfers with {:error, :closed} instead of
        # leaving them stranded on a silently deaf engine.
        raise "BodgeUSB: select failed: #{inspect(reason)}"
    end
  end

  defp rearm(state) do
    state = %{state | armed: false}
    if map_size(state.pending) > 0, do: arm(state), else: state
  end

  # ---- reaping -----------------------------------------------------------

  defp reap(state) do
    state.handle
    |> Nif.reap()
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
          do: send(entry.reply_to, {:bodge_usb, entry.ref, result_for(entry, status, payload)})

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

  defp result_for(%{iso_lengths: lengths}, :ok, {:iso, data, packets})
       when is_list(lengths) and is_binary(data),
       do: {:ok, {:iso, compact_iso(data, lengths, packets), packets}}

  defp result_for(_entry, :ok, payload), do: {:ok, payload}
  defp result_for(_entry, status, _payload), do: {:error, status}

  # usbfs returns the whole iso IN buffer with each packet's bytes at its
  # requested-length offset and zero-filled gaps; concatenate the actually
  # received bytes so callers split on the per-packet actual_length list.
  defp compact_iso(data, lengths, packets) do
    {parts, _offset} =
      lengths
      |> Enum.zip(packets)
      |> Enum.map_reduce(0, fn {req_len, {actual, _status}}, offset ->
        take = actual |> min(req_len) |> min(max(byte_size(data) - offset, 0))
        {binary_part(data, offset, take), offset + req_len}
      end)

    IO.iodata_to_binary(parts)
  end
end
