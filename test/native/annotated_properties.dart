import 'package:napi/napi.dart';

export 'annotated_properties_exports.dart' show crossValue;

int _initializations = 0;
int _initialize() => ++_initializations + 6;

@NAPI()
final int lazyFinal = _initialize();

@NAPI()
int lazyMutable = _initialize();

@NAPI()
late final int deferredFinal;

@NAPI()
void initializeDeferred(int value) => deferredFinal = value;

@NAPI()
int initializations() => _initializations;

@NAPI()
int count = 1;

@NAPI()
set crossValue(int value) => count = value;

@NAPI()
int? nullableCount;

int _reads = 0;
@NAPI()
int get reads => ++_reads;
set reads(int value) => _reads = value;

int _written = 0;
int get writeOnly => _written;
@NAPI()
set writeOnly(int value) => _written = value;

@NAPI()
int written() => writeOnly;

String _display = 'initial';
@NAPI(name: 'display')
String get formatted => _display;
@NAPI(name: 'display')
set formatted(Object? value) => _display = value.toString();

@NAPI()
set rejected(Object? value) => throw JsException(value);

int _increment(int value) => value + 1;
@NAPI()
int Function(int) operation = _increment;

@NAPI()
int useOperation(int value) => operation(value);

@NAPI.object()
class Point {
  @NAPI()
  Point(String value) : _value = int.parse(value);
  final int _value;

  @NAPI()
  int get value => _value;
}

@NAPI()
Point point = Point('3');

@NAPI()
class Token {
  @NAPI()
  Token(this.value);

  @NAPI()
  final int value;
}

@NAPI()
Token token = Token(3);

@NAPI()
Token echoToken(Token value) => value;

JsReference<JsObject>? _saved;
@NAPI()
JsReference<JsObject>? get saved => _saved;
@NAPI()
set saved(JsReference<JsObject>? value) {
  _saved?.dispose();
  _saved = value;
}

@NAPI()
void clearSaved() => saved = null;

@NAPI()
const fixed = 'constant';

@NAPI()
int twice(int value) => value * 2;

int hidden = 1;
int get hiddenAccessor => hidden;
