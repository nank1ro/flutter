// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// The reactive graph in this file is a dependency-free port of alien_signals
// 2.3.1 (https://pub.dev/packages/alien_signals), by Seven Du, used under the
// MIT license:
//
//   Copyright (c) 2024-present Seven Du
//
//   Permission is hereby granted, free of charge, to any person obtaining a
//   copy of this software and associated documentation files (the "Software"),
//   to deal in the Software without restriction, including without limitation
//   the rights to use, copy, modify, merge, publish, distribute, sublicense,
//   and/or sell copies of the Software, and to permit persons to whom the
//   Software is furnished to do so, subject to the following conditions:
//
//   The above copyright notice and this permission notice shall be included in
//   all copies or substantial portions of the Software.
//
//   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
//   THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//   LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//   FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//   DEALINGS IN THE SOFTWARE.
//
// The graph algorithms ([_propagate], [_checkDirty], [_shallowPropagate],
// [_link], [_unlink]) are kept structurally identical to the original, because
// their exact shape is what makes updates glitch-free and allocation-free in
// steady state. The public API on top of them is this fork's own.

/// Fine-grained reactivity primitives.
///
/// A [Signal] is a mutable value. A [Computed] derives a value from other
/// reactive values. An [Effect] runs a callback whenever anything it read
/// changes. [Owner] scopes the lifetime of effects and computeds, [batch]
/// groups writes, and [untracked] suppresses dependency tracking.
///
/// Reads are always immediately consistent: reading a [Signal] or a [Computed]
/// returns a value that reflects every write made so far. Effects, by
/// contrast, are queued and drained by [flushSignals]. By default the queue is
/// drained synchronously at the end of the outermost write or [batch]; when
/// [signalFlushScheduler] is set, draining is left to whoever installed it
/// (in the framework, the scheduler binding, once per frame).
library;

import 'assertions.dart';

/// Bit flags describing the state of a [ReactiveNode].
///
/// These are combined with bitwise operators. Several hot paths test more than
/// one flag at a time with a single mask, so the numeric values matter.
abstract final class _Flags {
  /// The default state: no flags set.
  static const int none = 0;

  /// The node holds a value other nodes can read: a signal or a computed.
  ///
  /// Propagation continues through mutable nodes and stops at the others.
  static const int mutable = 1;

  /// The node wants to be notified when a dependency changes.
  ///
  /// Set on effects and tracking nodes while they are armed. Cleared when the
  /// node is queued, so it is queued at most once per flush.
  static const int watching = 2;

  /// The node is currently running with dependency tracking enabled.
  ///
  /// This is the cycle guard: a write to a signal the running node reads is
  /// recorded, but does not re-enter the node.
  static const int recursedCheck = 4;

  /// The node was reached again while it was already running.
  static const int recursed = 8;

  /// The node's value is known to be out of date.
  static const int dirty = 16;

  /// Something upstream of the node changed, but it is not yet known whether
  /// the node's own value changed.
  ///
  /// Resolved by [_checkDirty], which pulls the upstream values.
  static const int pending = 32;

  /// The node created effects or owners that are disposed when it re-runs.
  static const int hasChildEffect = 64;
}

/// One edge of the reactive graph, from a dependency to a subscriber.
///
/// Every link belongs to two doubly-linked lists at once: the dependency list
/// of [sub] (via [prevDep] and [nextDep]) and the subscriber list of [dep]
/// (via [prevSub] and [nextSub]). Links are reused across re-runs, which is
/// what makes a signal that is written every frame allocation-free.
final class Link {
  /// Creates an edge from [dep] to [sub].
  Link({
    required this.version,
    required this.dep,
    required this.sub,
    this.prevSub,
    this.nextSub,
    this.prevDep,
    this.nextDep,
  });

  /// The run of [sub] during which this edge was last used.
  ///
  /// Edges whose version is stale after a run are removed by [_purgeDeps].
  int version;

  /// The node being read.
  final ReactiveNode dep;

  /// The node that read [dep].
  final ReactiveNode sub;

  /// The previous edge in [dep]'s subscriber list.
  Link? prevSub;

  /// The next edge in [dep]'s subscriber list.
  Link? nextSub;

  /// The previous edge in [sub]'s dependency list.
  Link? prevDep;

  /// The next edge in [sub]'s dependency list.
  Link? nextDep;
}

/// An explicit stack, used by the graph walks so that a deep graph cannot
/// overflow the Dart call stack.
final class _Stack<T> {
  _Stack({required this.value, this.prev});

  final T value;
  final _Stack<T>? prev;
}

/// A node in the reactive graph.
///
/// Every reactive object is a node: [Signal], [Computed], [Effect], [Owner]
/// and [TrackingNode]. A node keeps a doubly-linked list of the nodes it reads
/// ([deps]) and a doubly-linked list of the nodes that read it ([subs]).
///
/// The lists are exposed because the framework and the tests inspect them.
/// They must not be mutated from outside this library.
class ReactiveNode {
  /// Creates a node in the given state.
  ReactiveNode({required this.flags});

  /// The node's state, as a combination of [_Flags] values.
  int flags;

  /// The first edge to a node this node reads.
  Link? deps;

  /// The last edge to a node this node reads.
  Link? depsTail;

  /// The first edge to a node that reads this node.
  Link? subs;

  /// The last edge to a node that reads this node.
  Link? subsTail;

  /// Head of the intrusive list of computeds created while this node was the
  /// ownership scope. They are disposed with this node, and when it re-runs.
  ///
  /// Ownership of a [Computed] cannot use a graph edge the way it does for
  /// effects and owners, because an edge from a computed to a scope is exactly
  /// what reading that computed inside the scope already produces, and the two
  /// would be indistinguishable.
  Computed<Object?>? _ownedComputeds;

  /// Whether this node has been removed from the graph for good.
  ///
  /// A disposed node is never linked to again, never invalidated, and never
  /// re-armed. This is a separate field rather than a [_Flags] bit because the
  /// ported graph algorithms test flag masks against [_Flags.none], and an
  /// extra bit would change what those tests mean.
  bool _disposed = false;

  /// Recomputes this node's value, returning whether it changed.
  ///
  /// The default implementation does nothing and reports no change.
  bool _update() => false;

  /// Called when the last subscriber of this node goes away.
  ///
  /// The default implementation, used by signals, does nothing.
  void _unwatched() {}
}

/// A node that reads reactive values and is told when they change.
///
/// Subscribers are queued when a dependency changes and drained by
/// [flushSignals], which calls [onInvalidate] on each one whose dependencies
/// really did change. [Effect] re-runs itself; [TrackingNode] calls out to the
/// framework.
abstract base class Subscriber extends ReactiveNode {
  /// Creates a subscriber in the given state.
  Subscriber({required super.flags});

  /// The version of the run this node is in, or 0 before its first run.
  ///
  /// A full run takes a fresh version from [_cycle]; a retaining run keeps the
  /// one it already has, so that the several calls that make up one logical
  /// run agree on it.
  int _runVersion = 0;

  /// The object this node was created for, for debug messages only.
  ///
  /// The framework sets this to the [Element] whose build the node tracks, so
  /// that a debug check can tell which element a subscriber belongs to. Null
  /// for a node that belongs to no such object, such as a plain [Effect].
  Object? debugOwner;

  /// The next subscriber in the pending queue.
  ///
  /// The queue is intrusive: queueing a subscriber writes one field on an
  /// object that already exists, and allocates nothing.
  Subscriber? _nextQueued;

  /// Whether this subscriber is waiting in the queue [flushSignals] drains.
  ///
  /// Because the queue is intrusive, a node that is already in it must never
  /// be queued again: the second [_notify] would overwrite [_nextQueued] and
  /// drop everything queued behind it. Queueing clears [_Flags.watching],
  /// which is what normally prevents that, so anything that re-arms a node
  /// outside a flush — [rerun] — has to check this first.
  bool _queued = false;

  /// The owner scope this subscriber was created in.
  ///
  /// Restored on every run, so that [Owner.current] reads the same on a re-run
  /// as it did on the first one.
  final Owner? _owner = _currentOwner;

  /// Called when one of this node's dependencies changed.
  ///
  /// Only called from [flushSignals], and only after the change has been
  /// confirmed to reach this node, so a subscriber behind an unchanged
  /// [Computed] is not invalidated.
  void onInvalidate();

  /// Runs [body] with this node as the active subscriber, so that every
  /// reactive value read by [body] becomes a dependency of this node.
  ///
  /// Dependencies that were read by the previous call and not by this one are
  /// removed, so a subscriber only observes what it currently reads.
  ///
  /// When [retainDeps] is true the previous dependencies are kept and the ones
  /// read by [body] are appended to them, and the effects and computeds
  /// created by earlier runs are left alone. This is for a subscriber whose
  /// tracked work arrives in several separate calls that together make up one
  /// logical run, such as a lazy sliver building one child at a time during
  /// layout. Such a subscriber has to clear its dependencies itself, by
  /// tracking an empty body, when the run starts over. The calls of such a run
  /// share one version, so that reading the same signal from several of them
  /// reuses one edge instead of appending one per call.
  ///
  /// Tracking through a disposed subscriber is a mistake, and asserts. In
  /// release builds [body] still runs, but untracked, so a disposed node is
  /// never brought back to life.
  T track<T>(T Function() body, {bool retainDeps = false}) {
    assert(!_disposed, 'Cannot track through a disposed $runtimeType.');
    if (_disposed) {
      return untracked(body);
    }
    if (!retainDeps) {
      if ((flags & _Flags.hasChildEffect) != _Flags.none) {
        _disposeChildDepsInReverse(this);
      }
      _disposeOwnedComputeds(this);
      depsTail = null;
    }
    flags = _Flags.watching | _Flags.recursedCheck;
    final ReactiveNode? prevSub = _activeSub;
    final ReactiveNode? prevScope = _currentScope;
    final Owner? prevOwner = _currentOwner;
    final int prevVersion = _version;
    if (!retainDeps || _runVersion == 0) {
      _cycle += 1;
      _runVersion = _cycle;
    }
    _version = _runVersion;
    _activeSub = this;
    _currentScope = this;
    _currentOwner = _owner;
    try {
      _runDepth += 1;
      return body();
    } finally {
      _runDepth -= 1;
      _activeSub = prevSub;
      _version = prevVersion;
      _currentScope = prevScope;
      _currentOwner = prevOwner;
      flags &= ~_Flags.recursedCheck;
      if (!retainDeps) {
        _purgeDeps(this);
      }
    }
  }

  /// Invalidates this subscriber now, as if a dependency of it had changed.
  ///
  /// This is for a caller that changed something the graph cannot see — the
  /// closure an [Effect] runs, say — and needs the subscriber to run again
  /// with the new inputs.
  ///
  /// A subscriber that is already queued is left alone: [flushSignals] is
  /// about to run it anyway, and re-arming a node that is still in the queue
  /// would let a later write queue it twice, which drops every subscriber
  /// queued behind it. A disposed subscriber is ignored. Calling this from
  /// inside the subscriber's own run is a mistake, and asserts.
  void rerun() {
    assert(
      (flags & _Flags.recursedCheck) == _Flags.none,
      'Cannot re-run a $runtimeType from inside its own run.',
    );
    if (_disposed || _queued) {
      return;
    }
    onInvalidate();
  }

  /// Removes this node from the graph, along with anything it owns.
  ///
  /// After disposal the node is never invalidated again, and [track] no longer
  /// subscribes it to anything.
  void dispose() {
    _stop(this);
  }

  @override
  void _unwatched() {
    _stop(this);
  }
}

// ---------------------------------------------------------------------------
// Graph state.
// ---------------------------------------------------------------------------

/// Incremented on every full tracked run, so that edges established by earlier
/// runs can be told apart from edges established by the current one.
int _cycle = 0;

/// The version of the run the active subscriber is currently in.
///
/// Saved and restored alongside [_activeSub], so that a nested run does not
/// renumber the run it interrupted. A retaining run keeps the version it
/// started with across all of its calls, which is what lets [_link] recognise
/// a second read of the same dependency by the same subscriber and reuse the
/// edge instead of appending another one. See [Subscriber.track].
int _version = 0;

/// How deep we are inside effect callbacks. Writes made from inside an effect
/// propagate as inner writes.
int _runDepth = 0;

/// How deep we are inside [batch]. While greater than zero, the effect queue
/// is not drained.
int _batchDepth = 0;

/// The node that reads are currently attributed to, if any.
///
/// This is only about *tracking*: a read while this is set subscribes that
/// node. It is deliberately separate from [_currentScope], because the two
/// answer different questions and do not always agree. Inside [Owner.run] and
/// inside [untracked] there is an ownership scope but no tracking subscriber.
ReactiveNode? _activeSub;

/// The node that owns nodes created right now, if any.
///
/// This is about *lifetime*: an effect, tracking node, nested owner or
/// computed created while this is set is disposed with it. Set by [Owner.run]
/// and for the duration of every effect and computed run, and left alone by
/// [untracked], so that an effect created inside [untracked] is still owned by
/// the enclosing scope.
ReactiveNode? _currentScope;

/// The innermost [Owner] scope, if any.
///
/// A subset of [_currentScope]: effects and computeds are scopes too, but they
/// are not [Owner]s, so they restore the owner they were created under instead.
Owner? _currentOwner;

/// Head of the queue of subscribers waiting to be invalidated.
Subscriber? _queueHead;

/// Tail of the queue of subscribers waiting to be invalidated.
Subscriber? _queueTail;

/// Called when subscribers become pending and the effect queue needs draining.
///
/// When null (the default, and the case in plain Dart programs and unit
/// tests), the queue is drained synchronously at the end of the outermost
/// write or [batch], so effects observe writes immediately.
///
/// When set, draining is that callback's responsibility: it is invoked instead
/// of the synchronous drain and must eventually call [flushSignals]. The
/// framework installs a callback that schedules a frame and drains just before
/// the build phase, so that effects and the build pipeline agree on ordering.
/// This is deliberately a plain hook rather than an import of the scheduler:
/// `foundation` must not depend on `scheduler`.
void Function()? signalFlushScheduler;

/// Debug-only hook called before a [Signal] write is propagated, with the
/// signal being written.
///
/// Invoked from inside an `assert`, so it costs nothing in release builds, and
/// only when the write actually changes the value. It reports a problem by
/// throwing, and must otherwise return true.
///
/// The framework installs a callback that throws when a signal is written by
/// the build method of a widget and read by something that build cannot
/// invalidate, which is the signal-graph analogue of calling `setState` during
/// build. It walks the signal's [ReactiveNode.subs] to decide, which is why it
/// is handed the node. Writes made during layout and paint are left alone:
/// they are queued and picked up by the next frame.
bool Function(ReactiveNode signal)? debugAssertSignalWriteAllowed;

/// Debug-only hook called when a [Signal] or [Computed] value is read with no
/// tracking scope active, and not inside [untracked] or [Owner.run].
///
/// Invoked from inside an `assert`, so it costs nothing in release builds. It
/// must return true; it reports by other means.
///
/// Such a read is silently not tracked, so whatever depends on it is never
/// told when the value changes. That is correct in an event handler, and
/// almost always a bug in a callback that runs as part of a frame — a
/// [CustomPainter.paint], a `createRenderObject`, a builder invoked from a
/// [RenderObject] that has no tracking of its own. The framework installs a
/// callback that reports those, and only those.
bool Function()? debugSignalReadOutsideTracking;

/// Whether tracking is suppressed on purpose, by [untracked] or [Owner.run].
///
/// Only maintained when asserts are enabled; only read by the assert that
/// calls [debugSignalReadOutsideTracking].
bool _debugInUntracked = false;

/// Whether [flushSignals] is currently draining the queue.
///
/// Writes made by effects append to the queue the running drain is already
/// walking, so they must not start a second one.
bool _flushing = false;

// ---------------------------------------------------------------------------
// Graph algorithms, ported from alien_signals.
// ---------------------------------------------------------------------------

/// Records that [sub] read [dep] during the run identified by [version].
///
/// Reuses the edge left over from the previous run when the dependency order
/// is unchanged, which is the common case and allocates nothing.
void _link(ReactiveNode dep, ReactiveNode sub, int version) {
  if (sub._disposed) {
    // A node that disposed itself part way through its own run must not pick
    // up new dependencies from the rest of that run.
    return;
  }
  final Link? prevDep = sub.depsTail;
  if (prevDep != null && identical(prevDep.dep, dep)) {
    return;
  }
  final Link? nextDep = prevDep != null ? prevDep.nextDep : sub.deps;
  if (nextDep != null && identical(nextDep.dep, dep)) {
    nextDep.version = version;
    sub.depsTail = nextDep;
    return;
  }
  final Link? prevSub = dep.subsTail;
  if (prevSub != null && prevSub.version == version && identical(prevSub.sub, sub)) {
    return;
  }
  final newLink = Link(
    version: version,
    dep: dep,
    sub: sub,
    prevDep: prevDep,
    nextDep: nextDep,
    prevSub: prevSub,
  );
  sub.depsTail = newLink;
  dep.subsTail = newLink;
  if (nextDep != null) {
    nextDep.prevDep = newLink;
  }
  if (prevDep != null) {
    prevDep.nextDep = newLink;
  } else {
    sub.deps = newLink;
  }
  if (prevSub != null) {
    prevSub.nextSub = newLink;
  } else {
    dep.subs = newLink;
  }
}

/// Removes [link] from both lists it belongs to.
///
/// Returns the next dependency of [sub], so callers can walk and unlink in one
/// pass. Notifies the dependency when it loses its last subscriber.
Link? _unlink(Link link, ReactiveNode sub) {
  final ReactiveNode dep = link.dep;
  final Link? prevDep = link.prevDep;
  final Link? nextDep = link.nextDep;
  final Link? nextSub = link.nextSub;
  final Link? prevSub = link.prevSub;
  if (nextDep != null) {
    nextDep.prevDep = prevDep;
  } else {
    sub.depsTail = prevDep;
  }
  if (prevDep != null) {
    prevDep.nextDep = nextDep;
  } else {
    sub.deps = nextDep;
  }
  if (nextSub != null) {
    nextSub.prevSub = prevSub;
  } else {
    dep.subsTail = prevSub;
  }
  if (prevSub != null) {
    prevSub.nextSub = nextSub;
  } else if ((dep.subs = nextSub) == null) {
    dep._unwatched();
  }
  return nextDep;
}

/// Marks everything downstream of [link] as pending, and queues the watchers.
///
/// This is the push half of the algorithm. It only marks; no value is
/// recomputed here, which is what keeps a write cheap and glitch-free. Whether
/// a pending node actually changed is decided later, by [_checkDirty].
@pragma('vm:align-loops')
void _propagate(Link link, [bool innerWrite = false]) {
  Link? next = link.nextSub;
  _Stack<Link?>? stack;

  top:
  for (;;) {
    final ReactiveNode sub = link.sub;
    int flags = sub.flags;

    if ((flags & (_Flags.recursedCheck | _Flags.recursed | _Flags.dirty | _Flags.pending)) ==
        _Flags.none) {
      sub.flags = flags | _Flags.pending;
      if (innerWrite) {
        sub.flags |= _Flags.recursed;
      }
    } else if ((flags & (_Flags.recursedCheck | _Flags.recursed)) == _Flags.none) {
      flags = _Flags.none;
    } else if ((flags & _Flags.recursedCheck) == _Flags.none) {
      sub.flags = (flags & ~_Flags.recursed) | _Flags.pending;
    } else if ((flags & (_Flags.dirty | _Flags.pending)) == _Flags.none &&
        _isValidLink(link, sub)) {
      sub.flags = flags | (_Flags.recursed | _Flags.pending);
      flags &= _Flags.mutable;
    } else {
      flags = _Flags.none;
    }

    if ((flags & _Flags.watching) != _Flags.none) {
      _notify(sub as Subscriber);
    }

    if ((flags & _Flags.mutable) != _Flags.none) {
      final Link? subSubs = sub.subs;
      if (subSubs != null) {
        link = subSubs;
        final Link? nextSub = link.nextSub;
        if (nextSub != null) {
          stack = _Stack<Link?>(value: next, prev: stack);
          next = nextSub;
        }
        continue;
      }
    }

    if (next != null) {
      link = next;
      next = link.nextSub;
      continue;
    }

    while (stack != null) {
      final Link? value = stack.value;
      stack = stack.prev;
      if (value != null) {
        link = value;
        next = link.nextSub;
        continue top;
      }
    }

    break;
  }
}

/// Upgrades the direct subscribers of a node from pending to dirty, once that
/// node's value has been confirmed to have changed.
@pragma('vm:align-loops')
void _shallowPropagate(Link link) {
  Link? curr = link;
  do {
    final ReactiveNode sub = curr!.sub;
    final int flags = sub.flags;
    if ((flags & (_Flags.pending | _Flags.dirty)) == _Flags.pending) {
      sub.flags = flags | _Flags.dirty;
      if ((flags & (_Flags.watching | _Flags.recursedCheck)) == _Flags.watching) {
        _notify(sub as Subscriber);
      }
    }
  } while ((curr = curr.nextSub) != null);
}

/// Decides whether [sub] really needs to update, by pulling the values of the
/// dependencies that were marked pending.
///
/// This is the pull half of the algorithm, and the reason a diamond dependency
/// produces exactly one downstream run: an intermediate computed that recomputes
/// to an unchanged value stops the update here.
@pragma('vm:align-loops')
bool _checkDirty(Link link, ReactiveNode sub) {
  _Stack<Link>? stack;
  var checkDepth = 0;
  var dirty = false;

  top:
  for (;;) {
    final ReactiveNode dep = link.dep;
    final int flags = dep.flags;

    if ((sub.flags & _Flags.dirty) != _Flags.none) {
      dirty = true;
    } else if ((flags & (_Flags.mutable | _Flags.dirty)) == (_Flags.mutable | _Flags.dirty)) {
      final Link? subs = dep.subs;
      if (dep._update()) {
        if (subs!.nextSub != null) {
          _shallowPropagate(subs);
        }
        dirty = true;
      }
    } else if ((flags & (_Flags.mutable | _Flags.pending)) == (_Flags.mutable | _Flags.pending)) {
      stack = _Stack<Link>(value: link, prev: stack);
      link = dep.deps!;
      sub = dep;
      checkDepth += 1;
      continue;
    }

    if (!dirty) {
      final Link? nextDep = link.nextDep;
      if (nextDep != null) {
        link = nextDep;
        continue;
      }
    }

    while ((checkDepth--) > 0) {
      link = stack!.value;
      stack = stack.prev;
      if (dirty) {
        final Link? subs = sub.subs;
        if (sub._update()) {
          if (subs!.nextSub != null) {
            _shallowPropagate(subs);
          }
          sub = link.sub;
          continue;
        }
        dirty = false;
      } else {
        sub.flags &= ~_Flags.pending;
      }
      sub = link.sub;
      final Link? nextDep = link.nextDep;
      if (nextDep != null) {
        link = nextDep;
        continue top;
      }
    }

    return dirty && sub.flags != _Flags.none;
  }
}

/// Whether [checkLink] is still one of [sub]'s dependencies.
@pragma('vm:align-loops')
bool _isValidLink(Link checkLink, ReactiveNode sub) {
  Link? link = sub.depsTail;
  while (link != null) {
    if (identical(link, checkLink)) {
      return true;
    }
    link = link.prevDep;
  }
  return false;
}

/// Queues [node], and its watching ancestors, for invalidation.
///
/// The ancestors are queued ahead of the node so that a parent effect, which
/// may re-create the node, runs first. Queueing clears [_Flags.watching], so a
/// node is queued at most once per flush.
@pragma('vm:align-loops')
void _notify(Subscriber node) {
  Subscriber? head;
  final tail = node;
  var current = node;

  for (;;) {
    current._nextQueued = head;
    current._queued = true;
    head = current;
    current.flags &= ~_Flags.watching;

    final ReactiveNode? next = current.subs?.sub;
    if (next == null || (next.flags & _Flags.watching) == _Flags.none) {
      break;
    }
    current = next as Subscriber;
  }

  if (_queueTail == null) {
    _queueHead = head;
  } else {
    _queueTail!._nextQueued = head;
  }
  _queueTail = tail;
}

/// Removes the child effects and owners of [sub], newest first, leaving its
/// signal and computed dependencies for [_purgeDeps].
void _disposeChildDepsInReverse(ReactiveNode sub) {
  Link? link = sub.depsTail;
  while (link != null) {
    final Link? prev = link.prevDep;
    final ReactiveNode dep = link.dep;
    if (dep is! Computed<Object?> && dep is! Signal<Object?>) {
      _unlink(link, sub);
    }
    link = prev;
  }
}

/// Removes every dependency of [sub], newest first.
void _disposeAllDepsInReverse(ReactiveNode sub) {
  Link? link = sub.depsTail;
  while (link != null) {
    final Link? prev = link.prevDep;
    _unlink(link, sub);
    link = prev;
  }
}

/// Removes the dependencies of [sub] that were not read by its latest run.
@pragma('vm:align-loops')
void _purgeDeps(ReactiveNode sub) {
  final Link? depsTail = sub.depsTail;
  Link? dep = depsTail != null ? depsTail.nextDep : sub.deps;
  while (dep != null) {
    dep = _unlink(dep, sub);
  }
}

/// Disposes the computeds created while [node] was the ownership scope.
void _disposeOwnedComputeds(ReactiveNode node) {
  Computed<Object?>? owned = node._ownedComputeds;
  if (owned == null) {
    return;
  }
  node._ownedComputeds = null;
  while (owned != null) {
    final Computed<Object?>? next = owned._nextOwnedComputed;
    owned._nextOwnedComputed = null;
    owned.dispose();
    owned = next;
  }
}

/// Detaches [node] from the graph and disposes everything it owns.
void _stop(ReactiveNode node) {
  node._disposed = true;
  node.flags = _Flags.none;
  _disposeOwnedComputeds(node);
  _disposeAllDepsInReverse(node);
  final Link? subs = node.subs;
  if (subs != null) {
    assert(
      subs.nextSub == null,
      'A node stopped this way has at most one subscriber, the scope that owns '
      'it. Only effects, tracking nodes and owners are stopped this way, and '
      'none of them is ever read as a value, so nothing else can subscribe.',
    );
    _unlink(subs, subs.sub);
  }
  // A node that disposed itself part way through its own run must stop being
  // the target for the reads and the nodes created by the rest of that run.
  if (identical(_activeSub, node)) {
    _activeSub = null;
  }
  if (identical(_currentScope, node)) {
    _currentScope = null;
  }
}

/// Reports an exception thrown by user code running under the signal graph.
///
/// Effects are drained as a batch, so one failing effect must not take the
/// others down with it: the error is reported the way the framework reports
/// any other uncaught error, and the drain continues.
void _reportSignalError(Object exception, StackTrace stack) {
  FlutterError.reportError(
    FlutterErrorDetails(
      exception: exception,
      stack: stack,
      library: 'foundation library',
      context: ErrorDescription('while running a signal effect'),
    ),
  );
}

/// Drains the queue if there is anything in it, or hands that job to
/// [signalFlushScheduler].
void _flushOrSchedule() {
  if (_queueHead == null || _flushing) {
    // While flushing, whatever was just queued is appended to the queue the
    // running drain is already walking, so there is nothing to start.
    return;
  }
  final void Function()? scheduler = signalFlushScheduler;
  if (scheduler == null) {
    flushSignals();
  } else {
    // Called on every write that leaves something queued, rather than once per
    // queue. The scheduler is `ensureVisualUpdate`, which is idempotent and
    // cheap, and a latch here would stick shut for good the first time a
    // scheduler declined to schedule a frame.
    scheduler();
  }
}

// ---------------------------------------------------------------------------
// Public API.
// ---------------------------------------------------------------------------

/// A reactive value that can be read: a [Signal], a [Computed], or a fixed
/// value.
///
/// This is the type a widget property declares when it can follow a reactive
/// value. A plain value is passed as a const [ReadonlySignal.fixed], which
/// reads naturally through a dot shorthand and keeps the enclosing widget
/// `const`:
///
/// ```dart
/// final Signal<double> fade = Signal<double>(1);
/// final Computed<double> half = Computed<double>(() => fade.value / 2);
///
/// const ReadonlySignal<double> fixed = .fixed(0.5);
/// final ReadonlySignal<double> bound = fade;
/// final ReadonlySignal<double> derived = half;
/// ```
abstract interface class ReadonlySignal<T> {
  /// A value that never changes, and so is never subscribed to.
  const factory ReadonlySignal.fixed(T value) = FixedSignal<T>;

  /// The current value, subscribing the enclosing tracked scope.
  T get value;

  /// The current value, without subscribing.
  T get peek;

  /// Identical to reading [value].
  T call();
}

/// A [ReadonlySignal] whose value never changes.
///
/// It is not part of the reactive graph: reading it subscribes nothing, so a
/// consumer that sees one can skip setting up a subscription altogether.
/// Usually written as `.fixed(value)` where a [ReadonlySignal] is expected.
final class FixedSignal<T> implements ReadonlySignal<T> {
  /// Creates a fixed value.
  const FixedSignal(this.value);

  @override
  final T value;

  @override
  T get peek => value;

  @override
  T call() => value;
}

/// A mutable reactive value.
///
/// Reading [value] inside a tracked scope, such as an [Effect] callback or a
/// [Computed], subscribes that scope to this signal. Writing [value] marks the
/// dependents dirty and queues the affected effects.
///
/// Values are compared with `==`: writing a value equal to the current one is
/// not a change and propagates nothing, even if the two are different objects.
/// Most Flutter values, such as [String], `Offset` and `Color`, are value
/// types whose identity is not meaningful, so comparing by identity would
/// re-run effects for writes that changed nothing observable.
///
/// ```dart
/// final Signal<int> count = Signal<int>(0);
/// Effect(() => print('count is ${count.value}'));
/// count.value += 1; // prints 'count is 1'
/// ```
final class Signal<T> extends ReactiveNode implements ReadonlySignal<T> {
  /// Creates a signal holding [initialValue].
  Signal(T initialValue)
    : _currentValue = initialValue,
      _pendingValue = initialValue,
      super(flags: _Flags.mutable);

  T _currentValue;
  T _pendingValue;

  /// The current value, subscribing the enclosing tracked scope if there is
  /// one.
  @override
  T get value {
    if ((flags & _Flags.dirty) != _Flags.none) {
      if (_update()) {
        final Link? subs = this.subs;
        if (subs != null) {
          _shallowPropagate(subs);
        }
      }
    }
    final ReactiveNode? sub = _activeSub;
    if (sub != null) {
      _link(this, sub, _version);
    } else {
      assert(_debugInUntracked || (debugSignalReadOutsideTracking?.call() ?? true));
    }
    return _currentValue;
  }

  set value(T newValue) {
    if (_pendingValue == newValue) {
      return;
    }
    assert(debugAssertSignalWriteAllowed?.call(this) ?? true);
    _pendingValue = newValue;
    flags = _Flags.mutable | _Flags.dirty;
    final Link? subs = this.subs;
    if (subs != null) {
      _propagate(subs, _runDepth > 0);
      if (_batchDepth == 0) {
        _flushOrSchedule();
      }
    }
  }

  /// The current value, without subscribing.
  @override
  T get peek {
    if ((flags & _Flags.dirty) != _Flags.none) {
      if (_update()) {
        final Link? subs = this.subs;
        if (subs != null) {
          _shallowPropagate(subs);
        }
      }
    }
    return _currentValue;
  }

  /// The current value, subscribing the enclosing tracked scope.
  ///
  /// Identical to reading [value]. It exists so that a signal can be passed
  /// straight to anything that expects a reactive property of type
  /// `T Function()`, instead of `() => signal.value`.
  @override
  T call() => value;

  @override
  bool _update() {
    flags = _Flags.mutable;
    final T previous = _currentValue;
    _currentValue = _pendingValue;
    return previous != _currentValue;
  }
}

/// A reactive value derived from other reactive values.
///
/// The computation is lazy: it does not run until the value is read, and it
/// does not re-run while nothing reads it. It is also cached: it only re-runs
/// when something it read actually changed.
///
/// The callback receives the previous value, or null on the first run, which
/// makes incremental computations possible.
///
/// Results are compared with `==`, like [Signal.value]: a recomputation that
/// produces a value equal to the previous one propagates nothing, so an effect
/// behind it does not re-run.
///
/// A computed created inside an [Owner] or an [Effect] is disposed with it.
/// One created outside any scope, and reading a signal that outlives it, must
/// be released with [dispose].
///
/// If the computation throws, the exception propagates to the reader and the
/// value is left dirty, so the next read tries again rather than caching a
/// half-built result.
///
/// ```dart
/// final Signal<int> count = Signal<int>(2);
/// final Computed<int> doubled = Computed<int>(() => count.value * 2);
/// print(doubled.value); // 4
/// ```
final class Computed<T> extends ReactiveNode implements ReadonlySignal<T> {
  /// Creates a computed value from [compute].
  Computed(T Function() compute) : this.withPrevious((T? previous) => compute());

  /// Creates a computed value from [compute], which is passed the value it
  /// returned last time, or null on the first run.
  ///
  /// This is for a value that accumulates, such as a running maximum:
  ///
  /// ```dart
  /// final Signal<int> level = Signal<int>(0);
  /// final Computed<int> peak = Computed<int>.withPrevious(
  ///   (int? previous) => math.max(previous ?? 0, level.value),
  /// );
  /// ```
  Computed.withPrevious(T Function(T? previous) compute)
    : _compute = compute,
      super(flags: _Flags.none) {
    final ReactiveNode? scope = _currentScope;
    if (scope != null) {
      _nextOwnedComputed = scope._ownedComputeds;
      scope._ownedComputeds = this;
    }
  }

  final T Function(T? previous) _compute;
  T? _currentValue;

  /// The owner scope active when this computed was created, restored on every
  /// recomputation so [Owner.current] is stable across runs.
  final Owner? _owner = _currentOwner;

  /// The next computed owned by the same scope. See [_ownedComputeds].
  Computed<Object?>? _nextOwnedComputed;

  /// The current value, recomputing first if a dependency changed, and
  /// subscribing the enclosing tracked scope if there is one.
  @override
  T get value {
    final T result = _evaluate();
    final ReactiveNode? sub = _activeSub;
    if (sub != null) {
      if (!_disposed) {
        _link(this, sub, _version);
      }
    } else {
      assert(_debugInUntracked || (debugSignalReadOutsideTracking?.call() ?? true));
    }
    return result;
  }

  /// The current value, without subscribing.
  @override
  T get peek => _evaluate();

  /// The current value, subscribing the enclosing tracked scope.
  ///
  /// Identical to reading [value]; see [Signal.call].
  @override
  T call() => value;

  T _evaluate() {
    if (_disposed) {
      // A disposed computed has no dependencies left and is never invalidated
      // again, so its cached value can be arbitrarily stale. A read still has
      // to answer with the current value, so recompute on the spot: untracked,
      // unlinked and uncached. Correct, but no longer incremental, which is
      // the price of reading a computed whose scope is gone.
      return untracked(() => _compute(_currentValue));
    }
    final int flags = this.flags;
    var needsUpdate = (flags & _Flags.dirty) != _Flags.none;
    if (!needsUpdate && (flags & _Flags.pending) != _Flags.none) {
      if (_checkDirty(deps!, this)) {
        needsUpdate = true;
      } else {
        this.flags = flags & ~_Flags.pending;
      }
    }
    if (needsUpdate) {
      if (_update()) {
        final Link? subs = this.subs;
        if (subs != null) {
          _shallowPropagate(subs);
        }
      }
    } else if (flags == _Flags.none) {
      // First read of a computed that nothing has subscribed to yet.
      _update();
    }
    return _currentValue as T;
  }

  /// Removes this computed from the graph, along with anything it owns.
  ///
  /// Unsubscribes it from everything it reads and detaches it from everything
  /// that reads it, so that a computed reading a long-lived signal can be
  /// released. Called automatically when the scope that created it is
  /// disposed, or re-runs.
  ///
  /// Reading [value] afterwards still answers with the current value, by
  /// recomputing on the spot; it just no longer caches or subscribes. See
  /// [_evaluate].
  void dispose() {
    _disposed = true;
    flags = _Flags.none;
    _disposeOwnedComputeds(this);
    _disposeAllDepsInReverse(this);
    Link? link = subsTail;
    while (link != null) {
      final Link? prev = link.prevSub;
      _unlink(link, link.sub);
      link = prev;
    }
    if (identical(_activeSub, this)) {
      _activeSub = null;
    }
    if (identical(_currentScope, this)) {
      _currentScope = null;
    }
  }

  @override
  bool _update() {
    if ((flags & _Flags.hasChildEffect) != _Flags.none) {
      _disposeChildDepsInReverse(this);
    }
    _disposeOwnedComputeds(this);
    depsTail = null;
    flags = _Flags.mutable | _Flags.recursedCheck;
    final ReactiveNode? prevSub = _activeSub;
    final ReactiveNode? prevScope = _currentScope;
    final Owner? prevOwner = _currentOwner;
    final int prevVersion = _version;
    _cycle += 1;
    _version = _cycle;
    _activeSub = this;
    _currentScope = this;
    _currentOwner = _owner;
    var completed = false;
    try {
      final T? previous = _currentValue;
      _currentValue = _compute(previous);
      completed = true;
      return previous != _currentValue;
    } finally {
      _activeSub = prevSub;
      _version = prevVersion;
      _currentScope = prevScope;
      _currentOwner = prevOwner;
      flags &= ~_Flags.recursedCheck;
      _purgeDeps(this);
      if (!completed) {
        // The computation threw. Leave the node dirty, so that the next read
        // recomputes instead of handing out a value that was never produced.
        flags = _Flags.mutable | _Flags.dirty;
      }
    }
  }

  @override
  void _unwatched() {
    if (!_disposed && depsTail != null) {
      flags = _Flags.mutable | _Flags.dirty;
      _disposeAllDepsInReverse(this);
    }
  }
}

/// A callback that re-runs whenever a reactive value it read changes.
///
/// The callback runs immediately when the effect is created, which is how its
/// dependencies are discovered. It runs again when one of them changes: either
/// synchronously at the end of the write, or when [flushSignals] is called if
/// a [signalFlushScheduler] is installed.
///
/// An effect created inside an [Owner] scope, or inside another effect, is
/// disposed with it. An effect is itself a scope: effects and computeds it
/// creates are disposed when it re-runs or is disposed.
///
/// If the callback throws, the exception is reported through
/// [FlutterError.reportError] rather than propagating, so that one failing
/// effect does not strand the others waiting behind it in the queue. The
/// constructor therefore always returns an effect that can be disposed, even
/// if its first run failed.
///
/// ```dart
/// final Effect effect = Effect(() => print(count.value));
/// effect.dispose();
/// ```
final class Effect extends Subscriber {
  /// Creates an effect and runs [run] immediately.
  Effect(this._run) : super(flags: _Flags.watching | _Flags.recursedCheck) {
    final ReactiveNode? scope = _currentScope;
    if (scope != null) {
      _link(this, scope, 0);
      scope.flags |= _Flags.hasChildEffect;
    }
    final ReactiveNode? prevSub = _activeSub;
    _activeSub = this;
    _currentScope = this;
    try {
      _runDepth += 1;
      _run();
    } catch (exception, stack) {
      _reportSignalError(exception, stack);
    } finally {
      _runDepth -= 1;
      _activeSub = prevSub;
      _currentScope = scope;
      flags &= ~_Flags.recursedCheck;
    }
  }

  final void Function() _run;

  @override
  void onInvalidate() {
    track<void>(_run);
  }
}

/// A subscriber that reports invalidation to a callback instead of re-running
/// something itself.
///
/// This is the seam the framework binds to: an element creates one node,
/// wraps its build in [Subscriber.track], and passes `markNeedsBuild` as
/// [onInvalidate]. The element then rebuilds through the normal build
/// pipeline, and re-tracks as a side effect of building.
///
/// Unlike an [Effect], a tracking node does not re-arm itself. It is armed
/// again by the next call to [Subscriber.track].
final class TrackingNode extends Subscriber {
  /// Creates a tracking node that calls [onInvalidate] when a value read
  /// inside [Subscriber.track] changes.
  TrackingNode(this._onInvalidate) : super(flags: _Flags.watching) {
    final ReactiveNode? scope = _currentScope;
    if (scope != null) {
      _link(this, scope, 0);
      scope.flags |= _Flags.hasChildEffect;
    }
  }

  final void Function() _onInvalidate;

  @override
  void onInvalidate() {
    _onInvalidate();
  }
}

/// A disposal scope for effects and computeds.
///
/// Effects, tracking nodes and nested owners created while the owner is active
/// are torn down when it is disposed. Owners nest: disposing an owner disposes
/// the owners created inside it.
///
/// ```dart
/// final Owner owner = Owner();
/// owner.run(() => Effect(() => print(count.value)));
/// owner.dispose(); // the effect stops
/// ```
final class Owner extends ReactiveNode {
  /// Creates an owner, attached to the enclosing scope if there is one.
  Owner() : super(flags: _Flags.mutable) {
    final ReactiveNode? scope = _currentScope;
    if (scope != null) {
      _link(this, scope, 0);
      scope.flags |= _Flags.hasChildEffect;
    }
  }

  /// Creates an owner with no parent scope, whatever scope is active.
  ///
  /// Its lifetime is the caller's to manage: nothing else disposes it. This is
  /// for an owner tied to something outside the graph, such as an [Element],
  /// which would otherwise be disposed by the first enclosing scope that
  /// happens to be running when it is created.
  Owner.detached() : super(flags: _Flags.mutable);

  /// The innermost owner scope, if any.
  ///
  /// This is the owner whose [run] is on the stack, or the owner an effect or
  /// computed was created under while that effect or computed is running. It
  /// is unaffected by [untracked].
  static Owner? get current => _currentOwner;

  /// Runs [body] with this owner as the enclosing scope, and returns its
  /// result.
  ///
  /// Effects, tracking nodes, computeds and nested owners created by [body]
  /// are disposed with this owner. Reactive values read by [body] are *not*
  /// tracked: an owner is a lifetime, not a subscriber, so reading a signal
  /// here neither subscribes the owner nor keeps the signal alive.
  R run<R>(R Function() body) {
    final Owner? prevOwner = _currentOwner;
    final ReactiveNode? prevScope = _currentScope;
    final ReactiveNode? prevSub = _activeSub;
    _currentOwner = this;
    _currentScope = this;
    _activeSub = null;
    var debugPrevInUntracked = false;
    assert(() {
      debugPrevInUntracked = _debugInUntracked;
      _debugInUntracked = true;
      return true;
    }());
    try {
      return body();
    } finally {
      _activeSub = prevSub;
      _currentScope = prevScope;
      _currentOwner = prevOwner;
      assert(() {
        _debugInUntracked = debugPrevInUntracked;
        return true;
      }());
    }
  }

  /// Disposes everything created under this owner, and the owner itself.
  void dispose() {
    _stop(this);
  }

  @override
  bool _update() {
    flags = _Flags.mutable;
    return true;
  }

  @override
  void _unwatched() {
    _stop(this);
  }
}

/// Runs [body] with effect flushing deferred until the outermost batch ends.
///
/// Writes inside a batch are still immediately visible to reads; only the
/// effects are held back, so a group of related writes triggers one run of
/// each affected effect rather than one per write.
R batch<R>(R Function() body) {
  _batchDepth += 1;
  try {
    return body();
  } finally {
    _batchDepth -= 1;
    if (_batchDepth == 0) {
      _flushOrSchedule();
    }
  }
}

/// Runs [body] without tracking anything it reads.
///
/// Reads inside [body] do not subscribe the enclosing scope, and so do not
/// cause it to re-run.
R untracked<R>(R Function() body) {
  final ReactiveNode? prevSub = _activeSub;
  _activeSub = null;
  var debugPrevInUntracked = false;
  assert(() {
    debugPrevInUntracked = _debugInUntracked;
    _debugInUntracked = true;
    return true;
  }());
  try {
    return body();
  } finally {
    _activeSub = prevSub;
    assert(() {
      _debugInUntracked = debugPrevInUntracked;
      return true;
    }());
  }
}

/// Whether any subscriber is waiting to be invalidated by [flushSignals].
///
/// The framework checks this at the end of a frame: a write made after the
/// frame's flush, during layout or paint, has to be picked up by the next
/// frame, and that frame has to be asked for.
bool get hasPendingSignalEffects => _queueHead != null;

/// Runs every queued subscriber whose dependencies actually changed.
///
/// This is synchronous. A write made by an effect appends to the queue this
/// call is already draining, and is picked up by the same loop; a nested call
/// to [flushSignals] therefore returns immediately and leaves the work to the
/// drain already in progress. It is a no-op when nothing is queued, so it is
/// cheap to call unconditionally, once per frame.
///
/// This never throws. An exception from an effect is reported through
/// [FlutterError.reportError] and the rest of the queue still runs, so a
/// single bad effect cannot silently stop every other effect in the frame.
@pragma('vm:align-loops')
void flushSignals() {
  if (_flushing) {
    return;
  }
  _flushing = true;
  try {
    while (_queueHead != null) {
      final Subscriber node = _queueHead!;
      _queueHead = node._nextQueued;
      node._nextQueued = null;
      node._queued = false;
      if (_queueHead == null) {
        _queueTail = null;
      }
      if (node._disposed) {
        continue;
      }
      try {
        final int flags = node.flags;
        if ((flags & _Flags.dirty) != _Flags.none ||
            ((flags & _Flags.pending) != _Flags.none && _checkDirty(node.deps!, node))) {
          node.onInvalidate();
        } else if (node.deps != null) {
          node.flags = _Flags.watching | (flags & _Flags.hasChildEffect);
        }
      } catch (exception, stack) {
        _reportSignalError(exception, stack);
        // Re-arm the node so a later change still reaches it, rather than
        // leaving it stranded half-notified.
        if (!node._disposed) {
          node.flags |= _Flags.watching | _Flags.recursed;
        }
      }
    }
  } finally {
    _flushing = false;
  }
}
