defmodule Eml do
  @moduledoc """
  Eml makes markup a first class citizen in Elixir. It provides a
  flexible and modular toolkit for generating, parsing and
  manipulating markup. It's main focus is html, but other markup
  languages could be implemented as well.

  To start off:

  This piece of code
  ```elixir
  use Eml.HTML.Elements

  name = "Vincent"
  age  = 36

  div class: "person" do
    div do
      span "name: "
      span name
    end
    div do
      span "age: "
      span age
    end
  end |> Eml.render
  ```

  produces
  ```html
  <div class='person'>
    <div>
      <span>name: </span>
      <span>Vincent</span>
    </div>
    <div>
      <span>age: </span>
      <span>36</span>
    </div>
  </div>
  ```

  The functions and macro's in the `Eml` module cover most of
  Eml's public API.
  """

  alias Eml.Element

  @default_renderer Eml.HTML.Renderer
  @default_parser Eml.HTML.Parser

  @type t               :: String.t | Eml.Element.t | { :safe, String.t } | { :quoted, Macro.t }
  @type content         :: [t]
  @type transformable   :: t | [t]
  @type bindings        :: [{ atom, Eml.Encoder.t }]
  @type unpackr_result  :: funpackr_result | [unpackr_result]
  @type funpackr_result :: String.t | Macro.t | [String.t | Macro.t]

  @doc """
  Define a template function that renders eml to a string during compile time.

  Quoted expressions are evaluated at runtime and it's results are
  rendered to eml and concatenated with the precompiled eml.

  Eml uses the assigns extension from `EEx` for easy data access in
  a template. See the `EEx` docs for more info about them. Since all
  runtime behaviour is written in quoted expressions, assigns need to
  be quoted too. To prevent you from writing `quote do: @my_assign` all
  the time, atoms can be used as a shortcut. This means that for example
  `div(:a)` and `div(quote do: @a)` have the same result. This convertion
  is being performed by the `Eml.Encoder` protocol. The function that the
  template macro defines accepts optionally an Keyword list for binding
  values to assigns.

  Note that because the unquoted code is evaluated at compile time, it's not
  possible to call other functions from the same module. Quoted expressions
  however can call any local function, including other templates.

  Instead of defining a do block, you can also provide a path to a file with
  the `:file` option.

  In addition, all options of `Eml.render/3` also apply to the template macro.

  ### Example:

      iex> File.write! "test.eml.exs", "div(quote do: @number + @number)"
      iex> defmodule MyTemplates do
      ...>   use Eml
      ...>   use Eml.HTML.Elements
      ...>
      ...>   template fruit do
      ...>     prefix = "fruit"
      ...>     div do
      ...>       span [class: "prefix"], prefix
      ...>       span [class: "name"], :name
      ...>     end
      ...>   end
      ...>
      ...>   template tropical_fruit do
      ...>     body do
      ...>       h2 "Tropical Fruit"
      ...>       quote do
      ...>         for n <- @names do
      ...>           fruit name: n
      ...>         end
      ...>       end
      ...>     end
      ...>   end
      ...>
      ...>   template from_file, file: "test.eml.exs"
      ...> end
      iex> File.rm! "test.eml.exs"
      iex> MyTemplates.tropical_fruit names: ~w(mango papaya banana acai)
      {:safe,
       "<body><h2>Tropical Fruit</h2><div><span class='prefix'>fruit</span><span class='name'>mango</span></div><div><span class='prefix'>fruit</span><span class='name'>papaya</span></div><div><span class='prefix'>fruit</span><span class='name'>banana</span></div><div><span class='prefix'>fruit</span><span class='name'>acai</span></div></body>"}
      iex> MyTemplates.from_file number: 21
      { :safe, "<div>42</div>" }
      iex> MyTemplates.precompile()
      "<body><p>Strawberry</p></body>"

  """
  defmacro template(name, opts, do_block \\ []) do
    do_template(name, opts, do_block, __CALLER__, false)
  end

  @doc """
  Same as `template/3`, except that it defines a private function.
  """
  defmacro templatep(name, opts, do_block \\ []) do
    do_template(name, opts, do_block, __CALLER__, true)
  end

  defp do_template(name, opts, do_block, caller, private) do
    opts = Keyword.merge(opts, do_block)
    compiled = precompile(caller, opts)
    { name, _, _ } = name
    def_call = if private, do: :defp, else: :def
    quote do
      unquote(def_call)(unquote(name)(var!(assigns) \\ [])) do
        _ = var!(assigns)
        unquote(compiled)
      end
    end
  end


  @doc """
  Define a template as an anonymous function.

  All non quoted expressions are precompiled and the anonymous function that
  is returned expects a Keyword list for binding assigns.

  See `template/3` for more info.

  ### Example
      iex> t = template_fn do
      ...>   names = quote do
      ...>     for n <- @names, do: li n
      ...>   end
      ...>   ul names
      ...> end
      iex> t.(names: ~w(john james jesse))
      {:safe, "<ul><li>john</li><li>james</li><li>jesse</li></ul>"}

  """
  defmacro template_fn(opts, do_block \\ []) do
    opts = Keyword.merge(opts, do_block)
    compiled = precompile(__CALLER__, opts)
    quote do
      fn var!(assigns) ->
        _ = var!(assigns)
        unquote(compiled)
      end
    end
  end

  @doc """
  Converts data to `eml` content by using the `Eml.Encoder` protocol.

  It also concatenates binaries and flatten lists to ensure the result
  is valid content.

  ### Example

      iex> Eml.encode(["1", 2, [3], " ", ["miles"]])
      ["123 miles"]

  You can also use this function to add data to existing content:

      iex> Eml.encode(42, [" is the number"], :begin)
      ["42 is the number"]

      iex> Eml.encode(42, ["the number is "], :end)
      ["the number is 42"]

  """
  @spec encode(Eml.Encoder.t | [Eml.Encoder.t], content, atom) :: content
  def encode(data, acc \\ [], insert_at \\ :begin)

  # No-ops
  def encode(nondata, acc, _)
  when nondata in [nil, "", []], do: acc

  # Handle lists
  def encode(data, acc, :end)
  when is_list(data), do: add_nodes(data, :lists.reverse(acc), :end) |> :lists.reverse()
  def encode(data, acc, :begin)
  when is_list(data), do: add_nodes(:lists.reverse(data), acc, :begin)

  # Convert data to eml node
  def encode(data, acc, insert_at) do
    Eml.Encoder.encode(data) |> add_node(acc, insert_at)
  end

  defp add_node(node, [], _), do: [node]
  defp add_node(node, [h | t], :end) do
    if is_binary(node) and is_binary(h) do
      [h <> node | t]
    else
      [node, h | t]
    end
  end
  defp add_node(node, [h | t], :begin) do
    if is_binary(node) and is_binary(h) do
      [node <> h | t]
    else
      [node, h | t]
    end
  end

  defp add_nodes([h | t], acc, insert_at) do
    acc = if is_list(h) and insert_at === :end do
            add_nodes(h, acc, insert_at)
          else
            encode(h, acc, insert_at)
          end
    add_nodes(t, acc, insert_at)
  end
  defp add_nodes([], acc, _), do: acc

  defmacro decode(eml, opts, do_block \\ []) do
    opts = Keyword.merge(opts, do_block)
    quote do
      case unquote(eml) do
        unquote(opts[:match]) ->
          { :ok, unquote(opts[:do]) }
        _ ->
          { :error, :nomatch }
      end
    end
  end

  @doc """
  Parses data and converts it to eml

  How the data is interpreted depends on the `parser` argument.
  The default value is `Eml.HTML.Parser', which means that
  strings are parsed as html.

  In case of error, raises an Eml.ParseError exception.

  ### Examples:

      iex> Eml.parse("<body><h1 id='main-title'>The title</h1></body>")
      [#body<[#h1<%{id: "main-title"} ["The title"]>]>]
  """
  @spec parse(String.t, module) :: content
  def parse(data, parser \\ @default_parser)

  def parse(data, parser) when is_binary(data) do
    parser.parse(data)
  end
  def parse(data, _) do
    raise Eml.ParseError, type: :unsupported_input, value: data
  end

  @doc """
  Renders eml content with the specified markup renderer, which is html by default.

  When the provided eml contains quoted expressions that use assigns,
  you can bind to these by providing a Keyword list as the
  second argument.

  The accepted options are:

  * `:renderer` - The renderer to use, by default `Eml.HTML.Renderer`
  * `:quotes` - The type of quotes used for attribute values. Accepted values are `:single` (default) and `:double`.
  * `:safe` - When true, escape `&`, `<`, `>` `'` and `\"` in attribute values and content.
     Accepted values are `true` (default) and `false`.
  * `:prerender` - A function that receives every node just before it gets rendered.
  * `:postrender` - A function that receives all rendered chunks.

  If the option `:safe` is true, the rendered string will be wrapped in a `{ :safe, string }`
  tuple. This allows the result to be inserted as content in other Eml elements, without the markup
  getting escaped.

  In case of error, raises an Eml.CompileError exception. If the input contains a quoted expression
  that has a compile or runtime error, an exception will be raised for those too.

  ### Examples:

      iex> Eml.render(body(h1([id: "main-title"], "A title")))
      {:safe, "<body><h1 id='main-title'>A title</h1></body>"}

      iex> Eml.render(body(h1([id: "main-title"], "A title")), quotes: :double)
      {:safe, "<body><h1 id=\"main-title\">A title</h1></body>"}

      iex> Eml.render(p "Tom & Jerry")
      {:safe, "<p>Tom &amp; Jerry</p>"}

      iex> Eml.render(p("Tom & Jerry"), [], safe: false)
      "<p>Tom & Jerry</p>"

      iex> Eml.render(p(quote do: @names), names: "Tom & Jerry")
      {:safe, "<p>Tom &amp; Jerry</p>"}

      iex> Eml.render(p(:names), names: "Tom & Jerry")
      {:safe, "<p>Tom &amp; Jerry</p>"}

  """
  @spec render(t, Eml.bindings, Keyword.t) :: String.t
  def render(eml, assigns \\ [], opts \\ [])

  def render({ :safe, string }, _assigns, _opts) do
    { :safe, string }
  end
  def render({ :quoted, quoted }, assigns, _opts) do
    { string, _ } = Code.eval_quoted(quoted, [assigns: assigns])
    string
  end
  def render(content, assigns, opts) do
    { renderer, opts } = Keyword.pop(opts, :renderer, @default_renderer)
    opts = Keyword.put(opts, :mode, :render)
    case renderer.render(content, opts) do
      quoted = { :quoted, _ } -> render(quoted, assigns, opts)
      string -> string
    end
  end

  @doc """
  Compiles eml to a quoted expression.

  Accepts the same options as `Eml.render/3` and its result
  can be rendered to a string with a subsequent call to `Eml.render/3`.

  In case of error, raises an Eml.CompileError exception.

  ### Examples:

      iex> t = Eml.compile(body(h1([id: "main-title"], :the_title)))
      #Quoted<[:the_title]>
      iex> t.chunks
      ["<body><h1 id='main-title'>", #param:the_title, "</h1></body>"]
      iex> Eml.render(t, the_title: "The Title")
      "<body><h1 id='main-title'>The Title</h1></body>"

  """

  @spec compile(t, Keyword.t) :: Eml.Quoted.t
  def compile(eml, opts \\ []) do
    { renderer, opts } = Keyword.pop(opts, :renderer, @default_renderer)
    opts = Keyword.put(opts, :mode, :compile)
    renderer.render(eml, opts)
  end

  @doc false
  @spec precompile(Macro.Env.t | Keyword.t, Keyword.t) :: Macro.t
  def precompile(env \\ [], opts) do
    file = opts[:file]
    ast = if file do
            string = File.read!(file)
            Code.string_to_quoted!(string, file: file, line: 1)
          else
            opts[:do]
          end
    { res, _ } = Code.eval_quoted(ast, [], env)
    compile_opts = Keyword.take(opts, [:escape, :quotes, :renderer])
    { :quoted, compiled } = Eml.compile(res, compile_opts)
    compiled
  end

  @doc """
  Recursively transforms `eml` content.

  This is the most low level operation provided by Eml for manipulating
  eml nodes. For example, `update/3` and `remove/2` are implemented by
  using this function.

  It accepts any eml and traverses all nodes of the provided eml tree.
  The provided transform function will be evaluated for every node `transform/3`
  encounters. Parent nodes will be transformed before their children. Child nodes
  of a parent will be evaluated before moving to the next sibling.

  When the provided function returns `nil`, the node will
  be removed from the eml tree. Any other returned value will be
  evaluated by `Eml.encode/3` in order to guarantee valid eml.

  Note that because parent nodes are evaluated before their children,
  no children will be evaluated if the parent is removed.

  ### Examples:

      iex> use Eml.Transform
      iex> e = div do
      ...>   span [id: "inner1", class: "inner"], "hello "
      ...>   span [id: "inner2", class: "inner"], "world"
      ...> end
      #div<[#span<%{id: "inner1", class: "inner"} ["hello "]>,
       #span<%{id: "inner2", class: "inner"} ["world"]>]>
      iex> transform(e, fn x -> if Element.has?(x, tag: :span), do: "matched", else: x end)
      [#div<["matched", "matched"]>]
      iex> transform(e, fn x ->
      ...> IO.puts(inspect x)
      ...> x end)
      #div<[#span<%{id: "inner1", class: "inner"} ["hello "]>, #span<%{id: "inner2", class: "inner"} ["world"]>]>
      #span<%{id: "inner1", class: "inner"} ["hello "]>
      "hello "
      #span<%{id: "inner2", class: "inner"} ["world"]>
      "world"
      [#div<[#span<%{id: "inner1", class: "inner"} ["hello "]>,
        #span<%{id: "inner2", class: "inner"} ["world"]>]>]

  """
  @spec transform(transformable, (t -> Eml.Encoder.t)) :: transformable | nil
  def transform(eml, fun) when is_list(eml) do
    for node <- eml, t = transform(node, fun), do: t
  end
  def transform(node, fun) do
    node = fun.(node) |> Eml.Encoder.encode()
    if element?(node) do
      %Element{node| content: transform(node.content, fun)}
    else
      node
    end
  end

  @doc """
  Extracts a value from content (which is always a list) or an element

  ### Examples

      iex> Eml.unpack ["42"]
      "42"

      iex> Eml.unpack 42
      42

      iex> Eml.unpack(div "hallo")
      "hallo"

      iex> Eml.unpack Eml.unpack(div(span("hallo")))
      "hallo"

  """
  @spec unpack(t | [t]) :: t | [t]
  def unpack({ :safe, string }),          do: string
  def unpack(%Element{content: content}), do: unpack(content)
  def unpack([node]),                     do: node
  def unpack(content_or_node),            do: content_or_node

  @doc """
  Extracts a value recursively from content or an element

  ### Examples

      iex> Eml.unpackr div(span(42))
      "42"

      iex> Eml.unpackr div([span("Hallo"), span(" world")])
      ["Hallo", " world"]

  """
  @spec unpackr(t) :: unpackr_result
  def unpackr({ :safe, string }),             do: string
  def unpackr(%Element{content: [node]}),     do: unpackr(node)
  def unpackr(%Element{content: content}),    do: unpack_content(content)
  def unpackr([node]),                        do: unpackr(node)
  def unpackr(content) when is_list(content), do: unpack_content(content)
  def unpackr(node),                          do: node

  defp unpack_content(content) do
    for node <- content, do: unpackr(node)
  end

  @doc """
  Extracts a value recursively from content or an element and flatten the results.
  """
  @spec funpackr(t) :: funpackr_result
  def funpackr(eml), do: unpackr(eml) |> :lists.flatten

  @doc "Checks if a term is a `Eml.Element` struct."
  @spec element?(term) :: boolean
  def element?(%Element{}), do: true
  def element?(_),   do: false

  @doc "Checks if a value is regarded as empty by Eml."
  @spec empty?(term) :: boolean
  def empty?(nil), do: true
  def empty?([]), do: true
  def empty?(%Element{content: []}), do: true
  def empty?(_), do: false

  @doc """
  Returns the type of content.

  The types are `:string`, `:safe_string`, `:element`, `:quoted`, or `:undefined`.
  """
  @spec type(t) :: :string | :safe_string | :element | :quoted | :undefined
  def type(node) when is_binary(node), do: :string
  def type({ :safe, _ }), do: :safe_string
  def type({ :quoted, _ }), do: :quoted
  def type(%Element{}), do: :element
  def type(_), do: :undefined

  # use Eml
  @doc """
  Import macro's and alias core modules.

  Invoking it translates to:
  ```
  alias Eml.Element
  alias Eml.Query
  alias Eml.Transform
  import Eml, only: [template_fn: 1, template_fn: 2, template: 2, template: 3]
  ```
  """
  defmacro __using__(_) do
    quote do
      alias Eml.Element
      alias Eml.Query
      alias Eml.Transform
      import Eml, only: [template_fn: 1, template_fn: 2, template: 2, template: 3, decode: 2, decode: 3]
    end
  end
end
