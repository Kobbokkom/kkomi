import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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

Future<void> _initializeAds() async {
  if (kIsWeb ||
      _bannerId.isEmpty ||
      (kDebugMode && const bool.fromEnvironment('KKOMI_CAPTURE_SCREENSHOTS'))) {
    return;
  }

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
  const AdBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: _adsAllowed,
      builder: (context, allowed, _) {
        if (!allowed) return const SizedBox.shrink();
        return LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < AdSize.banner.width) {
              return const SizedBox.shrink();
            }
            return const _BottomBanner();
          },
        );
      },
    );
  }
}

class _BottomBanner extends StatefulWidget {
  const _BottomBanner();

  @override
  State<_BottomBanner> createState() => _BottomBannerState();
}

class _BottomBannerState extends State<_BottomBanner> {
  BannerAd? _ad;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
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
    if (ad == null || !_loaded) return const SizedBox.shrink();
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
