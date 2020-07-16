import 'dart:async';
import 'dart:typed_data';

import '../core/rsocket_error.dart';
import '../frame/frame_types.dart' as frame_types;
import '../duplex_connection.dart';
import '../payload.dart';
import '../rsocket.dart';
import '../frame/frame.dart';
import 'stream_id_supplier.dart';

Future<void> voidFuture() async {}

const MAX_REQUEST_N_SIZE = 0x7FFFFFFF;

abstract class Subscriber {
  void onNext(Payload value);

  void onError(dynamic error);

  void onComplete();
}

class CompleterSubscriber implements Subscriber {
  Completer completer;
  Payload payload;

  CompleterSubscriber(this.completer);

  @override
  void onNext(Payload payload) {
    this.payload = payload;
  }

  @override
  void onError(dynamic error) {
    completer.completeError(error);
  }

  @override
  void onComplete() {
    completer.complete(payload);
  }
}

class StreamSubscriber implements Subscriber {
  StreamController controller = StreamController();

  @override
  void onNext(Payload value) {
    controller.add(value);
  }

  @override
  void onError(dynamic error) {
    controller.addError(error);
  }

  @override
  void onComplete() {
    controller.close().then((value) => {});
  }

  Stream<Payload> payloadStream() {
    return controller.stream.map((item) => item as Payload);
  }
}

class RSocketRequester extends RSocket {
  bool closed = false;
  double _availability = 1.0;
  Timer keepAliveTimer;
  StreamIdSupplier streamIdSupplier;
  ConnectionSetupPayload connectionSetupPayload;
  DuplexConnection connection;

  Map<int, Subscriber> senders = {};
  RSocket responder;
  String mode = 'requester';
  ErrorConsumer errorConsumer;

  RSocketRequester(String mode, ConnectionSetupPayload connectionSetupPayload, DuplexConnection connection) {
    this.mode = mode;
    if (mode == 'requester') {
      streamIdSupplier = StreamIdSupplier.clientSupplier();
    } else {
      streamIdSupplier = StreamIdSupplier.serverSupplier();
    }
    this.connectionSetupPayload = connectionSetupPayload;
    this.connection = connection;
    if (this.connection.receiveHandler == null) {
      this.connection.receiveHandler = (chunk) => receiveChunk(chunk);
    }
    this.connection.closeHandler = () {
      close();
    };
    initRSocketCallStubs();
  }

  void initRSocketCallStubs() {
    //RSocket requestResponse
    requestResponse = (payload) {
      var completer = Completer<Payload>();
      var streamId = streamIdSupplier.nextStreamId(senders);
      connection.write(FrameCodec.encodeRequestResponseFrame(streamId, payload));
      senders[streamId] = CompleterSubscriber(completer);
      return completer.future;
    };
    //RSocket fireAndForget
    fireAndForget = (payload) {
      var streamId = streamIdSupplier.nextStreamId(senders);
      connection.write(FrameCodec.encodeFireAndForgetFrame(streamId, payload));
      return Future.value(() {});
    };
    //RSocket requestStream
    requestStream = (payload) {
      var streamId = streamIdSupplier.nextStreamId(senders);
      connection.write(FrameCodec.encodeRequestStreamFrame(streamId, MAX_REQUEST_N_SIZE, payload));
      var streamSubscriber = StreamSubscriber();
      senders[streamId] = streamSubscriber;
      return streamSubscriber.payloadStream();
    };
    //RSocket metadataPush
    metadataPush = (payload) {
      connection.write(FrameCodec.encodeMetadataFrame(0, payload));
      return Future.value(() {});
    };
    //Rsocket Channel
    /*requestChannel = (payloads) {
      var streamId = streamIdSupplier.nextStreamId(senders);
      connection.write(FrameCodec.encodeChannelFrame(streamId, MAX_REQUEST_N_SIZE, payload));
      var streamSubscriber = StreamSubscriber();
      senders[streamId] = streamSubscriber;
      return streamSubscriber.payloadStream();
    };*/
  }

  void sendSetupPayload() {
    connection.init();
    connection.write(setupPayloadFrame());
    if (mode == 'requester') {
      const oneSec = Duration(seconds: 20);
      keepAliveTimer = Timer.periodic(oneSec, (Timer t) {
        print('timer 20 seconds');
        if (!closed) {
          connection.write(FrameCodec.encodeKeepAlive(false, 0));
        } else {
          keepAliveTimer?.cancel();
        }
      });
    }
  }

  @override
  void close() {
    if (!closed) {
      closed = true;
      _availability = 0.0;
      keepAliveTimer.cancel();
      connection.close();
    }
  }

  @override
  double availability() {
    return _availability;
  }

  void receiveChunk(Uint8List chunk) {
    for (var frame in parseFrames(chunk)) {
      receiveFrame(frame);
    }
  }

  void receiveFrame(RSocketFrame frame) {
    var header = frame.header;
    var streamId = header.streamId;
    switch (header.type) {
      case frame_types.PAYLOAD:
        var payloadFrame = frame as PayloadFrame;
        if (senders.containsKey(streamId)) {
          var subscriber = senders[streamId];
          var payload = payloadFrame.payload;
          if (payloadFrame.completed) {
            senders.remove(streamId);
            if (payload?.data != null) {
              subscriber.onNext(payload);
            }
            subscriber.onComplete();
          } else {
            if (payload?.data != null) {
              subscriber.onNext(payload);
            }
          }
        }
        break;
      case frame_types.KEEPALIVE:
        var keepAliveFrame = frame as KeepAliveFrame;
        if (keepAliveFrame.respond) {
          connection.write(FrameCodec.encodeKeepAlive(false, keepAliveFrame.lastReceivedPosition));
        }
        break;
      case frame_types.ERROR:
        var errorFrame = frame as ErrorFrame;
        var streamId = header.streamId;
        var error = RSocketException(errorFrame.code, errorFrame.message);
        if (streamId == 0 && errorConsumer != null) {
          errorConsumer(error);
        } else {
          if (senders.containsKey(streamId)) {
            var subscriber = senders[streamId];
            senders.remove(streamId);
            subscriber.onError(error);
          }
        }
        break;
      case frame_types.CANCEL:
        var streamId = header.streamId;
        if (senders.containsKey(streamId)) {
          //implement cancel
          //var subscriber = senders[streamId];
          //senders.remove(streamId);
        }
        break;
      case frame_types.REQUEST_RESPONSE:
        var requestResponseFrame = frame as RequestResponseFrame;
        if (responder != null && requestResponseFrame.payload != null) {
          responder.requestResponse(requestResponseFrame.payload).then((payload) {
            connection.write(FrameCodec.encodePayloadFrame(header.streamId, true, payload));
          }).catchError((error) {
            var rsocketError = convertToRSocketException(error);
            connection.write(FrameCodec.encodeErrorFrame(header.streamId, rsocketError.code, rsocketError.message));
          });
        }
        break;
      case frame_types.REQUEST_FNF:
        var fireAndForgetFrame = frame as RequestFNFFrame;
        if (responder != null && fireAndForgetFrame.payload != null) {
          responder.fireAndForget(fireAndForgetFrame.payload).then((value) => {});
        }
        break;
      case frame_types.METADATA_PUSH:
        var metadataPushFrame = frame as MetadataPushFrame;
        if (responder != null && metadataPushFrame.payload != null) {
          responder.metadataPush(metadataPushFrame.payload).then((value) => {});
        }
        break;
      default:
    }
  }

  Uint8List setupPayloadFrame() {
    return FrameCodec.encodeSetupFrame(connectionSetupPayload.keepAliveInterval, connectionSetupPayload.keepAliveMaxLifetime,
        connectionSetupPayload.metadataMimeType, connectionSetupPayload.dataMimeType, connectionSetupPayload);
  }
}

RSocketException convertToRSocketException(dynamic e) {
  if (e == null) {
    return RSocketException(RSocketErrorCode.APPLICATION_ERROR, 'Error');
  } else if (e is RSocketException) {
    return e;
  } else {
    return RSocketException(RSocketErrorCode.APPLICATION_ERROR, e.toString());
  }
}