// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:test/test.dart';

import '../../descriptor.dart' as d;
import '../../test_pub.dart';

void main() {
  test('adds the latest stable version of the package', () async {
    await servePackages()
      ..serve('foo', '1.2.2')
      ..serve('foo', '1.2.3')
      ..serve('foo', '1.2.4-dev');

    await runPub(
        args: ['cache', 'add', 'foo'], output: 'Downloading foo 1.2.3...');

    await d.cacheDir({'foo': '1.2.3'}).validate();
  });
}
