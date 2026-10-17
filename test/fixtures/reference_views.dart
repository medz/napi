import 'package:napi/napi.dart';

int _constructions = 0;
_Combined? _held;

@NAPI()
abstract class ReadBase {
  ReadBase._();
  int shared([int amount = 1]);
}

@NAPI()
abstract class ReadView extends ReadBase {
  ReadView._() : super._();
  factory ReadView(int value) => _Combined(value);
  int get value;
  @override
  int shared([int amount = 7]);
  ReadView self();
  static int readOnlyStatic() => 1;
}

@NAPI()
abstract class WriteView {
  WriteView._();
  set value(int value);
  int shared([int amount = 7]);
  String describe();
}

@NAPI()
abstract class ExtraView {
  ExtraView._();
  int extra();
}

class _Combined extends ReadView implements WriteView, ExtraView {
  _Combined(this.value) : super._() {
    _constructions++;
  }
  @override
  int value;
  @override
  int shared([int amount = 99]) => value + amount;
  @override
  ReadView self() => this;
  @override
  String describe() => 'value=$value';
  @override
  int extra() => value * 2;
}

@NAPI()
int compositeConstructions() => _constructions;
@NAPI()
ReadView makeReadView(int value) => _held = _Combined(value);
@NAPI()
WriteView makeWriteView(int value) => _held = _Combined(value);
@NAPI()
ReadView? heldReadView() => _held;
@NAPI()
WriteView? heldWriteView() => _held;
@NAPI()
ExtraView? heldExtraView() => _held;
@NAPI()
int clearComposite() {
  _held = null;
  return 0;
}

@NAPI()
ReadView echoReadView(ReadView value) => value;
@NAPI()
WriteView echoWriteView(WriteView value) => value;
@NAPI()
ExtraView echoExtraView(ExtraView value) => value;
@NAPI()
(ReadView, WriteView, ExtraView) compositeViews(ReadView value) =>
    (value, value as WriteView, value as ExtraView);
@NAPI()
List<ReadView> compositeList(List<ReadView> values) => values;
@NAPI()
(ReadView, int) failingComposite() => (_held = _Combined(23), 9007199254740992);

@NAPI()
abstract class DefaultViewA {
  DefaultViewA._();
  int conflicting([int amount = 1]);
}

@NAPI()
abstract class DefaultViewB {
  DefaultViewB._();
  int conflicting([int amount = 2]);
}

class _DefaultConflict implements DefaultViewA, DefaultViewB {
  @override
  int conflicting([int amount = 3]) => amount;
}

final _defaults = _DefaultConflict();
@NAPI()
DefaultViewA conflictingDefaultsA() => _defaults;
@NAPI()
DefaultViewB conflictingDefaultsB() => _defaults;

@NAPI()
abstract class AliasViewA {
  AliasViewA._();
  @NAPI(name: 'action')
  int first();
}

@NAPI()
abstract class AliasViewB {
  AliasViewB._();
  @NAPI(name: 'action')
  int second();
}

class _AliasConflict implements AliasViewA, AliasViewB {
  @override
  int first() => 1;
  @override
  int second() => 2;
}

@NAPI()
AliasViewA conflictingAliases() => _AliasConflict();
