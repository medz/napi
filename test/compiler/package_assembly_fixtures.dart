import 'package:napi/napi.dart';

@NAPI()
int add(int left, int right) => left + right;

@NAPI()
int optional([int value = 42]) => value;

@NAPI()
String echo(String value) => value;
