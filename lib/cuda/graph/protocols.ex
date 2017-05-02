alias Cuda.Graph
alias Cuda.Graph.Node
alias Cuda.Graph.Pin

defprotocol Graph.NodeProto do
  @doc """
  Returns pin by its id
  """
  @spec pin(node:: Node.t, id: Graph.id) :: Pin.t | nil
  def pin(node, id)

  @doc """
  Returns a list of pins of specified type
  """
  @spec pins(node :: Node.t, type :: Pin.type | [Pin.type]) :: [Pin.t]
  def pins(node, type)
end

defprotocol Graph.GraphProto do
  @spec add(graph :: Graph.t, node :: Node.t) :: Graph.t
  def add(graph, node)

  @doc """
  Returns node in the graph by its name
  """
  @spec node(graph :: Graph.t, id :: Graph.id) :: Node.t
  def node(graph, id)
end

defimpl Graph.NodeProto, for: Any do
  def pin(%{pins: pins}, id) do
    pins |> Enum.find(fn
      %Pin{id: ^id} -> true
      _             -> false
    end)
  end
  def get_pin(_, _), do: nil

  def pins(%{pins: pins}, type) when is_atom(type) do
    pins |> Enum.filter(fn
      %Pin{type: ^type} -> true
      _                 -> false
    end)
  end
  def pins(_, []), do: []
  def pins(node, [type | rest]) do
    pins(node, type) ++ pins(node, rest)
  end
  def pins(_, _), do: []
end

defimpl Graph.GraphProto, for: Any do
  require Cuda
  import Cuda, only: [compile_error: 1]

  def add(%{nodes: nodes} = graph, %{id: id} = node) do
    with nil <- node(graph, id) do
      %{graph | nodes: [node | nodes]}
    else
      _ -> compile_error("Node with id `#{id}` is already in the graph")
    end
  end

  def node(%{nodes: nodes}, id) do
    nodes |> Enum.find(fn
      %{id: ^id} -> true
      _          -> false
    end)
  end
  def node(_, _), do: nil
end
