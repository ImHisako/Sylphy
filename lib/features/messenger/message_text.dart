import '../../core/privacy/app_palette.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

// Match links before mentions so user@host and URL fragments stay one token.
final _tokens = RegExp(
  r'(?:[a-z][a-z0-9+.-]*://|www\.|mailto:|javascript:|data:|file:|intent:|sylphy:|sylphy-group-join-v1:)[^\s<>]+'
  r'|(?:[\p{L}\p{N}._%+-]+@)?(?:[\p{L}\p{N}](?:[\p{L}\p{N}-]*[\p{L}\p{N}])?\.)+(?:[\p{L}]{2,63}|xn--[a-z0-9-]+)(?::\d+)?(?:[/#?][^\s<>]*)?'
  r'|(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?(?:[/#?][^\s<>]*)?'
  r'|[@#][\p{L}\p{M}\p{N}_]+',
  unicode: true,
  caseSensitive: false,
);

bool messageContainsLink(String text) => _tokens.allMatches(text).any((match) {
  final token = match.group(0)!;
  return !token.startsWith('@') && !token.startsWith('#');
});

String memberMention(String name) =>
    '@${name.trim().replaceAll(RegExp(r'[^\p{L}\p{M}\p{N}_]+', unicode: true), '_')}';

String _withoutTrailingPunctuation(String token) {
  var end = token.length;
  while (end > 0) {
    final last = token[end - 1];
    if ('.!,;:?"\'»”'.contains(last)) {
      end--;
      continue;
    }
    final opening = {')': '(', ']': '[', '}': '{'}[last];
    final part = token.substring(0, end);
    if (opening != null &&
        last.allMatches(part).length > opening.allMatches(part).length) {
      end--;
      continue;
    }
    break;
  }
  return token.substring(0, end);
}

/// Only web destinations can leave the app, and only after confirmation.
Uri? messageWebUri(String token) {
  token = _withoutTrailingPunctuation(token);
  if (RegExp(
    r'[\s\\\x00-\x1f\x7f\u202a-\u202e\u2066-\u2069]',
  ).hasMatch(token)) {
    return null;
  }
  final explicitWebScheme = RegExp(r'^https?://', caseSensitive: false);
  if (!explicitWebScheme.hasMatch(token) &&
      (token.contains('@') ||
          token.contains('://') ||
          RegExp(
            r'^[a-z][a-z0-9+.-]*:(?!\d)',
            caseSensitive: false,
          ).hasMatch(token))) {
    return null;
  }
  final uri = Uri.tryParse(
    explicitWebScheme.hasMatch(token) ? token : 'https://$token',
  );
  if (uri == null ||
      !{'https', 'http'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return uri;
}

TextSpan messageTextSpan(
  String text, {
  required bool outgoing,
  GestureRecognizer? Function(String token)? recognizerFor,
}) {
  final spans = <InlineSpan>[];
  var end = 0;
  for (final match in _tokens.allMatches(text)) {
    if (match.start > end) {
      spans.add(TextSpan(text: text.substring(end, match.start)));
    }
    final raw = match.group(0)!;
    final mention = raw.startsWith('@') || raw.startsWith('#');
    final token = mention ? raw : _withoutTrailingPunctuation(raw);
    spans.add(
      TextSpan(
        text: token,
        recognizer: recognizerFor?.call(token),
        style: TextStyle(
          color: mention
              ? (outgoing
                    ? AppPalette.color(0xFF006D91)
                    : AppPalette.color(0xFF72DCFF))
              : (outgoing
                    ? AppPalette.color(0xFF1748BD)
                    : AppPalette.color(0xFF82ACFF)),
          fontWeight: FontWeight.w600,
          decoration: mention ? TextDecoration.none : TextDecoration.underline,
        ),
      ),
    );
    if (token.length < raw.length) {
      spans.add(TextSpan(text: raw.substring(token.length)));
    }
    end = match.end;
  }
  if (end < text.length) spans.add(TextSpan(text: text.substring(end)));
  return TextSpan(children: spans);
}

class MessageText extends StatefulWidget {
  const MessageText(
    this.text, {
    super.key,
    required this.outgoing,
    this.style,
    this.onMention,
    this.openUrl,
  });

  final String text;
  final bool outgoing;
  final TextStyle? style;
  final ValueChanged<String>? onMention;
  final Future<bool> Function(Uri uri)? openUrl;

  @override
  State<MessageText> createState() => _MessageTextState();
}

class _MessageTextState extends State<MessageText> {
  final _recognizers = <String, TapGestureRecognizer>{};
  bool _openingLink = false;

  @override
  void didUpdateWidget(MessageText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _disposeRecognizers();
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers.values) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  Future<void> _openLink(Uri uri) async {
    if (_openingLink) return;
    _openingLink = true;
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Aprire il link?'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Si aprirà una pagina nel browser esterno:'),
                SizedBox(height: 12),
                SelectableText(
                  uri.toString(),
                  textDirection: TextDirection.ltr,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.pop(context, false),
              child: Text('Annulla'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text('Apri nel browser'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      final opened =
          await (widget.openUrl?.call(uri) ??
              launchUrl(uri, mode: LaunchMode.externalApplication));
      if (!opened) _showOpenError();
    } on Object {
      _showOpenError();
    } finally {
      _openingLink = false;
    }
  }

  void _showOpenError() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Impossibile aprire il link nel browser.')),
    );
  }

  @override
  Widget build(BuildContext context) => Text.rich(
    messageTextSpan(
      widget.text,
      outgoing: widget.outgoing,
      recognizerFor: (token) {
        VoidCallback? onTap;
        if (token.startsWith('@') && widget.onMention != null) {
          onTap = () => widget.onMention?.call(token);
        } else if (!token.startsWith('#')) {
          final uri = messageWebUri(token);
          if (uri != null) onTap = () => _openLink(uri);
        }
        if (onTap == null) return null;
        return (_recognizers[token] ??= TapGestureRecognizer())..onTap = onTap;
      },
    ),
    style: widget.style,
  );
}
