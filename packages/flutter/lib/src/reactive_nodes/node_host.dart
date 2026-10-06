// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// Hosting a collapsed node tree inside the classic widget tree.
library;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'nodes.dart';

/// Shows an [RNode] tree inside an ordinary widget tree.
///
/// This is the whole of the embedding: one widget, one element, one render
/// object, however many nodes the tree has. The host's render object adopts the
/// root node's render object as its child, so layout, painting, hit testing and
/// semantics all keep working through the render tree — which is what separates
/// the collapsed model from scene mode, where all four have to be re-provided.
///
/// The node is not owned: unmounting the host un-parents the root render object
/// but does not dispose the tree. Call [RNode.dispose] when the tree is
/// finished with.
class NodeHost extends LeafRenderObjectWidget {
  /// Creates a host showing [node].
  const NodeHost({super.key, required this.node});

  /// The root of the node tree to show.
  final RNode node;

  @override
  RenderNodeHost createRenderObject(BuildContext context) {
    assert(_debugCheckNotHosted());
    return RenderNodeHost(child: node.renderObject);
  }

  @override
  void updateRenderObject(BuildContext context, RenderNodeHost renderObject) {
    if (renderObject.child != node.renderObject) {
      assert(_debugCheckNotHosted());
      renderObject.child = node.renderObject;
    }
  }

  bool _debugCheckNotHosted() {
    assert(
      node.renderObject.parent == null,
      'The node given to this NodeHost is already hosted: its render object has a '
      'parent. A node tree lives in one place at a time, so remove it from its '
      'other host, or from its parent node, before hosting it here.',
    );
    return true;
  }
}

/// The render object behind [NodeHost]: a proxy onto a node tree's root render
/// object.
class RenderNodeHost extends RenderProxyBox {
  /// Creates a proxy onto [child].
  RenderNodeHost({RenderBox? child}) : super(child);

  @override
  void dispose() {
    // The node tree outlives this render object, so hand the root back rather
    // than leaving it parented to something disposed.
    child = null;
    super.dispose();
  }
}
