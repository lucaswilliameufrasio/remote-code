import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/security.dart';
import 'common.dart';
import 'design.dart';

enum _OnboardingStage {
  welcome,
  protection,
  password,
  recovery,
  confirmRecovery,
}

class OnboardingScreen extends StatefulWidget {
  final AppSecurity security;
  final VoidCallback onComplete;

  const OnboardingScreen({
    super.key,
    required this.security,
    required this.onComplete,
  });

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmationController = TextEditingController();
  final TextEditingController _recoveryController = TextEditingController();

  _OnboardingStage _stage = _OnboardingStage.welcome;
  bool _wantsPassword = false;
  bool _wantsBiometrics = false;
  bool _showPassword = false;
  bool _showConfirmation = false;
  bool _isBusy = false;
  bool? _biometricsAvailable;
  String? _recoveryPhrase;
  String? _copiedRecoveryPhrase;
  String? _errorMessage;
  Timer? _clipboardClearTimer;

  AppSecurity get security => widget.security;

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmationController.dispose();
    _recoveryController.dispose();
    super.dispose();
  }

  void _openProtectionStep() {
    setState(() {
      _stage = _OnboardingStage.protection;
      _errorMessage = null;
    });
    _checkBiometrics();
  }

  Future<void> _checkBiometrics() async {
    final available = await security.hasEnrolledBiometrics();
    if (!mounted) {
      return;
    }
    setState(() {
      _biometricsAvailable = available;
      if (!available) {
        _wantsBiometrics = false;
      }
    });
  }

  Future<void> _continueFromProtection() async {
    if (_wantsPassword) {
      setState(() {
        _stage = _OnboardingStage.password;
        _errorMessage = null;
      });
      return;
    }

    await _finishWithoutPassword();
  }

  Future<void> _finishWithoutPassword() async {
    setState(() {
      _isBusy = true;
      _errorMessage = null;
    });
    try {
      if (_wantsBiometrics) {
        await security.saveProtection(enableBiometrics: true);
      } else {
        await security.completeWithoutProtection();
      }
      if (mounted) {
        widget.onComplete();
      }
    } on Object {
      if (mounted) {
        setState(() {
          _errorMessage =
              'Não foi possível salvar essa configuração. Tente novamente.';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  Future<void> _createRecoveryPhrase() async {
    final password = _passwordController.text;
    final confirmation = _confirmationController.text;
    final validationMessage = AppSecurity.passwordValidationMessage(password);
    if (validationMessage != null) {
      setState(() => _errorMessage = validationMessage);
      return;
    }
    if (password != confirmation) {
      setState(() => _errorMessage = 'As senhas não coincidem.');
      return;
    }

    setState(() {
      _isBusy = true;
      _errorMessage = null;
    });
    try {
      final phrase = await security.createRecoveryPhrase();
      if (!mounted) {
        return;
      }
      setState(() {
        _recoveryPhrase = phrase;
        _stage = _OnboardingStage.recovery;
      });
    } on Object {
      if (mounted) {
        setState(() {
          _errorMessage = 'Não foi possível gerar a frase de recuperação.';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  Future<void> _saveProtection() async {
    final recoveryPhrase = _recoveryPhrase;
    if (recoveryPhrase == null) {
      setState(() => _errorMessage = 'Gere uma nova frase de recuperação.');
      return;
    }
    if (AppSecurity.normalizeRecoveryPhrase(_recoveryController.text) !=
        AppSecurity.normalizeRecoveryPhrase(recoveryPhrase)) {
      setState(() => _errorMessage = 'A frase digitada não corresponde.');
      return;
    }

    setState(() {
      _isBusy = true;
      _errorMessage = null;
    });
    try {
      await security.saveProtection(
        password: _passwordController.text,
        recoveryPhrase: recoveryPhrase,
        enableBiometrics: _wantsBiometrics,
      );
      if (mounted) {
        widget.onComplete();
      }
    } on Object {
      if (mounted) {
        setState(() {
          _errorMessage =
              'Não foi possível ativar a proteção. Tente novamente.';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  Future<void> _copyRecoveryPhrase() async {
    final phrase = _recoveryPhrase;
    if (phrase == null) {
      setState(() => _errorMessage = 'Gere uma nova frase de recuperação.');
      return;
    }

    try {
      await Clipboard.setData(ClipboardData(text: phrase));
      _clipboardClearTimer?.cancel();
      _copiedRecoveryPhrase = phrase;
      _clipboardClearTimer = Timer(const Duration(seconds: 60), () {
        unawaited(_expireCopiedRecoveryPhrase(phrase));
      });
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
              Text('Frase copiada. O app tentará limpá-la em 60 segundos.'),
        ),
      );
    } on PlatformException {
      if (mounted) {
        setState(() {
          _errorMessage =
              'Não foi possível copiar a frase para a área de transferência.';
        });
      }
    } on MissingPluginException {
      if (mounted) {
        setState(() {
          _errorMessage = 'A cópia não está disponível neste dispositivo.';
        });
      }
    }
  }

  Future<void> _expireCopiedRecoveryPhrase(String phrase) async {
    final wasCleared = await _clearClipboardIfUnchanged(phrase);
    if (_copiedRecoveryPhrase == phrase) {
      _copiedRecoveryPhrase = null;
    }
    if (!wasCleared && mounted && _stage == _OnboardingStage.recovery) {
      _showClipboardCleanupWarning();
    }
  }

  Future<void> _continueAfterSavingRecoveryPhrase() async {
    final copiedPhrase = _copiedRecoveryPhrase;
    _clipboardClearTimer?.cancel();
    _clipboardClearTimer = null;

    var clipboardWasCleared = true;
    if (copiedPhrase != null) {
      clipboardWasCleared = await _clearClipboardIfUnchanged(copiedPhrase);
    }
    _copiedRecoveryPhrase = null;
    if (!mounted) {
      return;
    }
    if (!clipboardWasCleared) {
      _showClipboardCleanupWarning();
    }

    _recoveryController.clear();
    setState(() {
      _stage = _OnboardingStage.confirmRecovery;
      _errorMessage = null;
    });
  }

  Future<bool> _clearClipboardIfUnchanged(String phrase) async {
    try {
      final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
      if (clipboardData?.text != phrase) {
        return true;
      }
      await Clipboard.setData(const ClipboardData(text: ''));
      return true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  void _showClipboardCleanupWarning() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content:
            Text('Não foi possível limpar a frase da área de transferência.'),
      ),
    );
  }

  void _back() {
    setState(() {
      _errorMessage = null;
      switch (_stage) {
        case _OnboardingStage.protection:
          _stage = _OnboardingStage.welcome;
        case _OnboardingStage.password:
          _stage = _OnboardingStage.protection;
        case _OnboardingStage.recovery:
          _stage = _OnboardingStage.password;
        case _OnboardingStage.confirmRecovery:
          _stage = _OnboardingStage.recovery;
        case _OnboardingStage.welcome:
          break;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_stage != _OnboardingStage.welcome) ...[
                IconButton(
                  tooltip: 'Voltar',
                  onPressed: _isBusy ? null : _back,
                  icon: const Icon(Icons.arrow_back),
                ),
                const SizedBox(height: 10),
              ] else ...[
                _brandMark(),
                const SizedBox(height: 38),
              ],
              _progressIndicator(),
              const SizedBox(height: 26),
              _stageContent(),
              if (_errorMessage != null) ...[
                const SizedBox(height: 16),
                InfoBox(_errorMessage!, icon: Icons.error_outline),
              ],
              const SizedBox(height: 24),
              ..._stageActions(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _brandMark() {
    return Row(
      children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: AppColors.accentSoft,
            borderRadius: BorderRadius.circular(16),
          ),
          child: const Icon(
            Icons.terminal,
            color: AppColors.accent,
          ),
        ),
        const SizedBox(width: 12),
        Text(
          'REMOTO',
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: 1.7,
              ),
        ),
      ],
    );
  }

  Widget _progressIndicator() {
    final progress = switch (_stage) {
      _OnboardingStage.welcome => 0.2,
      _OnboardingStage.protection => 0.4,
      _OnboardingStage.password => 0.6,
      _OnboardingStage.recovery => 0.8,
      _OnboardingStage.confirmRecovery => 1.0,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        eyebrow('PRIMEIROS PASSOS', color: AppColors.accent),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(99),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 4,
            backgroundColor: AppColors.surfaceHighest,
          ),
        ),
      ],
    );
  }

  Widget _stageContent() {
    return switch (_stage) {
      _OnboardingStage.welcome => _welcomeContent(),
      _OnboardingStage.protection => _protectionContent(),
      _OnboardingStage.password => _passwordContent(),
      _OnboardingStage.recovery => _recoveryContent(),
      _OnboardingStage.confirmRecovery => _confirmRecoveryContent(),
    };
  }

  Widget _welcomeContent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heroIcon(Icons.workspaces_outline),
        const SizedBox(height: 27),
        Text(
          'Seu trabalho,\nsempre por perto.',
          style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                height: 1.05,
                fontWeight: FontWeight.w700,
                letterSpacing: -1.4,
              ),
        ),
        const SizedBox(height: 14),
        Text(
          'Retome sessões do OpenCode pelo celular, com conexão privada e proteção no próprio dispositivo.',
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: AppColors.muted,
                height: 1.5,
              ),
        ),
        const SizedBox(height: 24),
        const _OnboardingBenefit(
          icon: Icons.vpn_lock_outlined,
          title: 'Acesso pela sua rede privada',
          description: 'Conecte suas máquinas pela tailnet.',
        ),
        const SizedBox(height: 10),
        const _OnboardingBenefit(
          icon: Icons.lock_outline,
          title: 'Você escolhe o bloqueio',
          description: 'Use senha, biometria, ambos ou nenhum.',
        ),
      ],
    );
  }

  Widget _protectionContent() {
    final checkingBiometrics = _biometricsAvailable == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heroIcon(Icons.shield_outlined),
        const SizedBox(height: 24),
        Text(
          'Como você quer proteger o app?',
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                height: 1.1,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.8,
              ),
        ),
        const SizedBox(height: 10),
        Text(
          'O bloqueio é opcional e acontece neste dispositivo. Você pode combinar as duas opções.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: AppColors.muted,
                height: 1.45,
              ),
        ),
        const SizedBox(height: 22),
        _ProtectionOption(
          icon: Icons.password,
          title: 'Senha do app',
          description: 'Crie uma senha e uma frase para recuperação.',
          value: _wantsPassword,
          onChanged: _isBusy
              ? null
              : (value) => setState(() {
                    _wantsPassword = value;
                    _errorMessage = null;
                  }),
        ),
        const SizedBox(height: 10),
        _ProtectionOption(
          icon: Icons.face_retouching_natural,
          title: 'Biometria do dispositivo',
          description:
              'Face ID ou Touch ID, com código do dispositivo como fallback.',
          value: _wantsBiometrics,
          onChanged:
              _isBusy || checkingBiometrics || _biometricsAvailable != true
                  ? null
                  : (value) => setState(() {
                        _wantsBiometrics = value;
                        _errorMessage = null;
                      }),
        ),
        if (checkingBiometrics) ...[
          const SizedBox(height: 12),
          const LinearProgressIndicator(),
        ] else if (_biometricsAvailable == false) ...[
          const SizedBox(height: 12),
          const InfoBox(
            'Cadastre Face ID, Touch ID ou outra biometria nas configurações do dispositivo para ativar essa opção.',
          ),
        ],
        const SizedBox(height: 14),
        const InfoBox(
          'Você pode continuar sem proteção e usar o app normalmente.',
          icon: Icons.info_outline,
        ),
      ],
    );
  }

  Widget _passwordContent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heroIcon(Icons.key_outlined),
        const SizedBox(height: 24),
        Text(
          'Crie sua senha',
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -0.8,
              ),
        ),
        const SizedBox(height: 10),
        Text(
          'Use pelo menos ${AppSecurity.minimumPasswordLength} caracteres. A senha não será enviada ao servidor OpenCode.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: AppColors.muted,
                height: 1.45,
              ),
        ),
        const SizedBox(height: 22),
        TextField(
          controller: _passwordController,
          autofocus: true,
          obscureText: !_showPassword,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            labelText: 'Senha',
            prefixIcon: const Icon(Icons.lock_outline),
            suffixIcon: IconButton(
              tooltip: _showPassword ? 'Ocultar senha' : 'Mostrar senha',
              onPressed: () => setState(() => _showPassword = !_showPassword),
              icon: Icon(
                _showPassword ? Icons.visibility_off : Icons.visibility,
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _confirmationController,
          obscureText: !_showConfirmation,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _createRecoveryPhrase(),
          decoration: InputDecoration(
            labelText: 'Confirme a senha',
            prefixIcon: const Icon(Icons.lock_reset),
            suffixIcon: IconButton(
              tooltip: _showConfirmation ? 'Ocultar senha' : 'Mostrar senha',
              onPressed: () => setState(
                () => _showConfirmation = !_showConfirmation,
              ),
              icon: Icon(
                _showConfirmation ? Icons.visibility_off : Icons.visibility,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _recoveryContent() {
    final phrase = _recoveryPhrase;
    final words = phrase?.split(' ') ?? const <String>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heroIcon(Icons.emergency_outlined),
        const SizedBox(height: 24),
        Text(
          'Guarde sua frase de recuperação',
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -0.8,
              ),
        ),
        const SizedBox(height: 10),
        Text(
          'Ela permite redefinir a senha se você esquecê-la. O Remoto não poderá mostrá-la novamente.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: AppColors.muted,
                height: 1.45,
              ),
        ),
        const SizedBox(height: 18),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var index = 0; index < words.length; index++)
                  _RecoveryWord(index: index + 1, word: words[index]),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _copyRecoveryPhrase,
            icon: const Icon(Icons.copy_outlined),
            label: const Text('Copiar frase de recuperação'),
          ),
        ),
        const SizedBox(height: 12),
        const InfoBox(
          'Anote e guarde em local seguro ou copie para um gerenciador de senhas confiável. Outros apps podem acessar ou sincronizar a área de transferência; o Remoto tentará apagar esta frase após 60 segundos ou quando você avançar.',
          icon: Icons.warning_amber_outlined,
        ),
      ],
    );
  }

  Widget _confirmRecoveryContent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heroIcon(Icons.fact_check_outlined),
        const SizedBox(height: 24),
        Text(
          'Confirme que guardou a frase',
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -0.8,
              ),
        ),
        const SizedBox(height: 10),
        Text(
          'Digite as 12 palavras na mesma ordem. Espaços extras e maiúsculas serão ignorados.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: AppColors.muted,
                height: 1.45,
              ),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _recoveryController,
          autofocus: true,
          minLines: 3,
          maxLines: 5,
          autocorrect: false,
          enableSuggestions: false,
          textCapitalization: TextCapitalization.none,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _saveProtection(),
          decoration: const InputDecoration(
            labelText: 'Frase de recuperação',
            hintText: '12 palavras, separadas por espaços',
            alignLabelWithHint: true,
            prefixIcon: Padding(
              padding: EdgeInsets.only(bottom: 40),
              child: Icon(Icons.key),
            ),
          ),
        ),
      ],
    );
  }

  Widget _heroIcon(IconData icon) {
    return Container(
      width: 62,
      height: 62,
      decoration: BoxDecoration(
        color: AppColors.accentSoft,
        borderRadius: BorderRadius.circular(21),
      ),
      child: Icon(icon, color: AppColors.accent, size: 29),
    );
  }

  List<Widget> _stageActions() {
    return switch (_stage) {
      _OnboardingStage.welcome => [
          _primaryButton(
            label: 'Começar',
            icon: Icons.arrow_forward,
            onPressed: _openProtectionStep,
          ),
        ],
      _OnboardingStage.protection => [
          _primaryButton(
            label: _wantsPassword
                ? 'Continuar com senha'
                : _wantsBiometrics
                    ? 'Ativar biometria'
                    : 'Continuar sem proteção',
            icon: _wantsPassword || _wantsBiometrics
                ? Icons.arrow_forward
                : Icons.lock_open_outlined,
            onPressed: _isBusy ? null : _continueFromProtection,
          ),
          if (_wantsPassword || _wantsBiometrics) ...[
            const SizedBox(height: 10),
            Center(
              child: TextButton(
                onPressed: _isBusy ? null : _finishWithoutPassword,
                child: const Text('Pular proteção por agora'),
              ),
            ),
          ],
        ],
      _OnboardingStage.password => [
          _primaryButton(
            label: 'Gerar frase de recuperação',
            icon: Icons.key,
            onPressed: _isBusy ? null : _createRecoveryPhrase,
          ),
        ],
      _OnboardingStage.recovery => [
          _primaryButton(
            label: 'Já salvei em local seguro',
            icon: Icons.check,
            onPressed: _continueAfterSavingRecoveryPhrase,
          ),
        ],
      _OnboardingStage.confirmRecovery => [
          _primaryButton(
            label: 'Ativar proteção',
            icon: Icons.shield,
            onPressed: _isBusy ? null : _saveProtection,
            showProgress: _isBusy,
          ),
        ],
    };
  }

  Widget _primaryButton({
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

class _ProtectionOption extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final bool value;
  final ValueChanged<bool>? onChanged;

  const _ProtectionOption({
    required this.icon,
    required this.title,
    required this.description,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: SwitchListTile.adaptive(
        value: value,
        onChanged: onChanged,
        secondary: Icon(icon, color: AppColors.accent),
        title: Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            description,
            style: const TextStyle(color: AppColors.muted, height: 1.35),
          ),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 4),
      ),
    );
  }
}

class _OnboardingBenefit extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;

  const _OnboardingBenefit({
    required this.icon,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(icon, color: AppColors.accent),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    description,
                    style: const TextStyle(
                      color: AppColors.muted,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecoveryWord extends StatelessWidget {
  final int index;
  final String word;

  const _RecoveryWord({required this.index, required this.word});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(11),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '${index.toString().padLeft(2, '0')}  ',
              style: const TextStyle(color: AppColors.muted, fontSize: 11),
            ),
            TextSpan(
              text: word,
              style: const TextStyle(
                color: AppColors.ink,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
