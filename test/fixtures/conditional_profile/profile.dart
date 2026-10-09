export 'stub.dart'
    if (dart.library.io) 'stub.dart'
    if (dart.library.io == 'false') 'stub.dart'
    if (dart.library.ffi) 'stub.dart'
    if (dart.library.ffi == 'false') 'stub.dart'
    if (dart.library.html) 'stub.dart'
    if (dart.library.js) 'stub.dart'
    if (dart.library.js_interop) 'web.dart';
