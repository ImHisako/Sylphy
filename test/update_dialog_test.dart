import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sylphy/core/updates/app_updates.dart';
import 'package:sylphy/core/updates/github_updates.dart';
import 'package:sylphy/features/updates/update_host.dart';

import 'github_updates_test.dart' show UpdateFixture, TestUpdateInstaller;

void main() {
  testWidgets('download and installation require separate user actions', (
    tester,
  ) async {
    final fixture = UpdateFixture();
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('sylphy-dialog-test-'),
    ))!;
    addTearDown(() => directory.delete(recursive: true));
    final installer = TestUpdateInstaller();
    final controller = AppUpdateController(
      platform: UpdatePlatform.android,
      currentVersion: () async => AppVersion('1.1.0', 2),
      directory: () async => directory,
      releases: fixture.service(),
      installer: installer,
    );
    addTearDown(controller.dispose);
    await tester.runAsync(() => controller.check(manual: true));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => UpdateDialog(
                  controller: controller,
                  onRestart: () async {},
                ),
              ),
              child: const Text('Apri'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Apri'));
    await tester.pumpAndSettle();
    expect(find.text('Scarica aggiornamento'), findsOneWidget);
    expect(fixture.requests.length, 2);
    expect(installer.calls, 0);
    await tester.runAsync(() async {
      final ready = Completer<void>();
      controller.addListener(() {
        if (controller.stage == UpdateStage.ready && !ready.isCompleted) {
          ready.complete();
        }
      });
      await tester.tap(find.text('Scarica aggiornamento'));
      await ready.future.timeout(const Duration(seconds: 5));
    });
    await tester.pumpAndSettle();
    expect(find.text('Aggiorna'), findsOneWidget);
    expect(installer.calls, 0);
    await tester.runAsync(() async {
      final installation = Completer<void>();
      controller.addListener(() {
        if (installer.calls == 1 && !installation.isCompleted) {
          installation.complete();
        }
      });
      await tester.tap(find.text('Aggiorna'));
      await installation.future.timeout(const Duration(seconds: 5));
    });
    await tester.pumpAndSettle();
    expect(installer.calls, 1);
    await tester.tap(find.text('Più tardi'));
    await tester.pumpAndSettle();
    expect(find.byType(UpdateDialog), findsNothing);
  });

  testWidgets('update host opens one popup and delaying never downloads', (
    tester,
  ) async {
    final fixture = UpdateFixture();
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('sylphy-dialog-test-'),
    ))!;
    addTearDown(() => directory.delete(recursive: true));
    final controller = AppUpdateController(
      platform: UpdatePlatform.windows,
      currentVersion: () async => AppVersion('1.1.0', 2),
      directory: () async => directory,
      releases: fixture.service(),
      installer: TestUpdateInstaller(),
    );
    addTearDown(controller.dispose);
    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: key,
        builder: (_, child) => UpdateHost(
          controller: controller,
          navigatorKey: key,
          onRestart: () async {},
          child: child!,
        ),
        home: const Scaffold(body: Text('Chat')),
      ),
    );
    await tester.runAsync(() => controller.check(manual: true));
    await tester.pumpAndSettle();
    expect(find.byType(UpdateDialog), findsOneWidget);
    controller.showAvailable();
    await tester.pumpAndSettle();
    expect(find.byType(UpdateDialog), findsOneWidget);
    await tester.tap(find.text('Più tardi'));
    await tester.pumpAndSettle();
    expect(find.byType(UpdateDialog), findsNothing);
    expect(fixture.requests.length, 2);
    await tester.pumpWidget(const SizedBox());
  });
}
