// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// B9: scene mode -- B1 and B3 re-run against the retained scene graph. See
// docs/fine_grained_reactivity/BENCHMARKS.md. The payoff of skipping
// widgets, elements, and render objects entirely.
//
// There is no legacy-Flutter baseline for this scenario: a retained scene
// graph that bypasses the widget/element/render-object tree does not exist
// on unmodified Flutter, which is why BENCHMARKS.md marks B9's baseline
// columns "n/a". The comparison point for this scenario is simply B1's and
// B3's own baseline numbers (test/reactivity/b1_single_sprite_update_test.dart
// and test/reactivity/b3_particle_field_batch_test.dart).
//
// TODO(fork): once the fork exposes a retained scene graph API, re-run B1
// and B3's workloads through it here and compare against those baselines.

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'scene mode baseline is not defined',
    () {},
    skip: 'no retained scene graph API exists yet; see the TODO(fork) above',
  );
}
