defmodule CircuitsUsb.Gadget do
  @moduledoc """
  USB gadget (device-side) definition over configfs (Part C1).

  The mirror image of the rest of this library: instead of talking *to* a USB
  device, this machine *is* one. A gadget is described by a spec (IDs, strings,
  functions, configurations), materialized as a configfs tree, and bound to a
  UDC (USB device controller). The kernel's function drivers (`usb_f_hid`,
  `usb_f_acm`, `usb_f_ecm`, `usb_f_mass_storage`, ...) implement the class
  protocol; chardev-backed functions (HID, serial) are then driven through
  `CircuitsUsb.Shim` or any file API.

  Pure filesystem plumbing in the spirit of the shim tier: no processes, no
  hidden state. A `t:t/0` is just the gadget's name and configfs path.

      spec = %{
        vendor_id: 0xCAFE,
        product_id: 0xBABE,
        strings: %{manufacturer: "circuits", product: "demo", serialnumber: "g-1"},
        functions: %{
          "hid.usb0" => %{
            protocol: 0,
            subclass: 0,
            report_length: 8,
            report_desc: <<0x06, 0x00, 0xFF, 0x09, 0x01, 0xA1, 0x01, ...>>
          }
        },
        configs: %{
          "c.1" => %{configuration: "demo", max_power: 120, functions: ["hid.usb0"]}
        }
      }

      {:ok, g} = CircuitsUsb.Gadget.define("demo", spec)
      :ok = CircuitsUsb.Gadget.bind(g, "dummy_udc.0")
      {:ok, "/dev/hidg0"} = CircuitsUsb.Gadget.device_node(g, "hid.usb0")
      ...
      :ok = CircuitsUsb.Gadget.unbind(g)
      :ok = CircuitsUsb.Gadget.remove(g)

  Requirements: a UDC (`/sys/class/udc` non-empty; OTG-capable hardware or
  `dummy_hcd`), configfs mounted, `libcomposite` plus the `usb_f_*` modules
  for the functions used, and permissions on `/sys/kernel/config` (root).

  Function attribute values: integers are written in decimal, binaries raw
  (e.g. `report_desc`), booleans as `1`/`0`. `max_power` is in mA. This module
  does not cover `os_desc` (Windows compat descriptors) or FunctionFS; see
  NEXT.md Part C for the roadmap.
  """

  alias __MODULE__

  @default_root "/sys/kernel/config/usb_gadget"
  @lang "0x409"

  defstruct [:name, :path]

  @typedoc "A defined gadget: its configfs directory."
  @type t :: %Gadget{name: String.t(), path: Path.t()}

  @typedoc """
  Gadget description. `functions` maps `"type.instance"` names to attribute
  maps; `configs` maps `"label.N"` names to `%{configuration: String.t(),
  max_power: mA, functions: [function_name]}`. Extra raw gadget attributes
  (e.g. `"bDeviceClass"`) go under `:attrs`.
  """
  @type spec :: %{
          optional(:vendor_id) => 0..0xFFFF,
          optional(:product_id) => 0..0xFFFF,
          optional(:bcd_usb) => 0..0xFFFF,
          optional(:bcd_device) => 0..0xFFFF,
          optional(:attrs) => %{optional(String.t()) => term()},
          optional(:strings) => %{optional(atom()) => String.t()},
          optional(:functions) => %{optional(String.t()) => map()},
          optional(:configs) => %{optional(String.t()) => map()}
        }

  @doc """
  Create the configfs tree for `name` from `spec`. Returns `{:ok, gadget}`;
  on any failure the partial tree is torn down again and `{:error, {step,
  reason}}` is returned. Fails with `{:error, :already_defined}` if a gadget
  of that name exists. `opts[:root]` overrides the configfs root (tests).
  """
  @spec define(String.t(), spec(), keyword()) :: {:ok, t()} | {:error, term()}
  def define(name, spec, opts \\ []) when is_binary(name) and is_map(spec) do
    root = Keyword.get(opts, :root, @default_root)
    gadget = %Gadget{name: name, path: Path.join(root, name)}

    with :ok <- validate(name, spec) do
      cond do
        not File.dir?(root) -> {:error, {:no_configfs, root}}
        File.dir?(gadget.path) -> {:error, :already_defined}
        true -> build(gadget, spec)
      end
    end
  end

  @doc """
  Bind the gadget to a UDC, making it appear on the bus. `udc` defaults to the
  first controller in `udcs/0`.
  """
  @spec bind(t(), String.t() | nil) :: :ok | {:error, term()}
  def bind(%Gadget{} = gadget, udc \\ nil) do
    case udc || List.first(udcs()) do
      nil -> {:error, :no_udc}
      chosen -> write_attr(gadget.path, "UDC", chosen)
    end
  end

  @doc "Unbind the gadget from its UDC (disconnect). Idempotent."
  @spec unbind(t()) :: :ok | {:error, term()}
  def unbind(%Gadget{} = gadget) do
    case udc(gadget) do
      :unbound -> :ok
      # A newline tells the kernel "no UDC"; plain "" is rejected on write.
      {:ok, _udc} -> write_attr(gadget.path, "UDC", "\n")
      {:error, _} = err -> err
    end
  end

  @doc "The UDC the gadget is bound to, or `:unbound`."
  @spec udc(t()) :: {:ok, String.t()} | :unbound | {:error, term()}
  def udc(%Gadget{} = gadget) do
    case File.read(Path.join(gadget.path, "UDC")) do
      {:ok, content} ->
        case String.trim(content) do
          "" -> :unbound
          name -> {:ok, name}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "List the available UDCs (`/sys/class/udc`)."
  @spec udcs() :: [String.t()]
  def udcs() do
    case File.ls("/sys/class/udc") do
      {:ok, names} -> Enum.sort(names)
      {:error, _} -> []
    end
  end

  @doc """
  Unbind (if bound) and delete the gadget's configfs tree. configfs requires a
  strict order (config symlinks, then config/function/string directories, then
  the gadget itself); every step is best-effort so a half-built tree is also
  removed. Returns `:ok` once the gadget directory is gone.
  """
  @spec remove(t()) :: :ok | {:error, term()}
  def remove(%Gadget{} = gadget) do
    _ = unbind(gadget)

    # Function symlinks inside each config must go before the config dirs.
    for config <- ls(Path.join(gadget.path, "configs")),
        entry <- ls(Path.join([gadget.path, "configs", config])) do
      path = Path.join([gadget.path, "configs", config, entry])

      case File.lstat(path) do
        {:ok, %File.Stat{type: :symlink}} -> File.rm(path)
        _ -> :ok
      end
    end

    for config <- ls(Path.join(gadget.path, "configs")) do
      rmdir_all(Path.join([gadget.path, "configs", config, "strings"]))
      File.rmdir(Path.join([gadget.path, "configs", config]))
    end

    rmdir_all(Path.join(gadget.path, "functions"))
    rmdir_all(Path.join(gadget.path, "strings"))

    case File.rmdir(gadget.path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {gadget.path, reason}}
    end
  end

  @doc """
  The `/dev` node backing a chardev function, resolved through the function's
  `dev` attribute (`major:minor` -> `/sys/dev/char`), with the `acm` port
  number as a fallback. E.g. `{:ok, "/dev/hidg0"}` for `"hid.usb0"`.
  """
  @spec device_node(t(), String.t()) :: {:ok, Path.t()} | {:error, term()}
  def device_node(%Gadget{} = gadget, function) do
    fpath = Path.join([gadget.path, "functions", function])

    cond do
      File.exists?(Path.join(fpath, "dev")) -> resolve_chardev(Path.join(fpath, "dev"))
      File.exists?(Path.join(fpath, "port_num")) -> resolve_acm(Path.join(fpath, "port_num"))
      true -> {:error, :no_device_node}
    end
  end

  @doc """
  The network interface name created by an ethernet-style function
  (ecm/ncm/rndis/eem), from its `ifname` attribute.
  """
  @spec network_interface(t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def network_interface(%Gadget{} = gadget, function) do
    case File.read(Path.join([gadget.path, "functions", function, "ifname"])) do
      {:ok, content} -> {:ok, String.trim(content)}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---- building ------------------------------------------------------------

  defp build(gadget, spec) do
    steps = [
      fn -> File.mkdir_p(gadget.path) end,
      fn -> write_gadget_attrs(gadget, spec) end,
      fn -> write_strings(Path.join(gadget.path, "strings"), Map.get(spec, :strings, %{})) end,
      fn -> build_functions(gadget, Map.get(spec, :functions, %{})) end,
      fn -> build_configs(gadget, Map.get(spec, :configs, %{})) end
    ]

    case run_steps(steps) do
      :ok ->
        {:ok, gadget}

      {:error, reason} ->
        _ = remove(gadget)
        {:error, reason}
    end
  end

  defp run_steps([]), do: :ok

  defp run_steps([step | rest]) do
    case step.() do
      :ok -> run_steps(rest)
      {:error, _} = err -> err
    end
  end

  @gadget_attr_names %{
    vendor_id: "idVendor",
    product_id: "idProduct",
    bcd_usb: "bcdUSB",
    bcd_device: "bcdDevice"
  }

  defp write_gadget_attrs(gadget, spec) do
    named =
      for {key, file} <- @gadget_attr_names,
          Map.has_key?(spec, key),
          do: {file, Map.fetch!(spec, key)}

    extra = spec |> Map.get(:attrs, %{}) |> Map.to_list()
    write_attrs(gadget.path, named ++ extra)
  end

  defp write_strings(_dir, strings) when map_size(strings) == 0, do: :ok

  defp write_strings(dir, strings) do
    lang_dir = Path.join(dir, @lang)

    with :ok <- File.mkdir_p(lang_dir) do
      write_attrs(lang_dir, Enum.map(strings, fn {key, value} -> {to_string(key), value} end))
    end
  end

  defp build_functions(gadget, functions) do
    Enum.reduce_while(functions, :ok, fn {name, attrs}, :ok ->
      case build_function(gadget, name, attrs) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {{:function, name}, reason}}}
      end
    end)
  end

  defp build_function(gadget, name, attrs) do
    fpath = Path.join([gadget.path, "functions", name])

    with :ok <- File.mkdir_p(fpath) do
      write_attrs(fpath, Enum.map(attrs, fn {key, value} -> {to_string(key), value} end))
    end
  end

  defp build_configs(gadget, configs) do
    Enum.reduce_while(configs, :ok, fn {name, config}, :ok ->
      case build_config(gadget, name, config) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {{:config, name}, reason}}}
      end
    end)
  end

  defp build_config(gadget, name, config) do
    cpath = Path.join([gadget.path, "configs", name])

    attrs =
      case Map.fetch(config, :max_power) do
        {:ok, ma} -> [{"MaxPower", ma}]
        :error -> []
      end

    strings =
      case Map.fetch(config, :configuration) do
        {:ok, description} -> %{configuration: description}
        :error -> %{}
      end

    with :ok <- File.mkdir_p(cpath),
         :ok <- write_attrs(cpath, attrs),
         :ok <- write_strings(Path.join(cpath, "strings"), strings) do
      link_functions(gadget, cpath, Map.get(config, :functions, []))
    end
  end

  defp link_functions(gadget, cpath, functions) do
    Enum.reduce_while(functions, :ok, fn fname, :ok ->
      target = Path.join([gadget.path, "functions", fname])
      link = Path.join(cpath, fname)

      case File.ln_s(target, link) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {{:link, fname}, reason}}}
      end
    end)
  end

  # ---- attribute plumbing ----------------------------------------------------

  defp write_attrs(dir, attrs) do
    Enum.reduce_while(attrs, :ok, fn {file, value}, :ok ->
      case write_attr(dir, file, value) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {Path.join(dir, file), reason}}}
      end
    end)
  end

  defp write_attr(dir, file, value) do
    case File.write(Path.join(dir, file), format_value(value)) do
      :ok -> :ok
      {:error, _} = err -> err
    end
  end

  # Integers in decimal (the kernel parses base 0, and decimal never collides
  # with its leading-0 octal rule); binaries raw (report descriptors); booleans
  # as the 0/1 configfs convention.
  defp format_value(value) when is_integer(value), do: Integer.to_string(value)
  defp format_value(true), do: "1"
  defp format_value(false), do: "0"
  defp format_value(value) when is_binary(value), do: value

  defp resolve_chardev(dev_attr) do
    with {:ok, content} <- File.read(dev_attr),
         {:ok, uevent} <- File.read("/sys/dev/char/#{String.trim(content)}/uevent") do
      uevent
      |> String.split("\n")
      |> Enum.find_value({:error, :no_devname}, fn
        "DEVNAME=" <> devname -> {:ok, "/dev/" <> devname}
        _ -> nil
      end)
    end
  end

  defp resolve_acm(port_attr) do
    with {:ok, content} <- File.read(port_attr) do
      {:ok, "/dev/ttyGS" <> String.trim(content)}
    end
  end

  defp ls(dir) do
    case File.ls(dir) do
      {:ok, entries} -> Enum.sort(entries)
      {:error, _} -> []
    end
  end

  # rmdir every child directory of dir (they only hold kernel-managed
  # attribute files in configfs, which vanish with the directory).
  defp rmdir_all(dir) do
    Enum.each(ls(dir), fn entry -> File.rmdir(Path.join(dir, entry)) end)
  end

  # ---- validation ------------------------------------------------------------

  # Every name becomes a path segment under the configfs root; reject anything
  # that could escape it or that configfs would refuse.
  @name_re ~r/^[A-Za-z0-9][A-Za-z0-9_-]*$/
  @dotted_re ~r/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/

  defp validate(name, spec) do
    functions = Map.get(spec, :functions, %{})
    configs = Map.get(spec, :configs, %{})

    cond do
      not Regex.match?(@name_re, name) ->
        {:error, {:invalid_name, name}}

      bad = Enum.find(Map.keys(functions), &(not Regex.match?(@dotted_re, &1))) ->
        {:error, {:invalid_function_name, bad}}

      bad = Enum.find(Map.keys(configs), &(not Regex.match?(@dotted_re, &1))) ->
        {:error, {:invalid_config_name, bad}}

      bad = missing_function_link(configs, functions) ->
        {:error, {:unknown_function, bad}}

      true ->
        :ok
    end
  end

  defp missing_function_link(configs, functions) do
    configs
    |> Enum.flat_map(fn {_name, config} -> Map.get(config, :functions, []) end)
    |> Enum.find(&(not Map.has_key?(functions, &1)))
  end
end
