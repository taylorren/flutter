// Copyright 2016 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/animation.dart';
import 'package:flutter/widgets.dart';

void main() {
  testWidgets('awaiting animation controllers - using direct future', (WidgetTester tester) async {
    final AnimationController controller1 = new AnimationController(
      duration: const Duration(milliseconds: 100),
      vsync: const TestVSync(),
    );
    final AnimationController controller2 = new AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: const TestVSync(),
    );
    final AnimationController controller3 = new AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: const TestVSync(),
    );
    final List<String> log = <String>[];
    Future<Null> runTest() async {
      log.add('a'); // t=0
      await controller1.forward(); // starts at t=0 again
      log.add('b'); // wants to end at t=100 but missed frames until t=150
      await controller2.forward(); // starts at t=200
      log.add('c'); // wants to end at t=800 but missed frames until t=850
      await controller3.forward(); // starts at t=1200
      log.add('d'); // wants to end at t=1500 but missed frames until t=1600
    }
    log.add('start');
    runTest().then((Null value) {
      log.add('end');
    });
    await tester.pump(); // t=0
    expect(log, <String>['start', 'a']);
    await tester.pump(); // t=0 again
    expect(log, <String>['start', 'a']);
    await tester.pump(const Duration(milliseconds: 50)); // t=50
    expect(log, <String>['start', 'a']);
    await tester.pump(const Duration(milliseconds: 100)); // t=150
    expect(log, <String>['start', 'a', 'b']);
    await tester.pump(const Duration(milliseconds: 50)); // t=200
    expect(log, <String>['start', 'a', 'b']);
    await tester.pump(const Duration(milliseconds: 400)); // t=600
    expect(log, <String>['start', 'a', 'b']);
    await tester.pump(const Duration(milliseconds: 199)); // t=799
    expect(log, <String>['start', 'a', 'b']);
    await tester.pump(const Duration(milliseconds: 51)); // t=850
    expect(log, <String>['start', 'a', 'b', 'c']);
    await tester.pump(const Duration(milliseconds: 400)); // t=1200
    expect(log, <String>['start', 'a', 'b', 'c']);
    await tester.pump(const Duration(milliseconds: 400)); // t=1600
    expect(log, <String>['start', 'a', 'b', 'c', 'd', 'end']);
  });

  testWidgets('awaiting animation controllers - using orCancel', (WidgetTester tester) async {
    final AnimationController controller1 = new AnimationController(
      duration: const Duration(milliseconds: 100),
      vsync: const TestVSync(),
    );
    final AnimationController controller2 = new AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: const TestVSync(),
    );
    final AnimationController controller3 = new AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: const TestVSync(),
    );
    final List<String> log = <String>[];
    Future<Null> runTest() async {
      log.add('a'); // t=0
      await controller1.forward().orCancel; // starts at t=0 again
      log.add('b'); // wants to end at t=100 but missed frames until t=150
      await controller2.forward().orCancel; // starts at t=200
      log.add('c'); // wants to end at t=800 but missed frames until t=850
      await controller3.forward().orCancel; // starts at t=1200
      log.add('d'); // wants to end at t=1500 but missed frames until t=1600
    }
    log.add('start');
    runTest().then((Null value) {
      log.add('end');
    });
    await tester.pump(); // t=0
    expect(log, <String>['start', 'a']);
    await tester.pump(); // t=0 again
    expect(log, <String>['start', 'a']);
    await tester.pump(const Duration(milliseconds: 50)); // t=50
    expect(log, <String>['start', 'a']);
    await tester.pump(const Duration(milliseconds: 100)); // t=150
    expect(log, <String>['start', 'a', 'b']);
    await tester.pump(const Duration(milliseconds: 50)); // t=200
    expect(log, <String>['start', 'a', 'b']);
    await tester.pump(const Duration(milliseconds: 400)); // t=600
    expect(log, <String>['start', 'a', 'b']);
    await tester.pump(const Duration(milliseconds: 199)); // t=799
    expect(log, <String>['start', 'a', 'b']);
    await tester.pump(const Duration(milliseconds: 51)); // t=850
    expect(log, <String>['start', 'a', 'b', 'c']);
    await tester.pump(const Duration(milliseconds: 400)); // t=1200
    expect(log, <String>['start', 'a', 'b', 'c']);
    await tester.pump(const Duration(milliseconds: 400)); // t=1600
    expect(log, <String>['start', 'a', 'b', 'c', 'd', 'end']);
  });

  testWidgets('awaiting animation controllers and failing', (WidgetTester tester) async {
    final AnimationController controller1 = new AnimationController(
      duration: const Duration(milliseconds: 100),
      vsync: const TestVSync(),
    );
    final List<String> log = <String>[];
    Future<Null> runTest() async {
      try {
        log.add('start');
        await controller1.forward().orCancel;
        log.add('fail');
      } on TickerCanceled {
        log.add('caught');
      }
    }
    runTest().then((Null value) {
      log.add('end');
    });
    await tester.pump(); // start ticker
    expect(log, <String>['start']);
    await tester.pump(const Duration(milliseconds: 50));
    expect(log, <String>['start']);
    controller1.dispose();
    expect(log, <String>['start']);
    await tester.idle();
    expect(log, <String>['start', 'caught', 'end']);
  });

  testWidgets('creating orCancel future later', (WidgetTester tester) async {
    final AnimationController controller1 = new AnimationController(
      duration: const Duration(milliseconds: 100),
      vsync: const TestVSync(),
    );
    final TickerFuture f = controller1.forward();
    await tester.pump(); // start ticker
    await tester.pump(const Duration(milliseconds: 200)); // end ticker
    await f; // should be a no-op
    await f.orCancel; // should create a resolved future
    expect(true, isTrue); // should reach here
  });

  testWidgets('creating orCancel future later', (WidgetTester tester) async {
    final AnimationController controller1 = new AnimationController(
      duration: const Duration(milliseconds: 100),
      vsync: const TestVSync(),
    );
    final TickerFuture f = controller1.forward();
    await tester.pump(); // start ticker
    controller1.stop(); // cancel ticker
    bool ok = false;
    try {
      await f.orCancel; // should create a resolved future
    } on TickerCanceled {
      ok = true;
    }
    expect(ok, isTrue); // should reach here
  });

  testWidgets('TickerFuture is a Future', (WidgetTester tester) async {
    final AnimationController controller1 = new AnimationController(
      duration: const Duration(milliseconds: 100),
      vsync: const TestVSync(),
    );
    final TickerFuture f = controller1.forward();
    await tester.pump(); // start ticker
    await tester.pump(const Duration(milliseconds: 200)); // end ticker
    expect(await f.asStream().single, isNull);
    await f.catchError((dynamic e) { throw 'do not reach'; });
    expect(await f.then<bool>((Null value) => true), isTrue);
    expect(await f.whenComplete(() => false), isNull);
    expect(await f.timeout(const Duration(seconds: 5)), isNull);
  });
}
