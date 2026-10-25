import 'package:flutter_test/flutter_test.dart';
import 'package:remote_dev/core/session_alerts.dart';

void main() {
  test(
      'Should not claim completion or announce existing requests on first observation',
      () {
    final tracker = SessionAlertTracker();
    expect(
        tracker.observe(status: 'idle', pending: {'permission:first'}), isNull);
    expect(
        tracker.observe(status: 'idle', pending: {'permission:first'}), isNull);
  });

  test(
      'Should alert once when an observed run becomes idle without claiming success',
      () {
    final tracker = SessionAlertTracker();
    tracker.observe(status: 'running', pending: {});
    expect(tracker.observe(status: 'retry', pending: {}), isNull);
    expect(
        tracker.observe(status: 'idle', pending: {}), SessionAlert.becameIdle);
    expect(tracker.observe(status: 'idle', pending: {}), isNull);
    expect(SessionAlert.becameIdle.message, contains('eventuais erros'));
  });

  test(
      'Should deduplicate requests and prioritize attention over idle transitions',
      () {
    final tracker = SessionAlertTracker();
    tracker.observe(status: 'busy', pending: {});
    expect(tracker.observe(status: 'idle', pending: {'question:first'}),
        SessionAlert.attentionRequired);
    expect(
        tracker.observe(status: 'idle', pending: {'question:first'}), isNull);
    expect(tracker.observe(status: 'idle', pending: {'permission:first'}),
        SessionAlert.attentionRequired);
  });

  test('Should not interpret an unknown status as completion', () {
    final tracker = SessionAlertTracker();
    tracker.observe(status: 'running', pending: {});
    expect(tracker.observe(status: 'disconnected', pending: {}), isNull);
    expect(tracker.observe(status: 'idle', pending: {}), isNull);
  });
}
