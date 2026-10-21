import 'package:napi/napi.dart';

int _constructions = 0;
int _cleanups = 0;
CollectionNode? _escapedNode;

@NAPI()
int collectionValueConstructions() => _constructions;

@NAPI()
int collectionValueCleanups() => _cleanups;

@NAPI(classPolicy: ClassPolicy.value)
class CollectionRejecting {
  CollectionRejecting() {
    throw StateError('value constructor rejected');
  }

  int get value => 1;
}

@NAPI()
void collectionReject<T>(JsArray<(CollectionRejecting, T)> values) =>
    values.get(0);

@NAPI(classPolicy: ClassPolicy.value)
class CollectionValue {
  final int value;
  final int? tag;
  CollectionValue(this.value, {this.tag = 7}) {
    _constructions++;
  }

  @NAPI(exclude: true)
  @override
  int get hashCode => value.hashCode;
  @override
  bool operator ==(Object other) =>
      other is CollectionValue && other.value == value;
}

@NAPI(classPolicy: ClassPolicy.value)
class CollectionParsed {
  final int value;
  CollectionParsed.parse(String source) : value = int.parse(source);
  int get doubled => value * 2;
}

@NAPI(classPolicy: ClassPolicy.value)
class CollectionNode {
  final int value;
  final JsArray<CollectionNode>? children;
  CollectionNode(this.value, {this.children});
}

@NAPI(classPolicy: ClassPolicy.value)
class CollectionOutput {
  final int value;
  CollectionOutput._(this.value);
}

@NAPI(classPolicy: ClassPolicy.value)
class CollectionEnvelope {
  final CollectionValue child;
  final int tail;
  CollectionEnvelope(this.child, {this.tail = 5});
}

@NAPI(classPolicy: ClassPolicy.value)
class CollectionEscaping {
  final CollectionNode node;
  final bool fail;
  CollectionEscaping(this.node, this.fail) {
    _escapedNode = node;
    if (fail) throw StateError('collection constructor failed');
  }
}

@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class CollectionResource {
  final int value;
  CollectionResource(this.value);
  void close() => _cleanups++;
}

@NAPI(classPolicy: ClassPolicy.value)
class CollectionResourceValue {
  final CollectionResource _resource;
  final void Function() _close;
  CollectionResourceValue._(this._resource, this._close);
  CollectionResource get resource => _resource;
  int get value {
    _close();
    return _resource.value;
  }
}

@NAPI()
class ValueCollectionOwner {
  final JsArray<CollectionValue?> _values;
  final JsMap<CollectionValue, CollectionValue> _map;
  final JsArray<CollectionOutput?> _outputs;
  CollectionResource? _resource;
  ValueCollectionOwner(this._values, this._map, this._outputs);

  JsArray<CollectionValue?> values() => _values;
  CollectionValue? read(int index) => _values.get(index);
  void copy(int index) => _values.set(index, _values.get(0));
  bool copiedKey() {
    final (key, value) = _map.entries.first;
    if (_map.has(key) || _map.get(key) != null || _map.delete(key)) {
      return false;
    }
    _map.set(key, value);
    return true;
  }

  CollectionOutput? readOutput(int index) => _outputs.get(index);
  void writeOutput(int index) => _outputs.set(index, CollectionOutput._(17));
  List<CollectionValue>? readList(JsArray<List<CollectionValue>> values) =>
      values.get(0);
  Map<CollectionValue, int>? readMap(
    JsArray<Map<CollectionValue, int>> values,
  ) => values.get(0);
  int parsed(JsArray<CollectionParsed> values) => values.get(0)!.value;
  void writeParsed(JsArray<CollectionParsed> values) =>
      values.set(0, CollectionParsed.parse('19'));
  JsArray<CollectionNode>? nodeChildren(JsArray<CollectionNode> values) =>
      values.get(0)!.children;
  void copyNode(JsArray<CollectionNode> values) =>
      values.set(1, values.get(0)!);
  int envelope(JsArray<CollectionEnvelope> values) =>
      values.get(0)!.child.value;
  void escape(JsArray<CollectionEscaping> values) => values.get(0);
  int escapedChild() => _escapedNode!.children!.get(0)!.value;
  void remember(CollectionResource resource) => _resource = resource;
  void writeResource(
    JsArray<CollectionResourceValue> values,
    void Function() close,
  ) => values.set(0, CollectionResourceValue._(_resource!, close));
}
