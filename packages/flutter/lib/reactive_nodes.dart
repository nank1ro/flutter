// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// A collapsed node model in which one retained object plays the part of both
/// a widget and an element.
///
/// To use, import `package:flutter/reactive_nodes.dart`.
///
/// This is the Phase 5 spike of the fork's plan: option (b) of section 4 of
/// `docs/fine_grained_reactivity/PLAN.md`. A [Component] runs exactly once and
/// returns a tree of [RNode]s. Properties are `T Function()` bindings — a
/// callable [Signal] satisfies one directly — applied by one effect each
/// straight to a [RenderObject] setter. Children are created, not diffed; only
/// [RShow] and [RFor] change structure. There is no `build()`, no key, and no
/// widget allocated per update.
///
/// ```dart
/// final Signal<Color> color = Signal<Color>(const Color(0xFF2196F3));
/// final RNode root = RComponent(() => RStack(
///   children: <RNode>[
///     RPositioned(left: 0, top: 0, width: 40, height: 40, child: RBox(color: color.call)),
///   ],
/// ));
/// // In a widget tree: NodeHost(node: root)
/// ```
///
/// The numbers this spike produced, and what they mean for whether Phase 5
/// should happen at all, are in
/// `docs/fine_grained_reactivity/PHASE5_DECISION.md`.
library reactive_nodes;

export 'src/reactive_nodes/node_host.dart';
export 'src/reactive_nodes/nodes.dart';
