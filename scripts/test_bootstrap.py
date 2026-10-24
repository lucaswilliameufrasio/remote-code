#!/usr/bin/env python3
"""Native configuration tests, run without requiring a Flutter installation."""
import importlib.util
import pathlib
import plistlib
import tempfile
import unittest
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location('bootstrap', pathlib.Path(__file__).with_name('bootstrap.py'))
bootstrap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bootstrap)

class NativeConfigurationTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        self.android = self.root / 'android'
        manifest = self.android / 'app/src/main/AndroidManifest.xml'
        manifest.parent.mkdir(parents=True)
        manifest.write_text('''<manifest xmlns:android="http://schemas.android.com/apk/res/android">
          <application android:name="${applicationName}"><activity android:name=".MainActivity" /></application>
        </manifest>''')
        activity = self.android / 'app/src/main/kotlin/example/MainActivity.kt'
        activity.parent.mkdir(parents=True)
        activity.write_text('''import io.flutter.embedding.android.FlutterActivity
class MainActivity : FlutterActivity()''')
        styles = self.android / 'app/src/main/res/values/styles.xml'
        styles.parent.mkdir(parents=True)
        styles.write_text('''<resources>
  <style name="LaunchTheme" parent="@android:style/Theme.Light.NoTitleBar" />
  <style name="NormalTheme" parent="@android:style/Theme.Light.NoTitleBar" />
</resources>''')
        self.gradle = self.android / 'app/build.gradle.kts'
        self.gradle.write_text('android { defaultConfig { minSdk = flutter.minSdkVersion } }')
        self.ios = self.root / 'ios'
        (self.ios / 'Runner').mkdir(parents=True)
        with (self.ios / 'Runner/Info.plist').open('wb') as stream:
            plistlib.dump({'CFBundleIdentifier': '$(PRODUCT_BUNDLE_IDENTIFIER)', 'OtherSetting': 'preserve'}, stream)
        (self.ios / 'Runner.xcodeproj').mkdir()
        (self.ios / 'Runner.xcodeproj/project.pbxproj').write_text('INFOPLIST_FILE = Runner/Info.plist;')
        (self.ios / 'Flutter').mkdir()
        (self.ios / 'Flutter/Debug.xcconfig').write_text('#include "Generated.xcconfig"\n')
        (self.ios / 'Flutter/Release.xcconfig').write_text('#include "Generated.xcconfig"\n')
    def tearDown(self):
        self.temp.cleanup()
    def manifest(self):
        return ET.parse(self.android / 'app/src/main/AndroidManifest.xml').getroot()
    def plist(self):
        with (self.ios / 'Runner/Info.plist').open('rb') as stream:
            return plistlib.load(stream)
    def test_android_permissions_and_fragment_activity_for_biometrics(self):
        bootstrap.configure_android(self.android, False)
        root = self.manifest()
        names = [v.get(f'{{{bootstrap.ANDROID}}}name') for v in root.findall('uses-permission')]
        self.assertEqual(names, [
            'android.permission.INTERNET',
            'android.permission.USE_BIOMETRIC',
            'android.permission.RECORD_AUDIO',
            'android.permission.CAMERA',
        ])
        self.assertEqual(
            root.find('queries/intent/action').get(f'{{{bootstrap.ANDROID}}}name'),
            'android.speech.RecognitionService',
        )
        self.assertEqual(root.find('application').get(f'{{{bootstrap.ANDROID}}}usesCleartextTraffic'), 'false')
        self.assertEqual(root.find('application').get(f'{{{bootstrap.ANDROID}}}allowBackup'), 'false')
        self.assertIn('minSdk = 24', self.gradle.read_text())
        activity = self.android / 'app/src/main/kotlin/example/MainActivity.kt'
        self.assertIn('FlutterFragmentActivity', activity.read_text())
        styles = (self.android / 'app/src/main/res/values/styles.xml').read_text()
        self.assertEqual(styles.count('Theme.AppCompat.DayNight.NoActionBar'), 2)
    def test_repeated_configuration_does_not_duplicate_permission(self):
        bootstrap.configure_android(self.android, False)
        bootstrap.configure_android(self.android, False)
        self.assertEqual(len(self.manifest().findall('uses-permission')), 4)
        self.assertEqual(len(self.manifest().findall('application/activity')), 1)
        self.assertEqual(len(self.manifest().findall('queries/intent')), 1)
        styles = (self.android / 'app/src/main/res/values/styles.xml').read_text()
        self.assertEqual(styles.count('Theme.AppCompat.DayNight.NoActionBar'), 2)
    def test_android_http_opt_in(self):
        bootstrap.configure_android(self.android, True)
        self.assertEqual(self.manifest().find('application').get(f'{{{bootstrap.ANDROID}}}usesCleartextTraffic'), 'true')
    def test_ios_default_https_preserves_bundle_identity(self):
        bootstrap.configure_ios(self.ios, False)
        info = self.plist()
        self.assertFalse(info['NSAppTransportSecurity']['NSAllowsArbitraryLoads'])
        self.assertEqual(info['CFBundleIdentifier'], '$(PRODUCT_BUNDLE_IDENTIFIER)')
        self.assertEqual(info['OtherSetting'], 'preserve')
        self.assertEqual(info['CFBundleDisplayName'], 'CodeRelay')
        self.assertEqual(info['CFBundleName'], 'CodeRelay')
        self.assertEqual(info['NSFaceIDUsageDescription'], 'Usar Face ID para desbloquear o CodeRelay.')
        self.assertEqual(
            info['NSMicrophoneUsageDescription'],
            'Usar o microfone para ditar um prompt e revisar o texto antes de enviar.',
        )
        self.assertEqual(
            info['NSSpeechRecognitionUsageDescription'],
            'Transcrever o ditado para texto editável antes de enviar ao OpenCode.',
        )
        with (self.ios / 'Runner/Runner.entitlements').open('rb') as stream:
            self.assertEqual(plistlib.load(stream)['keychain-access-groups'], [])
        self.assertIn('CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;',
            (self.ios / 'Runner.xcodeproj/project.pbxproj').read_text())
    def test_ios_opt_in_is_reversible(self):
        bootstrap.configure_ios(self.ios, True)
        self.assertTrue(self.plist()['NSAppTransportSecurity']['NSAllowsArbitraryLoads'])
        bootstrap.configure_ios(self.ios, False)
        self.assertFalse(self.plist()['NSAppTransportSecurity']['NSAllowsArbitraryLoads'])
    def test_ios_local_preview_swift_condition_is_debug_only_and_idempotent(self):
        bootstrap.configure_ios(self.ios, False)
        bootstrap.configure_ios(self.ios, False)
        debug_config = (self.ios / 'Flutter/Debug.xcconfig').read_text()
        release_config = (self.ios / 'Flutter/Release.xcconfig').read_text()
        condition = 'SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG $(inherited)'
        self.assertEqual(debug_config.count(condition), 1)
        self.assertNotIn(condition, release_config)
    def test_older_groovy_template(self):
        self.gradle.unlink()
        groovy = self.android / 'app/build.gradle'
        groovy.write_text('minSdkVersion flutter.minSdkVersion')
        bootstrap.configure_android(self.android, False)
        self.assertEqual(groovy.read_text(), 'minSdkVersion 24')

    def test_android_minimum_sdk_is_raised_without_lowering_newer_values(self):
        self.gradle.write_text('minSdk = 23')
        bootstrap.configure_android(self.android, False)
        self.assertEqual(self.gradle.read_text(), 'minSdk = 24')

        self.gradle.write_text('minSdk = 26')
        bootstrap.configure_android(self.android, False)
        self.assertEqual(self.gradle.read_text(), 'minSdk = 26')

    def test_android_identity_is_updated_and_configuration_is_idempotent(self):
        self.gradle.write_text('namespace = "old.app"\napplicationId = "old.app"\nminSdk = 26')
        activity = self.android / 'app/src/main/kotlin/example/MainActivity.kt'
        activity.write_text('package old.app\nimport io.flutter.embedding.android.FlutterActivity\nclass MainActivity : FlutterActivity()')
        bootstrap.configure_android(self.android, False)
        bootstrap.configure_android(self.android, False)
        self.assertEqual(self.gradle.read_text().count('"com.lucaswilliameufrasio.remotecode"'), 2)
        self.assertIn('package com.lucaswilliameufrasio.remotecode', activity.read_text())
        self.assertEqual(self.manifest().find('application').get(f'{{{bootstrap.ANDROID}}}label'), 'CodeRelay')

    def test_ios_identity_updates_all_build_modes_and_preserves_test_suffix(self):
        project = self.ios / 'Runner.xcodeproj/project.pbxproj'
        project.write_text('PRODUCT_BUNDLE_IDENTIFIER = old.app;\nPRODUCT_BUNDLE_IDENTIFIER = old.app.RunnerTests;\nINFOPLIST_FILE = Runner/Info.plist;')
        bootstrap.configure_ios(self.ios, False)
        bootstrap.configure_ios(self.ios, False)
        self.assertIn('PRODUCT_BUNDLE_IDENTIFIER = com.lucaswilliameufrasio.remotecode;', project.read_text())
        self.assertIn('PRODUCT_BUNDLE_IDENTIFIER = com.lucaswilliameufrasio.remotecode.RunnerTests;', project.read_text())
        self.assertNotIn('old.app', project.read_text())

    def test_groovy_identity_updates_namespace_and_application_id(self):
        self.gradle.unlink()
        groovy = self.android / 'app/build.gradle'
        groovy.write_text("namespace 'old.app'\napplicationId 'old.app'\nminSdkVersion 24")
        bootstrap.configure_android(self.android, False)
        self.assertEqual(groovy.read_text().count('"com.lucaswilliameufrasio.remotecode"'), 2)

    def test_camera_is_optional_and_configuration_is_idempotent(self):
        bootstrap.configure_android(self.android, False)
        bootstrap.configure_android(self.android, False)
        features = self.manifest().findall('uses-feature')
        self.assertEqual(len(features), 1)
        self.assertEqual(features[0].get(f'{{{bootstrap.ANDROID}}}name'), 'android.hardware.camera')
        self.assertEqual(features[0].get(f'{{{bootstrap.ANDROID}}}required'), 'false')

    def test_ios_explains_local_camera_use_for_pairing(self):
        bootstrap.configure_ios(self.ios, False)
        self.assertIn('Nenhuma imagem é enviada', self.plist()['NSCameraUsageDescription'])

    def test_android_copies_brand_icons_at_every_density(self):
        bootstrap.configure_android(self.android, False)
        for density, size in (('mdpi', 48), ('hdpi', 72), ('xhdpi', 96),
                              ('xxhdpi', 144), ('xxxhdpi', 192)):
            self.assertEqual(
                (self.android / f'app/src/main/res/mipmap-{density}/ic_launcher.png').read_bytes(),
                (bootstrap.ROOT / f'assets/brand/raster/{size}.png').read_bytes(),
            )

    def test_ios_copies_brand_icons_without_changing_catalog(self):
        catalog = self.ios / 'Runner/Assets.xcassets/AppIcon.appiconset'
        catalog.mkdir(parents=True)
        contents = '{"images":[{"filename":"icon.png","size":"60x60","scale":"3x"}]}'
        (catalog / 'Contents.json').write_text(contents)
        bootstrap.configure_ios(self.ios, False)
        self.assertEqual((catalog / 'Contents.json').read_text(), contents)
        self.assertEqual((catalog / 'icon.png').read_bytes(),
                         (bootstrap.ROOT / 'assets/brand/raster/180.png').read_bytes())

if __name__ == '__main__':
    unittest.main(verbosity=2)
