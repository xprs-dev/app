/*
 * A core Observable (package:xprs_core) as a Flutter ValueListenable, for
 * ValueListenableBuilder and friends. The core cannot depend on Flutter, so its
 * observable state is a plain Observable; widgets watch it through this.
 * One adapter per Observable (an Expando), so a builder sees a stable object
 * across rebuilds.
 */
import 'package:flutter/foundation.dart';
import 'package:xprs_core/src/util/observable.dart';

class _ObservableListenable<T> implements ValueListenable<T> {
  _ObservableListenable(this._o);
  final Observable<T> _o;
  @override
  T get value => _o.value;
  @override
  void addListener(VoidCallback listener) => _o.addListener(listener);
  @override
  void removeListener(VoidCallback listener) => _o.removeListener(listener);
}

final Expando<ValueListenable<Object?>> _adapters = Expando('listenable');

extension ObservableListenable<T> on Observable<T> {
  /// This observable as a Flutter [ValueListenable].
  ValueListenable<T> get listenable =>
      (_adapters[this] ??= _ObservableListenable<T>(this)) as ValueListenable<T>;
}
