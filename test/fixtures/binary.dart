import 'dart:async';
import 'dart:typed_data';

import 'package:napi/napi.dart';

typedef Bytes = Uint8List;

int _entries = 0;
final _events = <String>[];
final _work = <int, Completer<void>>{};
final _output = Uint8List.fromList([90, 1, 2, 3, 91]);
void Function()? _conversion;
List<int> _pressure = [];

@NAPI()
int entries() => _entries;
@NAPI()
List<String> events() => List.of(_events);
@NAPI()
Bytes bytes(Bytes value) {
  _entries++;
  return value;
}

@NAPI()
ByteBuffer buffer(ByteBuffer value) {
  _entries++;
  return value;
}

@NAPI()
Uint8List? nullable(Uint8List? value) => value;
@NAPI()
Uint8List optional([Uint8List? value]) => value ?? Uint8List.fromList([7]);
@NAPI()
List<Uint8List?> named({Uint8List? value, ByteBuffer? other}) => [
  value,
  other?.asUint8List(),
];
@NAPI()
Uint8List requiredNamed({required Uint8List value}) => value;
@NAPI()
T opaque<T>(T value) => value;
@NAPI()
Uint8List window() => Uint8List.sublistView(_output, 1, 4);
@NAPI()
ByteBuffer windowBuffer() => Uint8List.sublistView(_output, 1, 4).buffer;
@NAPI()
Uint8List empty() => Uint8List(0);
@NAPI()
List<Uint8List> repeated() {
  final value = window();
  return [value, value];
}

@NAPI()
List<ByteBuffer> repeatedBuffers() => [_output.buffer, _output.buffer];

@NAPI()
List<Uint8List?> lists(List<Uint8List?> value) => value;
@NAPI()
Map<Uint8List, ByteBuffer> maps(Map<Uint8List, ByteBuffer> value) => value;
@NAPI()
Map<BinaryKey, Uint8List> keyed(Map<BinaryKey, Uint8List> value) => value;

@NAPI()
class BinaryKey {
  final int id;
  BinaryKey(this.id);
  @NAPI(exclude: true)
  @override
  // Keep identity equality while exercising hashCode reentry during Map input.
  // ignore: hash_and_equals
  int get hashCode {
    _conversion?.call();
    return id;
  }
}

@NAPI()
Dictionary<Uint8List> dictionary(Dictionary<Uint8List> value) => value;
@NAPI()
(Uint8List, {ByteBuffer data}) record((Uint8List, {ByteBuffer data}) value) =>
    value;

@NAPI(classPolicy: ClassPolicy.value, valueConstructor: 'new')
class Packet {
  final Uint8List bytes;
  final ByteBuffer data;
  Packet(this.bytes, this.data) {
    _conversion?.call();
  }
}

@NAPI()
int setConversion(void Function()? callback) {
  _conversion = callback;
  return 0;
}

@NAPI()
Packet packet(Packet value) => value;
@NAPI()
List<Packet> packets(List<Packet> value) => value;
@NAPI()
List<Uint8List> afterPacket(Packet first, Uint8List later) => [
  first.bytes,
  later,
];

@NAPI()
class BinaryBox {
  Uint8List bytes;
  ByteBuffer? data;
  BinaryBox(this.bytes, [this.data]);
  void change(int value) {
    if (bytes.isNotEmpty) bytes[0] = value;
    final buffer = data?.asUint8List();
    if (buffer != null && buffer.isNotEmpty) buffer[0] = value;
  }
}

Future<Uint8List> _hold(int id, Uint8List value) async {
  final gate = Completer<void>();
  _work[id] = gate;
  _events.add('start:$id');
  try {
    await gate.future;
    return value;
  } finally {
    _events.add('finish:$id');
  }
}

@NAPI()
Future<Uint8List> hold(int id, Uint8List value) => _hold(id, value);
@NAPI()
int complete(int id, {bool fail = false}) {
  final gate = _work.remove(id)!;
  if (fail) {
    gate.completeError(StateError('binary-failure:$id'));
  } else {
    gate.complete();
  }
  return id;
}

@NAPI()
Future<ByteBuffer> futureBuffer(ByteBuffer value) => Future.value(value);
@NAPI()
Future<Uint8List> futureWindow() => Future.value(window());
@NAPI()
Future<List<Uint8List>> futureRows() => Future.value(repeated());
@NAPI()
int changeOutput(int value) => _output[1] = value;
@NAPI()
int pressure() {
  _pressure = List.generate(250000, (i) => i);
  return _pressure.last;
}

@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class BinaryOwner {
  final int id;
  late final StreamController<Uint8List> _bytes;
  late final StreamController<ByteBuffer> _buffers;
  BinaryOwner(this.id) {
    _bytes = StreamController.broadcast(
      sync: true,
      onCancel: () => _events.add('cancel-bytes:$id'),
    );
    _buffers = StreamController.broadcast(
      sync: true,
      onCancel: () => _events.add('cancel-buffers:$id'),
    );
  }
  Stream<Uint8List> get values => _bytes.stream;
  Stream<List<Uint8List>> get rows =>
      _bytes.stream.map((value) => [value, value]);
  Stream<ByteBuffer> get buffers => _buffers.stream;
  void emit(int value) {
    final storage = Uint8List.fromList([90, value, value + 1, 91]);
    final view = Uint8List.sublistView(storage, 1, 3);
    _bytes.add(view);
    _buffers.add(storage.buffer);
    storage.fillRange(0, storage.length, 255);
  }

  Future<Uint8List> work(int task, Uint8List value) => _hold(task, value);
  void close() => _events.add('cleanup:$id');
}
