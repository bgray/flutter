// Copyright 2018 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:io';

import 'package:json_rpc_2/json_rpc_2.dart' as json_rpc;
import 'package:web_socket_channel/io.dart';

import '../common/logging.dart';

const Duration _kConnectTimeout = const Duration(seconds: 9);

const Duration _kReconnectAttemptInterval = const Duration(seconds: 3);

const Duration _kRpcTimeout = const Duration(seconds: 5);

final Logger _log = new Logger('DartVm');

/// Signature of an asynchronous function for astablishing a JSON RPC-2
/// connection to a [Uri].
typedef Future<json_rpc.Peer> RpcPeerConnectionFunction(Uri uri);

/// [DartVm] uses this function to connect to the Dart VM on Fuchsia.
///
/// This function can be assigned to a different one in the event that a
/// custom connection function is needed.
RpcPeerConnectionFunction fuchsiaVmServiceConnectionFunction = _waitAndConnect;

/// Attempts to connect to a Dart VM service.
///
/// Gives up after `_kConnectTimeout` has elapsed.
Future<json_rpc.Peer> _waitAndConnect(Uri uri) async {
  final Stopwatch timer = new Stopwatch()..start();

  Future<json_rpc.Peer> attemptConnection(Uri uri) async {
    WebSocket socket;
    json_rpc.Peer peer;
    try {
      socket = await WebSocket.connect(uri.toString());
      peer = new json_rpc.Peer(new IOWebSocketChannel(socket).cast())..listen();
      return peer;
    } on HttpException catch (e) {
      // This is a fine warning as this most likely means the port is stale.
      _log.fine('$e: ${e.message}');
      await peer?.close();
      await socket?.close();
      rethrow;
    } catch (e) {
      // Other unknown errors will be handled with reconnects.
      await peer?.close();
      await socket?.close();
      if (timer.elapsed < _kConnectTimeout) {
        _log.info('Attempting to reconnect');
        await new Future<Null>.delayed(_kReconnectAttemptInterval);
        return attemptConnection(uri);
      } else {
        _log.severe('Connection to Fuchsia\'s Dart VM timed out at '
            '${uri.toString()}');
        rethrow;
      }
    }
  }

  return attemptConnection(uri);
}

/// Restores the VM service connection function to the default implementation.
void restoreVmServiceConnectionFunction() {
  fuchsiaVmServiceConnectionFunction = _waitAndConnect;
}

/// An error raised when a malformed RPC response is received from the Dart VM.
///
/// A more detailed description of the error is found within the [message]
/// field.
class RpcFormatError extends Error {
  /// Basic constructor outlining the reason for the format error.
  RpcFormatError(this.message);

  /// The reason for format error.
  final String message;

  @override
  String toString() {
    return '$RpcFormatError: $message\n${super.stackTrace}';
  }
}

/// Handles JSON RPC-2 communication with a Dart VM service.
///
/// Either wraps existing RPC calls to the Dart VM service, or runs raw RPC
/// function calls via [invokeRpc].
class DartVm {
  DartVm._(this._peer, this.uri);

  final json_rpc.Peer _peer;

  /// The URI through which this DartVM instance is connected.
  final Uri uri;

  /// Attempts to connect to the given [Uri].
  ///
  /// Throws an error if unable to connect.
  static Future<DartVm> connect(Uri uri) async {
    if (uri.scheme == 'http') {
      uri = uri.replace(scheme: 'ws', path: '/ws');
    }
    final json_rpc.Peer peer = await fuchsiaVmServiceConnectionFunction(uri);
    if (peer == null) {
      return null;
    }
    return new DartVm._(peer, uri);
  }

  /// Returns a [List] of [IsolateRef] objects whose name matches `pattern`.
  ///
  /// Also checks to make sure it was launched from the `main()` function.
  Future<List<IsolateRef>> getMainIsolatesByPattern(Pattern pattern) async {
    final Map<String, dynamic> jsonVmRef =
        await invokeRpc('getVM', timeout: _kRpcTimeout);
    final List<Map<String, dynamic>> jsonIsolates = jsonVmRef['isolates'];
    final List<IsolateRef> result = <IsolateRef>[];
    for (Map<String, dynamic> jsonIsolate in jsonIsolates) {
      final String name = jsonIsolate['name'];
      if (name.contains(pattern) && name.contains(new RegExp(r':main\(\)'))) {
        result.add(new IsolateRef._fromJson(jsonIsolate, this));
      }
    }
    return result;
  }

  /// Invokes a raw JSON RPC command with the VM service.
  ///
  /// When `timeout` is set and reached, throws a [TimeoutException].
  ///
  /// If the function returns, it is with a parsed JSON response.
  Future<Map<String, dynamic>> invokeRpc(
    String function, {
    Map<String, dynamic> params,
    Duration timeout = _kRpcTimeout,
  }) async {
    final Future<Map<String, dynamic>> future = _peer.sendRequest(
      function,
      params ?? <String, dynamic>{},
    );
    if (timeout == null) {
      return future;
    }
    return future.timeout(timeout, onTimeout: () {
      throw new TimeoutException(
        'Peer connection timed out during RPC call',
        timeout,
      );
    });
  }

  /// Returns a list of [FlutterView] objects running across all Dart VM's.
  ///
  /// If there is no associated isolate with the flutter view (used to determine
  /// the flutter view's name), then the flutter view's ID will be added
  /// instead. If none of these things can be found (isolate has no name or the
  /// flutter view has no ID), then the result will not be added to the list.
  Future<List<FlutterView>> getAllFlutterViews() async {
    final List<FlutterView> views = <FlutterView>[];
    final Map<String, dynamic> rpcResponse =
        await invokeRpc('_flutter.listViews', timeout: _kRpcTimeout);
    final List<Map<String, dynamic>> flutterViewsJson = rpcResponse['views'];
    for (Map<String, dynamic> jsonView in flutterViewsJson) {
      final FlutterView flutterView = new FlutterView._fromJson(jsonView);
      if (flutterView != null) {
        views.add(flutterView);
      }
    }
    return views;
  }

  /// Disconnects from the Dart VM Service.
  ///
  /// After this function completes this object is no longer usable.
  Future<Null> stop() async {
    await _peer?.close();
  }
}

/// Represents an instance of a Flutter view running on a Fuchsia device.
class FlutterView {
  FlutterView._(this._name, this._id);

  /// Attempts to construct a [FlutterView] from a json representation.
  ///
  /// If there is no isolate and no ID for the view, throws an [RpcFormatError].
  /// If there is an associated isolate, and there is no name for said isolate,
  /// also throws an [RpcFormatError].
  ///
  /// All other cases return a [FlutterView] instance. The name of the
  /// view may be null, but the id will always be set.
  factory FlutterView._fromJson(Map<String, dynamic> json) {
    final Map<String, dynamic> isolate = json['isolate'];
    final String id = json['id'];
    String name;
    if (isolate != null) {
      name = isolate['name'];
      if (name == null) {
        throw new RpcFormatError('Unable to find name for isolate "$isolate"');
      }
    }
    if (id == null) {
      throw new RpcFormatError(
          'Unable to find view name for the following JSON structure "$json"');
    }
    return new FlutterView._(name, id);
  }

  /// Determines the name of the isolate associated with this view. If there is
  /// no associated isolate, this will be set to the view's ID.
  final String _name;

  /// The ID of the Flutter view.
  final String _id;

  /// The ID of the [FlutterView].
  String get id => _id;

  /// Returns the name of the [FlutterView].
  ///
  /// May be null if there is no associated isolate.
  String get name => _name;
}

/// This is a wrapper class for the `@Isolate` RPC object.
///
/// See:
/// https://github.com/dart-lang/sdk/blob/master/runtime/vm/service/service.md#isolate
///
/// This class contains information about the Isolate like its name and ID, as
/// well as a reference to the parent DartVM on which it is running.
class IsolateRef {
  IsolateRef._(this.name, this.number, this.dartVm);

  factory IsolateRef._fromJson(Map<String, dynamic> json, DartVm dartVm) {
    final String number = json['number'];
    final String name = json['name'];
    final String type = json['type'];
    if (type == null) {
      throw new RpcFormatError('Unable to find type within JSON "$json"');
    }
    if (type != '@Isolate') {
      throw new RpcFormatError('Type "$type" does not match for IsolateRef');
    }
    if (number == null) {
      throw new RpcFormatError(
          'Unable to find number for isolate ref within JSON "$json"');
    }
    if (name == null) {
      throw new RpcFormatError(
          'Unable to find name for isolate ref within JSON "$json"');
    }
    return new IsolateRef._(name, int.parse(number), dartVm);
  }

  /// The full name of this Isolate (not guaranteed to be unique).
  final String name;

  /// The unique number ID of this isolate.
  final int number;

  /// The parent [DartVm] on which this Isolate lives.
  final DartVm dartVm;
}
