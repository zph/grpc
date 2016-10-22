defmodule GRPC.ServiceTest do
  use ExUnit.Case, async: true

  defmodule Routeguide do
    @external_resource Path.expand("../../priv/protos/route_guide.proto", __DIR__)
    use Protobuf, from: Path.expand("../../priv/protos/route_guide.proto", __DIR__)

    defmodule RouteGuide.Service do
      use GRPC.Service, name: "routeguide.RouteGuide"

      rpc :GetFeature, Routeguide.Point, Routeguide.Feature
      rpc :ListFeatures, Routeguide.Rectangle, stream(Routeguide.Feature)
      rpc :RecordRoute, stream(Routeguide.Point), Routeguide.RouteSummary
      rpc :RouteChat, stream(Routeguide.RouteNote), stream(Routeguide.RouteNote)
    end

    defmodule RouteGuide.Stub do
      use GRPC.Stub, service: RouteGuide.Service
    end

    defmodule RouteGuide.Server do
      use GRPC.Server, service: RouteGuide.Service
      alias GRPC.Server

      def get_feature(point, _conn) do
        simple_feature(point)
      end

      def list_features(rectangle, conn) do
        Enum.each [rectangle.lo, rectangle.hi], fn (point)->
          feature = simple_feature(point)
          Server.stream_send(conn, feature)
        end
      end

      def record_route(stream, conn) do
        points = Enum.reduce stream, [], fn (point, acc) ->
          [point|acc]
        end
        fake_num = length(points)
        Routeguide.RouteSummary.new(point_count: fake_num, feature_count: fake_num,
                                    distance: fake_num, elapsed_time: fake_num)
      end

      def route_chat(stream, conn) do
        Enum.each stream, fn note ->
          note = %{note | message: "Reply: #{note.message}"}
          Server.stream_send(conn, note)
        end
      end

      defp simple_feature(point) do
        Routeguide.Feature.new(location: point, name: "#{point.latitude},#{point.longitude}")
      end
    end
  end

  test "Unary RPC works" do
    GRPC.Server.start(Routeguide.RouteGuide.Server, "localhost:50051", insecure: true)

    {:ok, channel} = GRPC.Channel.connect("localhost:50051", insecure: true)
    point = Routeguide.Point.new(latitude: 409_146_138, longitude: -746_188_906)
    feature = channel |> Routeguide.RouteGuide.Stub.get_feature(point)
    assert feature == Routeguide.Feature.new(location: point, name: "409146138,-746188906")
    :ok = GRPC.Server.stop(Routeguide.RouteGuide.Server)
  end

  test "Server streaming RPC works" do
    GRPC.Server.start(Routeguide.RouteGuide.Server, "localhost:50051", insecure: true)

    {:ok, channel} = GRPC.Channel.connect("localhost:50051", insecure: true)
    low = Routeguide.Point.new(latitude: 400000000, longitude: -750000000)
    high = Routeguide.Point.new(latitude: 420000000, longitude: -730000000)
    rect = Routeguide.Rectangle.new(lo: low, hi: high)
    stream = channel |> Routeguide.RouteGuide.Stub.list_features(rect)
    assert Enum.to_list(stream) == [
      Routeguide.Feature.new(location: low, name: "400000000,-750000000"),
      Routeguide.Feature.new(location: high, name: "420000000,-730000000")
    ]
    :ok = GRPC.Server.stop(Routeguide.RouteGuide.Server)
  end

  test "Client streaming RPC works" do
    GRPC.Server.start(Routeguide.RouteGuide.Server, "localhost:50051", insecure: true)

    {:ok, channel} = GRPC.Channel.connect("localhost:50051", insecure: true)
    point1 = Routeguide.Point.new(latitude: 400000000, longitude: -750000000)
    point2 = Routeguide.Point.new(latitude: 420000000, longitude: -730000000)
    stream = channel |> Routeguide.RouteGuide.Stub.record_route
    GRPC.Stub.stream_send(stream, point1)
    GRPC.Stub.stream_send(stream, point2, end_stream: true)
    res = GRPC.Stub.recv(stream)
    assert %GRPC.ServiceTest.Routeguide.RouteSummary{point_count: 2} = res
    :ok = GRPC.Server.stop(Routeguide.RouteGuide.Server)
  end

  test "Bidirectional streaming RPC works" do
    GRPC.Server.start(Routeguide.RouteGuide.Server, "localhost:50051", insecure: true)

    {:ok, channel} = GRPC.Channel.connect("localhost:50051", insecure: true)
    current = self()
    stream = channel |> Routeguide.RouteGuide.Stub.route_chat
    task = Task.async(fn ->
      Enum.each(1..6, fn (i) ->
        point = Routeguide.Point.new(latitude: 0, longitude: rem(i, 3) + 1)
        note = Routeguide.RouteNote.new(location: point, message: "Message #{i}")
        opts = if i == 6, do: [end_stream: true], else: []
        GRPC.Stub.stream_send(stream, note, opts)
      end)
    end)
    stream_result = GRPC.Stub.recv(stream)
    notes = Enum.map stream_result, fn (note)->
      assert "Reply: " <> _msg = note.message
      note
    end
    assert length(notes) > 0
    :ok = GRPC.Server.stop(Routeguide.RouteGuide.Server)
  end
end
