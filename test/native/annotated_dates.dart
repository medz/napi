import 'package:napi/napi.dart';

@NAPI()
DateTime echoDate(DateTime value) => value;

@NAPI()
bool dateIsUtc(DateTime value) => value.isUtc;

@NAPI()
DateTime fromMicroseconds(int value) =>
    DateTime.fromMicrosecondsSinceEpoch(value, isUtc: true);

@NAPI()
DateTime? nullableDate([DateTime? value]) => value;

@NAPI()
List<DateTime?> echoDates(List<DateTime?> values) => values;

@NAPI()
DateTime Function(DateTime) bounceDate(DateTime Function(DateTime) callback) =>
    callback;
