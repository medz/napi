import 'dart:collection';

import 'package:napi/napi.dart';

export 'named_list.dart';

typedef Item = (
  String, {
  List<int?>? values,
  ({bool flag, double ratio})? detail,
});

int _calls = 0;
List<List<int?>?>? _saved;

@NAPI()
int structuralCalls() => _calls;

@NAPI()
List<List<int?>?>? structuralLists(List<List<int?>?>? value) {
  _calls++;
  _saved = value;
  return value;
}

@NAPI()
List<List<int?>?>? structuralSaved() => _saved;

@NAPI()
List<Item?> structuralRecords(List<Item?> value) {
  _calls++;
  return value;
}

@NAPI()
({List<int?>? values, ({String label})? nested})? structuralNamed(
  ({List<int?>? values, ({String label})? nested})? value,
) {
  _calls++;
  return value;
}

@NAPI()
(int,) structuralSingle((int,) value) => value;

@NAPI()
() structuralEmpty(() value) => value;

@NAPI()
List<bool> structuralBooleans(List<bool> value) => value;

@NAPI()
List<double> structuralDoubles(List<double> value) => value;

@NAPI()
List<String> structuralStrings(List<String> value) => value;

@NAPI(bigint: true)
List<({int wide, BigInt huge})> structuralBigInts(
  List<({int wide, BigInt huge})> value,
) => value;

@NAPI()
List<int?>? structuralOptional([List<int?>? value]) => value;

@NAPI()
List<int?>? structuralNamedRequired({required List<int?>? value}) => value;

@NAPI()
List<int?>? structuralNamedOptional({List<int?>? value}) => value;

@NAPI()
List<int?>? structuralMixed(List<int?>? value, [bool ignored = false]) => value;

@NAPI()
List<int> structuralUnsafeOutput() => [9007199254740992];

@NAPI()
List<int> structuralLargeOutput() => List.filled(10000, 1);

final class _ThrowingList extends ListBase<int> {
  final bool indexError;
  _ThrowingList(this.indexError);
  @override
  int get length => indexError ? 1 : throw StateError('output length failed');
  @override
  set length(int value) => throw UnimplementedError();
  @override
  int operator [](int index) => throw StateError('output element failed');
  @override
  void operator []=(int index, int value) => throw UnimplementedError();
}

@NAPI()
List<int> structuralThrowingOutput(bool indexError) =>
    _ThrowingList(indexError);

int _outputReads = 0;
@NAPI()
int structuralOutputReads() => _outputReads;

@NAPI()
(int, List<int>) structuralOutputOrder(bool throwing) {
  _outputReads = 0;
  return (9007199254740992, _OutputOrderList(throwing));
}

@NAPI()
(Map<double, int>, List<int>) structuralCollisionOrder(bool throwing) {
  _outputReads = 0;
  final entries = <double, int>{}
    ..[double.nan] = 1
    ..[double.nan] = 2;
  return (entries, _OutputOrderList(throwing));
}

final class _OutputOrderList extends ListBase<int> {
  final bool throwing;
  _OutputOrderList(this.throwing);
  @override
  int get length {
    _outputReads++;
    if (throwing) throw StateError('later output getter failed');
    return 1;
  }

  @override
  set length(int value) => throw UnsupportedError('fixed length');
  @override
  int operator [](int index) => 7;
  @override
  void operator []=(int index, int value) => throw UnsupportedError('readonly');
}

final class _InvalidLengthList extends ListBase<int> {
  final int reportedLength;
  _InvalidLengthList(this.reportedLength);
  @override
  int get length => reportedLength;
  @override
  set length(int value) => throw UnimplementedError();
  @override
  int operator [](int index) => throw StateError('must check length first');
  @override
  void operator []=(int index, int value) => throw UnimplementedError();
}

@NAPI()
List<int> structuralInvalidLength(int length) => _InvalidLengthList(length);

void main() => throw StateError('business main must not run');

typedef StructuralDepth1 = List<List<List<List<List<int>>>>>;
typedef StructuralDepth2 = List<List<List<List<List<StructuralDepth1>>>>>;
typedef StructuralDepth3 = List<List<List<List<List<StructuralDepth2>>>>>;
typedef StructuralDepth4 = List<List<List<List<List<StructuralDepth3>>>>>;
typedef StructuralDepth5 = List<List<List<List<List<StructuralDepth4>>>>>;
typedef StructuralDepth6 = List<List<List<List<List<StructuralDepth5>>>>>;
typedef StructuralDepth7 = List<List<List<List<List<StructuralDepth6>>>>>;
typedef StructuralDepth8 = List<List<List<List<List<StructuralDepth7>>>>>;
typedef StructuralDepth9 = List<List<List<List<List<StructuralDepth8>>>>>;
typedef StructuralDepth10 = List<List<List<List<List<StructuralDepth9>>>>>;
typedef StructuralDepth11 = List<List<List<List<List<StructuralDepth10>>>>>;
typedef StructuralDepth12 = List<List<List<List<List<StructuralDepth11>>>>>;
typedef StructuralDepth13 = List<List<List<List<List<StructuralDepth12>>>>>;

@NAPI()
StructuralDepth13 structuralDepth(StructuralDepth13 value) => value;

@NAPI()
StructuralDepth13 structuralDeepOutput() => [
  [
    [
      [
        [
          [
            [
              [
                [
                  [
                    [
                      [
                        [
                          [
                            [
                              [
                                [
                                  [
                                    [
                                      [
                                        [
                                          [
                                            [
                                              [
                                                [
                                                  [
                                                    [
                                                      [
                                                        [
                                                          [
                                                            [
                                                              [
                                                                [
                                                                  [
                                                                    [
                                                                      [
                                                                        [
                                                                          [
                                                                            [
                                                                              [
                                                                                [
                                                                                  [
                                                                                    [
                                                                                      [
                                                                                        [
                                                                                          [
                                                                                            [
                                                                                              [
                                                                                                [
                                                                                                  [
                                                                                                    [
                                                                                                      [
                                                                                                        [
                                                                                                          [
                                                                                                            [
                                                                                                              [
                                                                                                                [
                                                                                                                  [
                                                                                                                    [
                                                                                                                      [
                                                                                                                        [
                                                                                                                          [
                                                                                                                            [
                                                                                                                              [
                                                                                                                                [1],
                                                                                                                              ],
                                                                                                                            ],
                                                                                                                          ],
                                                                                                                        ],
                                                                                                                      ],
                                                                                                                    ],
                                                                                                                  ],
                                                                                                                ],
                                                                                                              ],
                                                                                                            ],
                                                                                                          ],
                                                                                                        ],
                                                                                                      ],
                                                                                                    ],
                                                                                                  ],
                                                                                                ],
                                                                                              ],
                                                                                            ],
                                                                                          ],
                                                                                        ],
                                                                                      ],
                                                                                    ],
                                                                                  ],
                                                                                ],
                                                                              ],
                                                                            ],
                                                                          ],
                                                                        ],
                                                                      ],
                                                                    ],
                                                                  ],
                                                                ],
                                                              ],
                                                            ],
                                                          ],
                                                        ],
                                                      ],
                                                    ],
                                                  ],
                                                ],
                                              ],
                                            ],
                                          ],
                                        ],
                                      ],
                                    ],
                                  ],
                                ],
                              ],
                            ],
                          ],
                        ],
                      ],
                    ],
                  ],
                ],
              ],
            ],
          ],
        ],
      ],
    ],
  ],
];
