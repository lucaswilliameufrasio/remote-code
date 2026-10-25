enum SessionAlert {
  attentionRequired,
  becameIdle;

  String get message => switch (this) {
        attentionRequired =>
          'O agente precisa da sua atenção. Confira as pendências do chat.',
        becameIdle =>
          'O agente deixou de executar. Confira a resposta e eventuais erros.',
      };
}

/// Observes successful snapshots of the open chat, not background work.
class SessionAlertTracker {
  bool _initialized = false;
  bool _wasRunning = false;
  Set<String> _pending = {};

  SessionAlert? observe({
    required String status,
    required Set<String> pending,
  }) {
    final running = const {'running', 'busy', 'retry'}.contains(status);
    final needsAttention = pending.difference(_pending).isNotEmpty;
    final becameIdle = _initialized && _wasRunning && status == 'idle';
    _wasRunning = running;
    _pending = Set.of(pending);
    if (!_initialized) {
      _initialized = true;
      return null;
    }
    if (needsAttention) {
      return SessionAlert.attentionRequired;
    }
    return becameIdle ? SessionAlert.becameIdle : null;
  }
}
