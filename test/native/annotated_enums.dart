import 'dart:async';

import 'package:napi/napi.dart';

@NAPI()
enum Status { ready, done }

@NAPI(name: 'Mode')
enum DartMode {
  @NAPI(name: 'fast')
  _quick(7),
  slow(11);

  const DartMode(this.code);
  final int code;
}

@NAPI()
Status echoStatus(Status value) => value;

@NAPI()
Status toggle(Status value) =>
    value == Status.ready ? Status.done : Status.ready;

@NAPI()
int modeCode(DartMode value) => switch (value) {
  DartMode._quick => value.code,
  DartMode.slow => value.code,
};

const _defaultStatus = Status.done;

@NAPI()
Status defaultStatus([Status value = _defaultStatus]) => value;

@NAPI()
Status? nullableStatus([Status? value]) => value;

@NAPI()
class Job {
  @NAPI()
  Job([this.status = Status.ready]);
  @NAPI()
  Status status;
  @NAPI()
  Status? next;

  @NAPI()
  Status finish() => status = Status.done;
}

@NAPI()
List<Status?> echoStatuses(List<Status?> values) => values;

@NAPI()
({Status status, Status? next}) statusRecord(
  ({Status status, Status? next}) value,
) => value;

@NAPI()
Status applyStatus(Status value, Status Function(Status) callback) =>
    callback(value);

@NAPI()
Future<Status> futureStatus(Future<Status> value) => value;

@NAPI()
Stream<Status> statuses() async* {
  yield Status.ready;
  yield Status.done;
}
