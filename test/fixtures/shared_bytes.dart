import 'dart:async';
import 'dart:typed_data';

import 'package:napi/napi.dart';

typedef Bytes = SharedBytes;
Bytes? _saved;
WeakReference<Bytes>? _weak;
List<int> _pressure = [];
final _events = <String>[];
final _work = <int, Completer<void>>{};
int _entries = 0;
void Function()? _conversion;

@NAPI()
int entries() => _entries;
@NAPI()
List<String> events() => List.of(_events);
@NAPI()
Bytes remember(Bytes value) {
  _entries++;
  _saved = value;
  _weak = WeakReference(value);
  return value;
}

@NAPI()
bool same(Bytes value) => identical(_saved, value);
@NAPI()
bool alive() => _weak?.target != null;
@NAPI()
int drop() {
  _saved = null;
  return 0;
}

@NAPI()
int pressure() {
  _pressure = List.generate(250000, (i) => i);
  return _pressure.last;
}

@NAPI()
Bytes allocate(int length) => SharedBytes.allocate(length);
@NAPI()
int length() => _saved!.length;
@NAPI()
int read(int index) => _saved![index];
@NAPI()
int put(int index, int value) {
  _saved![index] = value;
  return value;
}

@NAPI()
Bytes view(int start, [int? end]) => _saved!.subview(start, end);
@NAPI()
Uint8List snapshot([int start = 0, int? end]) =>
    _saved!.toUint8List(start, end);
@NAPI()
int write(Uint8List source, int offset) {
  _saved!.write(source, offset: offset);
  return 0;
}

@NAPI()
int copy(Bytes source, int start, int offset, int? count) {
  _saved!.copyFrom(
    source,
    sourceOffset: start,
    targetOffset: offset,
    length: count,
  );
  return 0;
}

@NAPI()
Bytes? nullable(Bytes? value) => value;
@NAPI()
Bytes? optional([Bytes? value]) => value;
@NAPI()
Bytes? named({Bytes? value}) => value;
@NAPI()
Bytes requiredNamed({required Bytes value}) => value;
@NAPI()
List<Bytes?> lists(List<Bytes?> value) => value;
@NAPI()
Map<Bytes, Bytes> maps(Map<Bytes, Bytes> value) => value;
@NAPI()
Dictionary<Bytes> dictionary(Dictionary<Bytes> value) => value;
@NAPI()
(Bytes, {Bytes? other}) record((Bytes, {Bytes? other}) value) => value;

@NAPI(classPolicy: ClassPolicy.value)
class SharedPacket {
  final Bytes bytes;
  SharedPacket(this.bytes) {
    _weak = WeakReference(bytes);
    _conversion?.call();
  }
}

@NAPI()
SharedPacket packet(SharedPacket value) => value;
@NAPI()
int setConversion(void Function()? callback) {
  _conversion = callback;
  return 0;
}

@NAPI()
int packets(List<SharedPacket> values) => values.length;

@NAPI(classPolicy: ClassPolicy.value)
class Repair {
  int get value {
    _conversion?.call();
    return 7;
  }
}

@NAPI()
(Bytes, Repair) repairOutput() => (_saved!, Repair());
@NAPI()
int partial(SharedPacket first, int later) {
  _entries++;
  return first.bytes.length + later;
}

@NAPI()
class SharedBox {
  Bytes bytes;
  SharedBox(this.bytes);
  SharedBox.allocated(int size) : bytes = SharedBytes.allocate(size);
  void change(int byte) => bytes[0] = byte;
}

Future<Bytes> _hold(int id, Bytes value) async {
  final gate = Completer<void>();
  _work[id] = gate;
  _events.add('start:$id');
  await gate.future;
  _events.add('finish:$id');
  return value;
}

@NAPI()
Future<Bytes> hold(int id, Bytes value) => _hold(id, value);
@NAPI()
int complete(int id) {
  _work.remove(id)!.complete();
  return id;
}

@NAPI()
Future<int> delayedRead() async {
  await Future<void>.delayed(const Duration(milliseconds: 5));
  return _saved![0];
}

@NAPI()
int caught() {
  try {
    return _saved![0];
  } catch (_) {
    return -1;
  }
}

@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class SharedOwner {
  final int id;
  late final StreamController<Bytes> _controller;
  SharedOwner(this.id) {
    _controller = StreamController.broadcast(
      sync: true,
      onCancel: () => _events.add('cancel:$id'),
    );
  }
  Stream<Bytes> get values => _controller.stream;
  Stream<List<Bytes>> get rows =>
      _controller.stream.map((value) => [value, value]);
  void emit(Bytes bytes) {
    _controller.add(bytes);
    if (bytes.length > 0) bytes[0]++;
  }

  Future<Bytes> work(int task, Bytes bytes) => _hold(task, bytes);
  void close() => _events.add('cleanup:$id');
}

class _FakeBytes implements SharedBytes {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

@NAPI()
SharedBytes fakeOutput() => _FakeBytes();
@NAPI()
int fakeCopy() {
  _saved!.copyFrom(_FakeBytes());
  return 0;
}
