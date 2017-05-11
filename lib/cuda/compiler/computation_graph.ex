defimpl Cuda.Compiler.GPUUnit, for: Cuda.Graph do
  alias Cuda.Graph.Node
  alias Cuda.Graph.Pin
  alias Cuda.Graph.NodeProto
  alias Cuda.Graph.GraphProto
  alias Cuda.Graph.Processing
  alias Cuda.Compiler.GPUUnit

  import Node, only: [input_pin_types: 0, output_pin_types: 0]

  def sources(%{type: :computation_graph, id: gid} = graph, ctx) do
    with {:ok, nodes} <- Processing.topology_sort(graph) do
      nodes = nodes
              |> Enum.map(fn {node, _pin} -> node end)
              |> Enum.reject(& &1 == gid)
      {_, offset, _} = nodes
                       |> Enum.with_index
                       |> Enum.reduce({graph, 0, 0}, &collect_sizes/2)
      state = {:ok, {graph, 0, offset, ctx, []}}
      with {:ok, {_, _, _, _, sources}} <- Enum.reduce(nodes, state, &collect_sources/2) do
        {:ok, sources}
      else
        {:error, _} = error -> error
        error               -> {:error, error}
      end
    else
      error -> {:error, error}
    end
  end
  def sources(_, _), do: {:ok, []}

  defp collect_sizes({node, idx}, {graph, s1, s2}) when div(idx, 2) == 0 do
    node = GraphProto.node(graph, node)
    {pins1, pins2} = case div(idx, 2) do
      0 -> {input_pin_types(), output_pin_types()}
      _ -> {output_pin_types(), input_pin_types()}
    end
    size1 = node
            |> NodeProto.pins(pins1)
            |> Enum.map(&Pin.data_size/1)
            |> Enum.max()
    size2 = node
            |> NodeProto.pins(pins2)
            |> Enum.map(&Pin.data_size/1)
            |> Enum.max()
    {graph, Enum.max([s1, size1]), Enum.max([s2, size2])}
  end

  defp collect_sources(node, {:ok, {graph, offset1, offset2, ctx, sources}}) do
    node = GraphProto.node(graph, node)
    {offsets, _} = node
                   |> NodeProto.pins(input_pin_types())
                   |> Enum.reduce({%{}, offset1}, &collect_offsets/2)
    {offsets, _} = node
                   |> NodeProto.pins(output_pin_types())
                   |> Enum.reduce({offsets, offset2}, &collect_offsets/2)
    assigns = Map.put(ctx.assigns, :offsets, offsets)
    with {:ok, node} <- node.module.handle_compile(node),
         {:ok, src} <- GPUUnit.sources(node, %{ctx | assigns: assigns}) do
      sources = sources ++ src
      {:ok, {graph, offset2, offset1, ctx, sources}}
    end
  end
  defp collect_sources(_, error), do: error

  defp collect_offsets(pin, {offsets, offset}) do
    {Map.put(offsets, pin.id, offset), offset + Pin.data_size(pin)}
  end
end

defimpl Cuda.Compiler.Unit, for: Cuda.Graph do
  alias Cuda.Compiler
  alias Cuda.Compiler.GPUUnit
  alias Cuda.Graph.NodeProto
  require Logger

  def compile(%{type: :computation_graph} = graph, ctx) do
    Logger.info("CUDA: Compiling GPU code for graph #{graph.module} (#{graph.id})")
    with {:ok, graph}   <- graph.module.handle_compile(graph),
         {:ok, sources} <- GPUUnit.sources(graph, ctx),
         {:ok, cubin}   <- Compiler.compile(sources) do
      {:ok, NodeProto.assign(graph, :cubin, cubin)}
    else
      _ ->
        Logger.warn("CUDA: Error while compiling GPU code for graph " <>
                    "#{graph.module} (#{graph.id})")
        {:error, :compile_error}
    end
  end
  def compile(%{nodes: nodes} = graph, ctx) do
    Logger.info("CUDA: Compiling graph #{graph.module} (#{graph.id})")
    with {:ok, graph}    <- graph.module.handle_compile(graph, ctx),
         {:ok, _, nodes} <- Enum.reduce(nodes, {:ok, ctx, []}, &compile_reducer/2) do
      {:ok, %{graph | nodes: nodes}}
    else
      _ ->
        Logger.warn("CUDA: Error while compiling graph " <>
                    "#{graph.module} (#{graph.id})")
        {:error, :compile_error}
    end
  end

  defp compile_reducer(node, {:ok, ctx, nodes}) do
    with {:ok, node} <- Cuda.Compiler.Unit.compile(node, ctx) do
      {:ok, ctx, [node | nodes]}
    end
  end
  defp compile_reducer(_, error) do
    error
  end
end

defimpl Cuda.Compiler.Unit, for: Cuda.Graph.Node do
  require Logger

  def compile(node, ctx) do
    Logger.info("CUDA: Compiling node #{node.module} (#{node.id})")
    node.module.handle_compile(node, ctx)
  end
end
