/// Shims for dart:isolate on the web.
///
/// PATCHED (xprs): ported from dart:html to dart:js_interop so it compiles
/// under dart2wasm as well as dart2js. See README.xprs.md.
library html_isolate;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_rust_bridge/src/ffi/web.dart';

typedef MessagePort = PortLike;

/// An alias to [MessagePort] on web platforms.
typedef SendPort = PortLike;

typedef NativePortType = dynamic;

abstract class Channel {
  SendPort get sendPort;
  SendPort get receivePort;
  const Channel();
  factory Channel.messageChannel() = _MessageChannelWrapper;
  factory Channel.broadcastChannel(String channelName) =
      _BroadcastChannelWrapper;
}

JSObject _construct(String constructor, [JSAny? arg]) {
  final ctor = globalContext[constructor]! as JSFunction;
  return arg == null ? ctor.callAsConstructor() : ctor.callAsConstructor(arg);
}

class _MessageChannelWrapper implements Channel {
  final JSObject channel = _construct('MessageChannel');
  @override
  SendPort get sendPort =>
      PortLike.messagePort(channel['port2']! as JSObject);
  @override
  SendPort get receivePort =>
      PortLike.messagePort(channel['port1']! as JSObject);
}

class _BroadcastChannelWrapper implements Channel {
  final JSObject channel;
  _BroadcastChannelWrapper(String channelName)
      : channel = _construct('BroadcastChannel', channelName.toJS);
  @override
  SendPort get sendPort => PortLike.broadcastChannel(channel);
  @override
  SendPort get receivePort => sendPort;
}

/// Wrapper around a [MessageChannel].
class RawReceivePort {
  /// The underlying message channel.
  final Channel channel;
  RawReceivePort([Channel? channel])
      : channel = channel ?? Channel.messageChannel();

  set handler(Function(dynamic) handler) {
    receivePort.onMessage.listen((data) => handler(data));
  }

  /// Close the receive port.
  void close() => channel.receivePort.close();

  /// The port to be used by other workers.
  SendPort get sendPort => channel.sendPort;

  /// The port used to receive messages from other workers.
  SendPort get receivePort => channel.receivePort;
}

/// Web implementation of the `dart:isolate`'s ReceivePort.
class ReceivePort extends Stream<dynamic> {
  /// The receive port.
  final RawReceivePort port;

  /// Create a new receive port from an optional [RawReceivePort].
  ReceivePort([RawReceivePort? port]) : port = port ?? RawReceivePort();

  @override
  StreamSubscription listen(
    void Function(dynamic event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return port.receivePort.onMessage.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  /// The send port.
  SendPort get sendPort => port.sendPort;

  /// Close the receive port, ignoring any further messages.
  void close() => port.receivePort.close();
}

ReceivePort broadcastPort(String channelName) =>
    ReceivePort(RawReceivePort(Channel.broadcastChannel(channelName)));

/// A JS `MessagePort` or `BroadcastChannel`.
///
/// Upstream extended dart:html's `EventTarget`; this keeps the members the
/// bridge uses, over the JS object in [nativePort].
abstract class PortLike {
  factory PortLike.messagePort(JSObject port) = _MessagePortWrapper;
  factory PortLike.broadcastChannel(JSObject channel) = _BroadcastPortWrapper;
  void postMessage(Object? value);
  void close();
  NativePortType get nativePort;
  void addEventListener(String type, JSFunction? listener, [bool? useCapture]);
  void removeEventListener(String type, JSFunction? listener,
      [bool? useCapture]);

  /// The `data` of every `message` event, converted with `dartify`.
  Stream<Object?> get onMessage;
}

/// Converts a Dart message to a JS value for `postMessage`.
JSAny? _jsMessage(Object? value) {
  if (value == null) return null;
  // ignore: invalid_runtime_check_with_js_interop_types
  if (value is JSAny) return value;
  return value.jsify();
}

/// Delegates a subset of PortLike methods verbatim.
abstract class _DelegatedPort implements PortLike {
  @override
  JSObject get nativePort;

  @override
  void addEventListener(String type, JSFunction? listener,
          [bool? useCapture]) =>
      nativePort.callMethod<JSAny?>('addEventListener'.toJS, type.toJS,
          listener, useCapture?.toJS);

  @override
  void removeEventListener(String type, JSFunction? listener,
          [bool? useCapture]) =>
      nativePort.callMethod<JSAny?>('removeEventListener'.toJS, type.toJS,
          listener, useCapture?.toJS);

  @override
  void close() => nativePort.callMethod<JSAny?>('close'.toJS);

  @override
  Stream<Object?> get onMessage {
    late final StreamController<Object?> controller;
    final listener = ((JSObject event) {
      controller.add(event['data'].dartify());
    }).toJS;
    controller = StreamController<Object?>(
      onListen: () {
        addEventListener('message', listener);
        // A MessagePort only delivers once started; addEventListener does
        // not start it implicitly (onmessage would).
        if (nativePort.has('start')) {
          nativePort.callMethod<JSAny?>('start'.toJS);
        }
      },
      onCancel: () => removeEventListener('message', listener),
    );
    return controller.stream;
  }
}

class _MessagePortWrapper extends _DelegatedPort {
  @override
  final JSObject nativePort;
  _MessagePortWrapper(this.nativePort);

  @override
  void postMessage(message, [List<Object>? transfer]) {
    if (transfer == null) {
      nativePort.callMethod<JSAny?>('postMessage'.toJS, _jsMessage(message));
    } else {
      nativePort.callMethod<JSAny?>('postMessage'.toJS, _jsMessage(message),
          _jsMessage(transfer));
    }
  }
}

class _BroadcastPortWrapper extends _DelegatedPort {
  @override
  final JSObject nativePort;
  _BroadcastPortWrapper(this.nativePort);

  /// This presents a limitation of BroadcastChannel,
  /// i.e. it cannot carry transferables and will unconditionally clone the items.
  @override
  void postMessage(message, [List<Object>? transfer]) {
    if (transfer != null && transfer.isNotEmpty) {
      warn("Ignoring transferables for BroadcastPort:", transfer);
    }
    nativePort.callMethod<JSAny?>(
        'postMessage'.toJS, _jsMessage(message ?? false));
  }
}
