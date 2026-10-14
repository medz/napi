# Binding redesign roadmap

The complete design is tracked in [#114](https://github.com/medz/napi/issues/114). This sequence is implementation order, not a reduction of that design.

1. **#115 foundation:** immutable compiler models and plans, runtime adapter contracts, executable scalar fixture. This checkout implements that bounded foundation.
2. **#108 frontend:** annotation discovery, external binding declarations, complete normalized member/default/nullability metadata and source diagnostics.
3. **#109 values:** recursive structural validation/conversion, presence, numbers, Map/dictionary semantics and accurate declarations.
4. **#112 identity/resources:** retained class identity, branding, constructors/methods/properties and resource lifecycle.
5. **#110 generics / #111 buffers:** concrete Dart versus opaque generic semantics, copying/sharing and ownership. These can develop in parallel after their prerequisites.
6. **#113 async:** Futures, callbacks, streams, scheduling, cancellation and lifetime composition.
7. **#107 packaging:** the early SDK-loader experiment runs now; production assembly and complete clean-consumer compatibility join the feature engines later. Reuse #106 package-name work.
8. **#114 conformance:** real engines composed through nested structures, generics, instances and async; migration and performance evidence.

No feature is implemented merely because an interface or test double exists. No prerequisite feature issue must close before the foundation is testable. This PR does not imply a release, npm publication or closure of #107/#108/#114. Preserve the cumulative changelog and version until a release-preparation milestone.
