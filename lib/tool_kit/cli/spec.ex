defmodule ToolKit.CLI.Spec do
  @moduledoc """
  CLI のコマンド・オプション定義(spec)と、そこからの導出。

  ツールは自分のコマンド語彙を `%ToolKit.CLI.Spec{}` として組み立てて渡す。
  OptionParser に渡す strict/aliases、コマンドごとの有効オプション検証、
  enum 値の検証、help 文面はすべて spec から導出される。
  spec に定義がないオプションはパース段階でエラーになる。

  ## 構造

  - `option_catalog`: オプション名 → `%{type, alias, values, doc}`。
    `values` が nil 以外なら enum としてパース時に検証される
  - `global_option_names`: 全コマンドで使えるオプション名のリスト
  - `commands`: コマンド定義 `%{name, aliases, usage, summary, options, examples}` のリスト。
    `options` の要素は名前(atom)か `{名前, 上書きマップ}` で、上書きマップで
    コマンド固有の values / doc を差し替えられる
  """

  @enforce_keys [:tool_name, :tool_summary, :option_catalog, :global_option_names, :commands]
  defstruct [:tool_name, :tool_summary, :option_catalog, :global_option_names, :commands]

  @type option_def :: %{
          type: :boolean | :string | :integer,
          alias: atom() | nil,
          values: [String.t()] | nil,
          doc: String.t()
        }

  @type command :: %{
          name: String.t(),
          aliases: [String.t()],
          usage: [String.t()],
          summary: String.t(),
          options: [atom() | {atom(), map()}],
          examples: [String.t()]
        }

  @type t :: %__MODULE__{
          tool_name: String.t(),
          tool_summary: String.t(),
          option_catalog: %{atom() => option_def()},
          global_option_names: [atom()],
          commands: [command()]
        }

  @doc "名前またはエイリアスからコマンド定義を引く"
  @spec find_command(t(), String.t() | nil) :: command() | nil
  def find_command(%__MODULE__{commands: commands}, name) do
    Enum.find(commands, fn command ->
      command.name == name or name in command.aliases
    end)
  end

  @doc """
  コマンドが使えるオプション定義(グローバル含む)。

  各要素は catalog の定義に `:name` を加えたマップ。spec の options に
  catalog に無い名前があれば `KeyError` を送出する。
  """
  @spec options_for(t(), %{:options => [atom() | {atom(), map()}], optional(any()) => any()}) ::
          [map()]
  def options_for(%__MODULE__{} = spec, %{options: entries}) do
    Enum.map(spec.global_option_names ++ entries, &resolve_option(spec.option_catalog, &1))
  end

  defp resolve_option(catalog, name) when is_atom(name) do
    catalog
    |> Map.fetch!(name)
    |> Map.put(:name, name)
  end

  defp resolve_option(catalog, {name, override}) do
    catalog
    |> Map.fetch!(name)
    |> Map.merge(override)
    |> Map.put(:name, name)
  end

  @doc "OptionParser の strict リスト(全オプションの和集合)"
  @spec strict_switches(t()) :: [{atom(), :boolean | :string | :integer}]
  def strict_switches(%__MODULE__{option_catalog: catalog}) do
    Enum.map(catalog, fn {name, %{type: type}} -> {name, type} end)
  end

  @doc "OptionParser の aliases リスト"
  @spec aliases(t()) :: [{atom(), atom()}]
  def aliases(%__MODULE__{option_catalog: catalog}) do
    for {name, %{alias: short}} <- catalog, short != nil, do: {short, name}
  end

  @doc "コマンドが受け付けるオプション名の MapSet(未知のコマンドは nil)"
  @spec allowed_for(t(), String.t()) :: MapSet.t() | nil
  def allowed_for(%__MODULE__{} = spec, name) do
    case find_command(spec, name) do
      nil -> nil
      command -> MapSet.new(options_for(spec, command), & &1.name)
    end
  end

  @doc """
  パース済みオプションをコマンド定義に対して検証する。

  コマンドに属さないオプションと enum 違反(コマンド固有の values を含む)を
  エラーにする。コマンド名が nil または未知の場合は :ok(dispatch 側が
  :help に落とす)。
  """
  @spec validate_opts(t(), String.t() | nil, keyword()) :: :ok | {:error, String.t()}
  def validate_opts(%__MODULE__{} = spec, command_name, opts) do
    case find_command(spec, command_name) do
      nil ->
        :ok

      command ->
        check_opts(command.name, opts, Map.new(options_for(spec, command), &{&1.name, &1}))
    end
  end

  defp check_opts(command_name, opts, defs) do
    case Enum.flat_map(opts, &opt_violation(&1, command_name, defs)) do
      [] -> :ok
      messages -> {:error, Enum.join(messages, "\n")}
    end
  end

  defp opt_violation({name, value}, command_name, defs) do
    case defs[name] do
      nil ->
        ["--#{render_name(name)} は #{command_name} コマンドでは使えません"]

      %{values: values} when is_list(values) ->
        if value in values do
          []
        else
          ["--#{render_name(name)} の値が不正です: #{value}（有効な値: #{Enum.join(values, ", ")}）"]
        end

      _ ->
        []
    end
  end

  @doc "グローバル help を spec から生成する"
  @spec render_help(t()) :: String.t()
  def render_help(%__MODULE__{} = spec) do
    command_sections = Enum.map_join(spec.commands, "\n", &render_command_section(spec, &1))

    """
    #{spec.tool_name} - #{spec.tool_summary}

    使用方法:
      #{spec.tool_name} <command> [options]
      #{spec.tool_name} <command> --help

    コマンド:
    #{command_sections}
    グローバルオプション:
    #{render_options(global_options(spec))}
    例:
    #{render_examples(spec)}
    """
  end

  @doc "コマンド単体の help を spec から生成する(未知のコマンドは nil)"
  @spec render_command_help(t(), String.t()) :: String.t() | nil
  def render_command_help(%__MODULE__{} = spec, name) do
    case find_command(spec, name) do
      nil ->
        nil

      command ->
        """
        #{spec.tool_name} #{command.name} - #{command.summary}

        使用方法:
        #{Enum.map_join(command.usage, "\n", &"  #{spec.tool_name} #{&1}")}

        オプション:
        #{render_options(options_for(spec, command))}
        例:
        #{Enum.map_join(command.examples, "\n", &"  #{spec.tool_name} #{&1}")}
        """
    end
  end

  defp render_command_section(spec, command) do
    usage_lines = Enum.map_join(command.usage, "\n", &"  #{&1}")

    option_names =
      Enum.map_join(command.options, " ", fn entry ->
        spec.option_catalog |> resolve_option(entry) |> render_option_name()
      end)

    option_line =
      if command.options == [] do
        ""
      else
        "      オプション: #{option_names}\n"
      end

    "#{usage_lines}\n      #{command.summary}\n#{option_line}"
  end

  defp render_options(options) do
    Enum.map_join(options, "\n", &render_option_line/1)
  end

  defp render_option_line(option) do
    # 値を取る型(string / integer)には VALUE プレースホルダを表示する
    value = if option.type == :boolean, do: "", else: " #{render_values(option)}"

    if single_char_name?(option.name) do
      "  -#{option.name}#{value}  #{option.doc}"
    else
      short = if option.alias, do: "-#{option.alias}, ", else: "    "
      "  #{short}--#{render_name(option.name)}#{value}  #{option.doc}"
    end
  end

  # 1 文字名のオプション（:t など）は短縮形のみを持つ
  defp render_option_name(option) do
    if single_char_name?(option.name) do
      "-#{option.name}"
    else
      "--#{render_name(option.name)}"
    end
  end

  defp single_char_name?(name), do: byte_size(Atom.to_string(name)) == 1

  defp render_values(%{values: values}) when is_list(values), do: Enum.join(values, "|")
  defp render_values(_), do: "VALUE"

  defp render_examples(spec) do
    spec.commands
    |> Enum.flat_map(& &1.examples)
    |> Enum.map_join("\n", &"  #{spec.tool_name} #{&1}")
  end

  defp global_options(spec) do
    Enum.map(spec.global_option_names, &resolve_option(spec.option_catalog, &1))
  end

  defp render_name(name), do: String.replace(Atom.to_string(name), "_", "-")
end
