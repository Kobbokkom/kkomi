import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
// Use the native channel codecs so the test can count requests without the SDK.
// ignore: implementation_imports
import 'package:google_mobile_ads/src/ad_instance_manager.dart';
// ignore: implementation_imports
import 'package:google_mobile_ads/src/ump/user_messaging_codec.dart';
import 'package:kkomi/ads.dart';

void main() {
  testWidgets('Only the first visible layout requests an ad for the slot', (
    tester,
  ) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    final adChannel = MethodChannel(
      'plugins.flutter.io/google_mobile_ads',
      StandardMethodCodec(AdMessageCodec()),
    );
    final consentChannel = MethodChannel(
      'plugins.flutter.io/google_mobile_ads/ump',
      StandardMethodCodec(UserMessagingCodec()),
    );
    final calls = <String>[];
    messenger.setMockMethodCallHandler(adChannel, (call) async {
      if (call.method == 'MobileAds#initialize') {
        return InitializationStatus({});
      }
      if (call.method == 'loadBannerAd' || call.method == 'disposeAd') {
        calls.add(call.method);
      }
      return null;
    });
    messenger.setMockMethodCallHandler(consentChannel, (call) async {
      return switch (call.method) {
        'ConsentInformation#canRequestAds' => true,
        'ConsentInformation#getPrivacyOptionsRequirementStatus' => 0,
        _ => null,
      };
    });

    Widget app(bool visible) => MaterialApp(
      home: Scaffold(bottomNavigationBar: AdBanner(visible: visible)),
    );
    await tester.pumpWidget(app(false));
    unawaited(initializeAds());
    await tester.pumpAndSettle();
    expect(calls, isEmpty);

    for (var i = 0; i < 3; i++) {
      await tester.pumpWidget(app(true));
      await tester.pumpWidget(app(false));
    }
    expect(calls, ['loadBannerAd']);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(calls, ['loadBannerAd', 'disposeAd']);
  });
}
