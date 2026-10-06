// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Profile-mode entry point for the B1-B11 fine-grained-reactivity benchmarks.
//
// The same scenario files run under `flutter test` produce debug-JIT numbers
// (the test runner cannot do AOT). This file registers those same tests
// against IntegrationTestWidgetsFlutterBinding so the identical harness runs
// profile-compiled on a real device:
//
//   cd dev/reactive_demos
//   ../../bin/flutter drive -d macos \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/profile_bench_test.dart \
//     --profile
//
// Results appear in the drive output as the usual RESULT lines / timing
// tables. Scenario sources are copies of
// dev/benchmarks/microbenchmarks/test/reactivity/; if a scenario changes
// there, refresh the copy here.

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'reactivity/b10_prop_overhead_test.dart' as b10;
import 'reactivity/b11_static_mount_test.dart' as b11;
import 'reactivity/b1_single_sprite_update_test.dart' as b1;
import 'reactivity/b2_all_sprites_update_test.dart' as b2;
import 'reactivity/b3_particle_field_batch_test.dart' as b3;
import 'reactivity/b4_deep_tree_counter_test.dart' as b4;
import 'reactivity/b5_deep_static_tree_leaf_test.dart' as b5;
import 'reactivity/b6_wide_list_row_update_test.dart' as b6;
import 'reactivity/b7_material_checkbox_grid_test.dart' as b7;
import 'reactivity/b8_mount_unmount_test.dart' as b8;
import 'reactivity/b9_scene_mode_test.dart' as b9;

void main() {
  // Must run before any testWidgets registration below, so that the
  // flutter_test `testWidgets` calls bind to the integration binding rather
  // than creating a plain TestWidgetsFlutterBinding.
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // `pump()` must run frame callbacks synchronously instead of waiting for a
  // real vsync, otherwise every timed iteration is quantized to the refresh
  // rate (~16.6 ms at 60 Hz) and the numbers measure the display, not the
  // work. This is the same policy the drive-based microbenchmarks use.
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.benchmarkLive;

  b1.main();
  b2.main();
  b3.main();
  b4.main();
  b5.main();
  b6.main();
  b7.main();
  b8.main();
  b9.main();
  b10.main();
  b11.main();
}
