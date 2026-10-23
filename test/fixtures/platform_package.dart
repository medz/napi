import 'package:napi/napi.dart';

int _calls = 0;
final _singleton = Counter(7);

@NAPI()
int calls() => _calls;

@NAPI()
int add(int value, [int amount = 2]) {
  _calls++;
  return value + amount;
}

@NAPI()
Counter singleton() => _singleton;

@NAPI()
class Counter {
  int value;
  Counter([this.value = 1]);
  int increment([int amount = 1]) => value += amount;
}
