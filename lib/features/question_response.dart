import 'package:flutter/material.dart';
import '../core/models.dart';
import 'design.dart';

class QuestionResponseSheet extends StatefulWidget {
  final Json form;

  const QuestionResponseSheet({super.key, required this.form});

  @override
  State<QuestionResponseSheet> createState() => _QuestionResponseSheetState();
}

class _QuestionResponseSheetState extends State<QuestionResponseSheet> {
  final formKey = GlobalKey<FormState>();
  final Map<String, dynamic> answers = {};
  final Map<String, Set<String>> selections = {};
  final Map<String, TextEditingController> controllers = {};
  late final List<Json> fields;
  int currentFieldIndex = 0;
  String? multiselectError;

  @override
  void initState() {
    super.initState();
    fields = objects(widget.form['fields'])
        .where((field) => field['hidden'] != true)
        .toList();
    for (final field in fields) {
      final fieldKey = _fieldKey(field);
      final fieldType = field['type'];
      final defaultValue = field['default'];
      if (fieldType == 'boolean') {
        answers[fieldKey] = defaultValue == true;
      } else if (fieldType == 'multiselect') {
        final defaults = defaultValue is List
            ? defaultValue.whereType<String>().toSet()
            : <String>{};
        selections[fieldKey] = defaults;
        controllers[fieldKey] = TextEditingController();
      } else if (_isChoiceField(field)) {
        final options = objects(field['options']);
        if (defaultValue is String &&
            options.any((option) => option['value'] == defaultValue)) {
          answers[fieldKey] = defaultValue;
        } else {
          controllers[fieldKey] = TextEditingController(
            text: defaultValue is String ? defaultValue : '',
          );
        }
      } else {
        controllers[fieldKey] = TextEditingController(
          text: defaultValue == null ? '' : defaultValue.toString(),
        );
      }
    }
  }

  @override
  void dispose() {
    for (final controller in controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  String _fieldKey(Json field) => field['key'] as String;

  TextEditingController _controller(String fieldKey) => controllers[fieldKey]!;

  bool _hasOptions(Json field) =>
      field['options'] is List && (field['options'] as List).isNotEmpty;

  bool _isChoiceField(Json field) =>
      field['type'] == 'string' && _hasOptions(field);

  Widget _buildField(Json field) {
    final fieldKey = _fieldKey(field);
    final fieldType = field['type'];
    if (fieldType == 'boolean') {
      return SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(field['title'] as String? ?? fieldKey),
        subtitle: field['description'] is String
            ? Text(field['description'] as String)
            : null,
        value: answers[fieldKey] as bool? ?? false,
        onChanged: (value) => setState(() => answers[fieldKey] = value),
      );
    }

    if (fieldType == 'multiselect') {
      final selected = selections[fieldKey] ?? <String>{};
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final option in objects(field['options']))
                FilterChip(
                  label: Text(option['label'] as String? ?? ''),
                  selected: selected.contains(option['value']),
                  onSelected: (isSelected) => setState(() {
                    final optionValue = option['value'] as String;
                    if (isSelected) {
                      selected.add(optionValue);
                    } else {
                      selected.remove(optionValue);
                    }
                    multiselectError = null;
                  }),
                ),
            ],
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _controller(fieldKey),
            minLines: 1,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Ou escreva outra resposta',
              hintText: 'Sua opção',
              alignLabelWithHint: true,
            ),
            onChanged: (_) => setState(() => multiselectError = null),
          ),
          if (multiselectError != null) ...[
            const SizedBox(height: 6),
            Text(
              multiselectError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      );
    }

    if (_isChoiceField(field)) {
      final current = answers[fieldKey] as String?;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final option in objects(field['options']))
            _choiceOption(
              fieldKey: fieldKey,
              option: option,
              selectedValue: current,
            ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _controller(fieldKey),
            minLines: 1,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Ou escreva sua própria resposta',
              hintText: 'Digite uma resposta',
              alignLabelWithHint: true,
            ),
            onChanged: (value) {
              if (value.trim().isNotEmpty && answers[fieldKey] != null) {
                setState(() => answers[fieldKey] = null);
              }
            },
            validator: (value) {
              if (field['required'] == true &&
                  answers[fieldKey] is! String &&
                  (value?.trim().isEmpty ?? true)) {
                return 'Escolha uma opção ou escreva sua resposta.';
              }
              return null;
            },
          ),
        ],
      );
    }

    final isNumeric = fieldType == 'number' || fieldType == 'integer';
    final description = field['description'] as String?;
    final url = field['url'] as String?;
    return TextFormField(
      controller: _controller(fieldKey),
      minLines: 1,
      maxLines: fieldType == 'external' ? 3 : 5,
      keyboardType: isNumeric
          ? const TextInputType.numberWithOptions(decimal: true)
          : TextInputType.text,
      decoration: InputDecoration(
        labelText: 'Sua resposta',
        helperText: fieldType == 'external'
            ? '${description ?? ''} ${url ?? ''}'.trim()
            : field['placeholder'] as String?,
        hintText: field['placeholder'] as String?,
        alignLabelWithHint: true,
      ),
      validator: (value) {
        final text = value?.trim() ?? '';
        if (field['required'] == true && text.isEmpty) {
          return 'Este campo é obrigatório.';
        }
        if (text.isNotEmpty &&
            fieldType == 'number' &&
            num.tryParse(text) == null) {
          return 'Informe um número válido.';
        }
        if (text.isNotEmpty &&
            fieldType == 'integer' &&
            int.tryParse(text) == null) {
          return 'Informe um número inteiro.';
        }
        return null;
      },
    );
  }

  Widget _choiceOption({
    required String fieldKey,
    required Json option,
    required String? selectedValue,
  }) {
    final value = option['value'] as String;
    final label = option['label'] as String? ?? value;
    final description = option['description'] as String?;
    final selected = selectedValue == value;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected ? AppColors.accentSoft : AppColors.surfaceRaised,
        borderRadius: smallRadius,
        child: InkWell(
          borderRadius: smallRadius,
          onTap: () => setState(() {
            answers[fieldKey] = value;
            _controller(fieldKey).clear();
          }),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: smallRadius,
              border: Border.all(
                color: selected ? AppColors.accent : AppColors.outline,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: selected ? AppColors.accent : AppColors.muted,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                      if (description?.isNotEmpty == true) ...[
                        const SizedBox(height: 3),
                        Text(
                          description!,
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: AppColors.muted,
                                  ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  bool _validateCurrentField() {
    if (!(formKey.currentState?.validate() ?? false)) {
      return false;
    }
    final field = fields[currentFieldIndex];
    if (field['type'] != 'multiselect') {
      return true;
    }
    final fieldKey = _fieldKey(field);
    final customAnswer = _controller(fieldKey).text.trim();
    final selected = selections[fieldKey] ?? <String>{};
    final selectedCount = selected.length +
        (customAnswer.isNotEmpty && !selected.contains(customAnswer) ? 1 : 0);
    final minimum =
        field['minItems'] as int? ?? (field['required'] == true ? 1 : 0);
    if (selectedCount < minimum) {
      setState(() {
        multiselectError =
            'Selecione ou escreva pelo menos $minimum resposta(s).';
      });
      return false;
    }
    return true;
  }

  void _advance() {
    if (fields.isEmpty) {
      Navigator.pop(context);
      return;
    }
    if (!_validateCurrentField()) {
      return;
    }
    FocusScope.of(context).unfocus();
    if (currentFieldIndex < fields.length - 1) {
      setState(() {
        currentFieldIndex++;
        multiselectError = null;
      });
      return;
    }
    _submit();
  }

  void _submit() {
    if (fields.isEmpty) {
      Navigator.pop(context);
      return;
    }
    if (!_validateCurrentField()) {
      return;
    }
    final result = <String, dynamic>{};
    for (final field in fields) {
      final fieldKey = _fieldKey(field);
      final fieldType = field['type'];
      if (fieldType == 'boolean') {
        result[fieldKey] = answers[fieldKey] as bool? ?? false;
      } else if (fieldType == 'multiselect') {
        final values = (selections[fieldKey] ?? <String>{}).toList();
        final customAnswer = _controller(fieldKey).text.trim();
        if (customAnswer.isNotEmpty && !values.contains(customAnswer)) {
          values.add(customAnswer);
        }
        if (values.isNotEmpty) {
          result[fieldKey] = values;
        }
      } else if (_isChoiceField(field)) {
        final customAnswer = _controller(fieldKey).text.trim();
        final selected =
            customAnswer.isNotEmpty ? customAnswer : answers[fieldKey];
        if (selected is String) {
          result[fieldKey] = selected;
        }
      } else {
        final text = _controller(fieldKey).text.trim();
        if (text.isEmpty) {
          continue;
        }
        if (fieldType == 'number') {
          result[fieldKey] = num.parse(text);
        } else if (fieldType == 'integer') {
          result[fieldKey] = int.parse(text);
        } else {
          result[fieldKey] = text;
        }
      }
    }
    Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final availableHeight =
        mediaQuery.size.height - mediaQuery.viewInsets.bottom;
    final currentField =
        fields.isEmpty ? <String, dynamic>{} : fields[currentFieldIndex];
    final currentTitle = currentField['title'] as String? ??
        currentField['key'] as String? ??
        '';
    final formTitle = widget.form['title'] as String? ?? 'Responder ao agente';
    final formDescription = widget.form['description'] as String?;

    return SizedBox(
      height: availableHeight * .94,
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 14, 4),
              child: Row(
                children: [
                  const Icon(Icons.forum_outlined, color: AppColors.warning),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'PERGUNTA DO AGENTE',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                            color: AppColors.warning,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1,
                          ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Fechar sem responder',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            if (fields.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    Expanded(
                      child: LinearProgressIndicator(
                        value: (currentFieldIndex + 1) / fields.length,
                        minHeight: 4,
                        borderRadius: BorderRadius.circular(8),
                        color: AppColors.accent,
                        backgroundColor: AppColors.surfaceHighest,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      '${currentFieldIndex + 1} de ${fields.length}',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: AppColors.muted,
                          ),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: fields.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('Este formulário não contém perguntas.'),
                      ),
                    )
                  : Form(
                      key: formKey,
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(22, 18, 22, 20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              formTitle,
                              style: Theme.of(context)
                                  .textTheme
                                  .headlineSmall
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            if (formDescription?.trim().isNotEmpty == true) ...[
                              const SizedBox(height: 8),
                              Text(
                                formDescription!,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodyMedium
                                    ?.copyWith(color: AppColors.muted),
                              ),
                            ],
                            const SizedBox(height: 22),
                            Text(
                              currentTitle,
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            if ((currentField['description'] as String?)
                                    ?.trim()
                                    .isNotEmpty ==
                                true) ...[
                              const SizedBox(height: 8),
                              Text(
                                currentField['description'] as String,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodyMedium
                                    ?.copyWith(color: AppColors.muted),
                              ),
                            ],
                            const SizedBox(height: 18),
                            _buildField(currentField),
                          ],
                        ),
                      ),
                    ),
            ),
            const Divider(height: 1, color: AppColors.outline),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 10, 18, 12),
                child: Row(
                  children: [
                    if (currentFieldIndex > 0)
                      TextButton.icon(
                        onPressed: () {
                          FocusScope.of(context).unfocus();
                          setState(() {
                            currentFieldIndex--;
                            multiselectError = null;
                          });
                        },
                        icon: const Icon(Icons.arrow_back),
                        label: const Text('Voltar'),
                      ),
                    const Spacer(),
                    FilledButton.icon(
                      onPressed: _advance,
                      icon: Icon(
                        currentFieldIndex < fields.length - 1
                            ? Icons.arrow_forward
                            : Icons.send,
                      ),
                      label: Text(
                        currentFieldIndex < fields.length - 1
                            ? 'Próxima pergunta'
                            : 'Enviar resposta',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
