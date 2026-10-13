import 'package:flutter_test/flutter_test.dart';
import 'package:remote_dev/core/local_preview.dart';

void main() {
  group('Local preview credential loading', () {
    test('Should prefer the process environment credential', () async {
      var nativeReadCount = 0;
      final password = await loadLocalPreviewPassword(
        isIOS: true,
        processPassword: 'environment-test-password',
        readNativePassword: () async {
          nativeReadCount += 1;
          return 'native-test-password';
        },
      );

      expect(password, 'environment-test-password');
      expect(nativeReadCount, 0);
    });

    test('Should read the iOS credential through the native bridge', () async {
      var nativeReadCount = 0;
      final password = await loadLocalPreviewPassword(
        isIOS: true,
        processPassword: null,
        readNativePassword: () async {
          nativeReadCount += 1;
          return 'native-test-password';
        },
      );

      expect(password, 'native-test-password');
      expect(nativeReadCount, 1);
    });

    test('Should not call the iOS bridge on other platforms', () async {
      var nativeReadCount = 0;
      final password = await loadLocalPreviewPassword(
        isIOS: false,
        processPassword: null,
        readNativePassword: () async {
          nativeReadCount += 1;
          return 'native-test-password';
        },
      );

      expect(password, isNull);
      expect(nativeReadCount, 0);
    });
  });
}
