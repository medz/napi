import 'package:napi/napi.dart';

@NAPI()
class Counter {
  Counter([this.value = 0]);

  int value;

  int increment([int amount = 1]) => value += amount;
}
