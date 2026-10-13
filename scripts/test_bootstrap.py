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
        self.assertEqual(names, ['android.permission.INTERNET', 'android.permission.USE_BIOMETRIC'])
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
        self.assertEqual(len(self.manifest().findall('uses-permission')), 2)
        self.assertEqual(len(self.manifest().findall('application/activity')), 1)
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
        self.assertEqual(info['CFBundleDisplayName'], 'Remoto')
        self.assertEqual(info['NSFaceIDUsageDescription'], 'Usar Face ID para desbloquear o Remoto.')
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

if __name__ == '__main__':
    unittest.main(verbosity=2)
