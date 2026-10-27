import 'package:napi/napi.dart';

@NAPI()
class Counter {
  @NAPI()
  Counter([this.value = 0]);

  @NAPI()
  int value;

  @NAPI()
  Counter same() => this;

  @NAPI()
  int increment([int step = 1]) {
    final next = value + step;
    if (next < -9007199254740991 || next > 9007199254740991) {
      throw RangeError('Result exceeds JavaScript safe integers');
    }
    return value = next;
  }
}
