import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_dev/core/store.dart';
import 'package:remote_dev/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('Should show a clear first-run path and separate destinations',
      (tester) async {
    final store = AppStore();
    await store.load();

    await tester.pumpWidget(RemoteDevApp(store: store));
    await tester.pumpAndSettle();

    expect(find.text('Seu trabalho,\nsem interrupções.'), findsOneWidget);
    expect(find.text('Conecte seu ambiente'), findsOneWidget);
    expect(find.text('Configurar máquina'), findsOneWidget);

    await tester.tap(find.text('Configurar máquina'));
    await tester.pumpAndSettle();

    expect(find.text('SEUS AMBIENTES'), findsOneWidget);
    expect(find.text('Máquinas'), findsWidgets);
    expect(find.text('Conectar máquina'), findsOneWidget);
  });
}
