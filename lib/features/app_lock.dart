import 'package:flutter/material.dart';
import '../core/security.dart';
import 'common.dart';
import 'design.dart';

enum _LockStage { locked, recoveryPhrase, recoveryPassword }

class AppLockScreen extends StatefulWidget {
  final AppSecurity security;
  final VoidCallback onUnlocked;

  const AppLockScreen({
    super.key,
    required this.security,
    required this.onUnlocked,
  });

  @override
  State<AppLockScreen> createState() => _AppLockScreenState();
}

class _AppLockScreenState extends State<AppLockScreen> {
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _recoveryController = TextEditingController();
  final TextEditingController _newPasswordController = TextEditingController();
  final TextEditingController _confirmationController = TextEditingController();

  _LockStage _stage = _LockStage.locked;
  bool _isBusy = false;
  bool _showPassword = false;
  String? _recoveryPhrase;
  String? _errorMessage;

  AppSecurity get security => widget.security;

  @override
  void dispose() {
    _passwordController.dispose();
    _recoveryController.dispose();
    _newPasswordController.dispose();
    _confirmationController.dispose();
    super.dispose();
  }

  Future<void> _unlockWithPassword() async {
    setState(() {
      _isBusy = true;
      _errorMessage = null;
    });
    try {
      final isValid = await security.verifyPassword(_passwordController.text);
      if (!mounted) {
        return;
      }
      if (isValid) {
        widget.onUnlocked();
      } else {
        setState(() => _errorMessage = 'Senha incorreta. Tente novamente.');
      }
    } on Object {
      if (mounted) {
        setState(() {
          _errorMessage =
              'Não foi possível verificar a senha. Tente novamente.';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  Future<void> _unlockWithBiometrics() async {
    setState(() {
      _isBusy = true;
      _errorMessage = null;
    });
    try {
      final isAuthenticated = await security.unlockWithBiometrics();
      if (!mounted) {
        return;
      }
      if (isAuthenticated) {
        widget.onUnlocked();
      } else {
        setState(() {
          _errorMessage = security.hasPassword
              ? 'Não foi possível validar. Use sua senha ou tente novamente.'
              : 'Não foi possível validar. Tente a biometria ou o código do dispositivo novamente.';
        });
      }
    } on Object {
      if (mounted) {
        setState(() {
          _errorMessage =
              'Não foi possível iniciar a autenticação do dispositivo.';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  Future<void> _verifyRecoveryPhrase() async {
    setState(() {
      _isBusy = true;
      _errorMessage = null;
    });
    try {
      final isValid =
          await security.verifyRecoveryPhrase(_recoveryController.text);
      if (!mounted) {
        return;
      }
      if (!isValid) {
        setState(
            () => _errorMessage = 'Frase inválida. Confira as 12 palavras.');
        return;
      }
      setState(() {
        _recoveryPhrase = _recoveryController.text;
        _recoveryController.clear();
        _stage = _LockStage.recoveryPassword;
      });
    } on Object {
      if (mounted) {
        setState(() {
          _errorMessage = 'Não foi possível verificar a frase de recuperação.';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  Future<void> _resetPassword() async {
    final newPassword = _newPasswordController.text;
    final validationMessage =
        AppSecurity.passwordValidationMessage(newPassword);
    if (validationMessage != null) {
      setState(() => _errorMessage = validationMessage);
      return;
    }
    if (newPassword != _confirmationController.text) {
      setState(() => _errorMessage = 'As senhas não coincidem.');
      return;
    }

    final recoveryPhrase = _recoveryPhrase;
    if (recoveryPhrase == null) {
      setState(() {
        _stage = _LockStage.recoveryPhrase;
        _errorMessage = 'Informe novamente a frase de recuperação.';
      });
      return;
    }

    setState(() {
      _isBusy = true;
      _errorMessage = null;
    });
    try {
      final wasRecovered = await security.recoverPassword(
        recoveryPhrase: recoveryPhrase,
        newPassword: newPassword,
      );
      if (!mounted) {
        return;
      }
      if (wasRecovered) {
        widget.onUnlocked();
      } else {
        setState(() {
          _stage = _LockStage.recoveryPhrase;
          _recoveryPhrase = null;
          _errorMessage = 'Frase inválida. Confira as 12 palavras.';
        });
      }
    } on Object {
      if (mounted) {
        setState(() {
          _errorMessage =
              'Não foi possível salvar a nova senha. Tente novamente.';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  void _returnToLock() {
    setState(() {
      _stage = _LockStage.locked;
      _recoveryPhrase = null;
      _errorMessage = null;
      _recoveryController.clear();
      _newPasswordController.clear();
      _confirmationController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 430),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _lockIcon(),
                  const SizedBox(height: 28),
                  Text(
                    _title(),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.8,
                        ),
                  ),
                  const SizedBox(height: 9),
                  Text(
                    _description(),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: AppColors.muted,
                          height: 1.45,
                        ),
                  ),
                  const SizedBox(height: 25),
                  _stageContent(),
                  if (_errorMessage != null) ...[
                    const SizedBox(height: 14),
                    InfoBox(_errorMessage!, icon: Icons.error_outline),
                  ],
                  const SizedBox(height: 18),
                  ..._stageActions(),
                  const SizedBox(height: 20),
                  Text(
                    'Suas credenciais continuam protegidas pelo armazenamento seguro do dispositivo.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: AppColors.muted,
                          height: 1.4,
                        ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _title() {
    return switch (_stage) {
      _LockStage.locked => 'Desbloquear CodeRelay',
      _LockStage.recoveryPhrase => 'Recuperar acesso',
      _LockStage.recoveryPassword => 'Definir uma nova senha',
    };
  }

  String _description() {
    return switch (_stage) {
      _LockStage.locked => 'Confirme sua identidade para retomar suas sessões.',
      _LockStage.recoveryPhrase =>
        'Digite sua frase de recuperação de 12 palavras.',
      _LockStage.recoveryPassword =>
        'A frase foi validada. Escolha uma senha nova para o app.',
    };
  }

  Widget _stageContent() {
    return switch (_stage) {
      _LockStage.locked => _lockedContent(),
      _LockStage.recoveryPhrase => _recoveryContent(),
      _LockStage.recoveryPassword => _newPasswordContent(),
    };
  }

  Widget _lockedContent() {
    if (!security.hasPassword) {
      return const InfoBox(
        'Use a biometria ou o código de acesso configurado no dispositivo para continuar.',
        icon: Icons.fingerprint,
      );
    }
    return TextField(
      controller: _passwordController,
      autofocus: true,
      obscureText: !_showPassword,
      autocorrect: false,
      enableSuggestions: false,
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => _unlockWithPassword(),
      decoration: InputDecoration(
        labelText: 'Senha do app',
        prefixIcon: const Icon(Icons.lock_outline),
        suffixIcon: IconButton(
          tooltip: _showPassword ? 'Ocultar senha' : 'Mostrar senha',
          onPressed: () => setState(() => _showPassword = !_showPassword),
          icon: Icon(
            _showPassword ? Icons.visibility_off : Icons.visibility,
          ),
        ),
      ),
    );
  }

  Widget _recoveryContent() {
    return TextField(
      controller: _recoveryController,
      autofocus: true,
      minLines: 3,
      maxLines: 5,
      autocorrect: false,
      enableSuggestions: false,
      textCapitalization: TextCapitalization.none,
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => _verifyRecoveryPhrase(),
      decoration: const InputDecoration(
        labelText: 'Frase de recuperação',
        hintText: '12 palavras, separadas por espaços',
        alignLabelWithHint: true,
        prefixIcon: Padding(
          padding: EdgeInsets.only(bottom: 40),
          child: Icon(Icons.key),
        ),
      ),
    );
  }

  Widget _newPasswordContent() {
    return Column(
      children: [
        TextField(
          controller: _newPasswordController,
          autofocus: true,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: 'Nova senha',
            prefixIcon: Icon(Icons.lock_outline),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _confirmationController,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _resetPassword(),
          decoration: const InputDecoration(
            labelText: 'Confirme a nova senha',
            prefixIcon: Icon(Icons.lock_reset),
          ),
        ),
      ],
    );
  }

  List<Widget> _stageActions() {
    return switch (_stage) {
      _LockStage.locked => [
          if (security.hasPassword)
            _actionButton(
              label: 'Desbloquear com senha',
              icon: Icons.lock_open,
              onPressed: _isBusy ? null : _unlockWithPassword,
              showProgress: _isBusy,
            ),
          if (security.biometricEnabled) ...[
            if (security.hasPassword) const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _isBusy ? null : _unlockWithBiometrics,
              icon: const Icon(Icons.face_retouching_natural),
              label: const Text('Usar biometria ou código do dispositivo'),
            ),
          ],
          if (security.hasPassword) ...[
            const SizedBox(height: 8),
            Center(
              child: TextButton(
                onPressed: _isBusy
                    ? null
                    : () {
                        setState(() {
                          _stage = _LockStage.recoveryPhrase;
                          _errorMessage = null;
                        });
                      },
                child: const Text('Esqueci minha senha'),
              ),
            ),
          ],
        ],
      _LockStage.recoveryPhrase => [
          _actionButton(
            label: 'Validar frase',
            icon: Icons.verified_user_outlined,
            onPressed: _isBusy ? null : _verifyRecoveryPhrase,
            showProgress: _isBusy,
          ),
          const SizedBox(height: 8),
          Center(
            child: TextButton(
              onPressed: _isBusy ? null : _returnToLock,
              child: const Text('Voltar ao desbloqueio'),
            ),
          ),
        ],
      _LockStage.recoveryPassword => [
          _actionButton(
            label: 'Redefinir senha e desbloquear',
            icon: Icons.lock_reset,
            onPressed: _isBusy ? null : _resetPassword,
            showProgress: _isBusy,
          ),
          const SizedBox(height: 8),
          Center(
            child: TextButton(
              onPressed: _isBusy ? null : _returnToLock,
              child: const Text('Cancelar'),
            ),
          ),
        ],
    };
  }

  Widget _lockIcon() {
    return Center(
      child: Container(
        width: 76,
        height: 76,
        decoration: BoxDecoration(
          color: AppColors.accentSoft,
          borderRadius: BorderRadius.circular(25),
        ),
        child: const Icon(
          Icons.shield_outlined,
          color: AppColors.accent,
          size: 36,
        ),
      ),
    );
  }

  Widget _actionButton({
    required String label,
    required IconData icon,
    required VoidCallback? onPressed,
    bool showProgress = false,
  }) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: onPressed,
        icon: showProgress
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(icon),
        label: Text(label),
      ),
    );
  }
}

class AppSecurityFailureScreen extends StatelessWidget {
  const AppSecurityFailureScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(28),
            child: InfoBox(
              'A configuração de segurança não pôde ser validada. Nenhum dado foi apagado. Feche e reabra o app; se o problema continuar, procure suporte antes de reinstalar.',
              icon: Icons.error_outline,
            ),
          ),
        ),
      ),
    );
  }
}
