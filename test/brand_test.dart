import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_dev/features/brand.dart';

void main() {
  testWidgets(
      'Should display the shared CodeRelay logo with an accessible name',
      (tester) async {
    await tester
        .pumpWidget(const MaterialApp(home: Scaffold(body: BrandMark())));
    await tester.pumpAndSettle();

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, const AssetImage('assets/brand/logo.png'));
    expect(image.semanticLabel, 'CodeRelay');
    expect(image.width, 46);
    expect(image.height, 46);
    expect(tester.takeException(), isNull);
  });
}
