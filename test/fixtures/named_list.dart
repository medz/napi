import 'package:napi/napi.dart';

// This user declaration must not be mistaken for dart:core List<T>.
@NAPI(name: 'NamedList')
class List {
  final int value;
  List([this.value = 0]);
  List self() => this;
}

@NAPI()
List namedListIdentity(List value) => value;
