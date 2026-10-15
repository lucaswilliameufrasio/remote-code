import 'dart:math';

Future<List<TResult>> mapConcurrent<TItem, TResult>({
  required List<TItem> items,
  required int concurrency,
  required Future<TResult> Function(TItem item) operation,
}) async {
  if (concurrency < 1) {
    throw ArgumentError.value(concurrency, 'concurrency');
  }
  if (items.isEmpty) {
    return [];
  }

  final results = List<Object?>.filled(items.length, null);
  var nextIndex = 0;

  Future<void> runWorker() async {
    while (true) {
      final itemIndex = nextIndex;
      if (itemIndex >= items.length) {
        break;
      }
      nextIndex++;
      results[itemIndex] = await operation(items[itemIndex]);
    }
  }

  final workerCount = min(concurrency, items.length);
  final workers = <Future<void>>[];
  for (var workerIndex = 0; workerIndex < workerCount; workerIndex++) {
    workers.add(runWorker());
  }
  await Future.wait(workers);

  final orderedResults = <TResult>[];
  for (var resultIndex = 0; resultIndex < results.length; resultIndex++) {
    orderedResults.add(results[resultIndex] as TResult);
  }
  return orderedResults;
}
