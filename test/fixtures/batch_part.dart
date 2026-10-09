part of 'batch.dart';

typedef BatchPart = ({int code, String message});

@napi
List<BatchPart?>? echoPart(List<BatchPart?>? values) => values;

@napi
Future<List<BatchPart?>?> echoPartAsync(List<BatchPart?>? values) async =>
    values;
