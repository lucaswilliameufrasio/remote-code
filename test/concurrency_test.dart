import 'package:flutter_test/flutter_test.dart';
import 'package:remote_dev/core/concurrency.dart';

void main() {
  test('Should preserve result order while bounding concurrent work', () async {
    var activeOperations = 0;
    var maximumActiveOperations = 0;

    final results = await mapConcurrent<int, int>(
      items: [0, 1, 2, 3, 4, 5],
      concurrency: 2,
      operation: (item) async {
        activeOperations++;
        if (activeOperations > maximumActiveOperations) {
          maximumActiveOperations = activeOperations;
        }
        await Future<void>.delayed(Duration(milliseconds: 2 + item));
        activeOperations--;
        return item * 2;
      },
    );

    expect(results, [0, 2, 4, 6, 8, 10]);
    expect(maximumActiveOperations, 2);
    expect(activeOperations, 0);
  });

  test('Should return an empty result without starting work', () async {
    var operationStarted = false;

    final results = await mapConcurrent<int, int>(
      items: [],
      concurrency: 3,
      operation: (item) async {
        operationStarted = true;
        return item;
      },
    );

    expect(results, isEmpty);
    expect(operationStarted, isFalse);
  });
}
