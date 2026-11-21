import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'localization.dart';

const _androidBannerId = kReleaseMode
    ? String.fromEnvironment(
        'ANDROID_ADMOB_BANNER_ID',
        defaultValue: 'ca-app-pub-6737616702687889/1500674457',
      )
    : 'ca-app-pub-3940256099942544/6300978111';
const _iosBannerId = kReleaseMode
    ? String.fromEnvironment(
        'IOS_ADMOB_BANNER_ID',
        defaultValue: 'ca-app-pub-6737616702687889/1697961485',
      )
    : 'ca-app-pub-3940256099942544/2934735716';

String get _bannerId => switch (defaultTargetPlatform) {
  TargetPlatform.android => _androidBannerId,
  TargetPlatform.iOS => _iosBannerId,
  _ => '',
};

final _adsAllowed = ValueNotifier(false);
final _privacyRequired = ValueNotifier(false);
Future<void>? _initialization;
Future<InitializationStatus>? _sdkInitialization;
bool _privacyFormOpen = false;

Future<void> initializeAds() => _initialization ??= _initializeAds();

bool get _adsEnabled =>
    !kIsWeb &&
    _bannerId.isNotEmpty &&
    !(kDebugMode && const bool.fromEnvironment('KKOMI_CAPTURE_SCREENSHOTS'));

Future<void> _initializeAds() async {
  if (!_adsEnabled) return;

  final updated = Completer<bool>();
  ConsentInformation.instance.requestConsentInfoUpdate(
    ConsentRequestParameters(),
    () => updated.complete(true),
    (error) {
      _logConsentError(error);
      updated.complete(false);
    },
  );
  try {
    if (await updated.future) {
      await ConsentForm.loadAndShowConsentFormIfRequired(_logConsentError);
    }
  } catch (error) {
    debugPrint('AdMob consent form unavailable: $error');
  }
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    try {
      // App Store review requires the ATT prompt before any ad request.
      await const MethodChannel('kkomi/tracking').invokeMethod<void>('request');
    } on PlatformException catch (error) {
      debugPrint('Tracking authorization unavailable: $error');
    }
  }
  await _refreshConsent();
}

Future<void> _refreshConsent() async {
  try {
    final consent = ConsentInformation.instance;
    final privacyRequired =
        await consent.getPrivacyOptionsRequirementStatus() ==
        PrivacyOptionsRequirementStatus.required;
    try {
      if (await consent.canRequestAds()) {
        await (_sdkInitialization ??= MobileAds.instance.initialize());
        _adsAllowed.value = true;
      }
    } finally {
      _privacyRequired.value = privacyRequired;
    }
  } catch (error) {
    debugPrint('AdMob unavailable: $error');
  }
}

void _logConsentError(FormError? error) {
  if (error != null) debugPrint('AdMob consent: ${error.message}');
}

class AdPrivacyOptions extends StatelessWidget {
  const AdPrivacyOptions({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: _privacyRequired,
      builder: (context, required, _) => required
          ? ListTile(
              leading: const Icon(Icons.privacy_tip_outlined),
              title: Text(
                translate(context, '광고 개인정보 설정', const {
                  '광고 개인정보 설정': [
                    'Ad privacy options',
                    '広告のプライバシー設定',
                    '广告隐私设置',
                    '廣告隱私權設定',
                    'Privacidad publicitaria',
                    'Confidentialité publicitaire',
                    'Datenschutz bei Werbung',
                    'Privacidade de anúncios',
                    'Privasi iklan',
                  ],
                }),
              ),
              onTap: _showPrivacyOptions,
            )
          : const SizedBox.shrink(),
    );
  }

  Future<void> _showPrivacyOptions() async {
    if (_privacyFormOpen) return;
    _privacyFormOpen = true;
    _adsAllowed.value = false;
    try {
      await ConsentForm.showPrivacyOptionsForm(_logConsentError);
    } catch (error) {
      debugPrint('AdMob privacy options unavailable: $error');
    } finally {
      await _refreshConsent();
      _privacyFormOpen = false;
    }
  }
}

class AdBanner extends StatelessWidget {
  const AdBanner({super.key, this.visible = true});

  final bool visible;

  @override
  Widget build(BuildContext context) {
    if (!_adsEnabled) return const SizedBox.shrink();
    final isCurrentRoute = ModalRoute.isCurrentOf(context) ?? true;
    return LayoutBuilder(
      builder: (context, constraints) {
        final showBanner =
            visible && constraints.maxWidth >= AdSize.banner.width;
        // Reserve the banner height up front so content does not jump when
        // consent finishes or the ad arrives.
        return SizedBox(
          height: showBanner ? AdSize.banner.height.toDouble() : 0,
          child: ValueListenableBuilder<bool>(
            valueListenable: _adsAllowed,
            builder: (context, allowed, _) => allowed
                ? _BottomBanner(visible: showBanner && isCurrentRoute)
                : const SizedBox.shrink(),
          ),
        );
      },
    );
  }
}

class _BottomBanner extends StatefulWidget {
  const _BottomBanner({required this.visible});

  final bool visible;

  @override
  State<_BottomBanner> createState() => _BottomBannerState();
}

class _BottomBannerState extends State<_BottomBanner> {
  BannerAd? _ad;
  bool _loaded = false;
  bool _requested = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant _BottomBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    unawaited(_load());
  }

  Future<void> _load() async {
    if (!widget.visible || _requested) return;
    _requested = true;
    try {
      final ad = BannerAd(
        adUnitId: _bannerId,
        size: AdSize.banner,
        request: const AdRequest(),
        listener: BannerAdListener(
          onAdLoaded: (ad) {
            if (mounted && identical(_ad, ad)) {
              setState(() => _loaded = true);
            }
          },
          onAdFailedToLoad: (ad, error) {
            debugPrint('AdMob banner failed: ${error.code}');
            if (identical(_ad, ad) && !_loaded) {
              _ad = null;
              unawaited(ad.dispose());
            }
          },
        ),
      );
      _ad = ad;
      await ad.load();
    } catch (error) {
      debugPrint('AdMob banner unavailable: $error');
      unawaited(_ad?.dispose());
      _ad = null;
    }
  }

  @override
  void dispose() {
    unawaited(_ad?.dispose());
    _ad = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ad = _ad;
    if (!widget.visible || ad == null || !_loaded) {
      return const SizedBox.shrink();
    }
    return Center(
      heightFactor: 1,
      child: SizedBox(
        width: ad.size.width.toDouble(),
        height: ad.size.height.toDouble(),
        child: AdWidget(ad: ad),
      ),
    );
  }
}
