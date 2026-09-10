import 'package:flutter/material.dart';

// Match links before mentions so user@host and URL fragments stay one token.
final _tokens = RegExp(
  r'(?:[a-z][a-z0-9+.-]*://|www\.|mailto:|sylphy:|sylphy-group-join-v1:)[^\s<>]+'
  r'|(?:[\p{L}\p{N}._%+-]+@)?(?:[\p{L}\p{N}](?:[\p{L}\p{N}-]*[\p{L}\p{N}])?\.)+(?:[\p{L}]{2,63}|xn--[a-z0-9-]+)(?::\d+)?(?:[/#?][^\s<>]*)?'
  r'|(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?(?:[/#?][^\s<>]*)?'
  r'|[@#][\p{L}\p{N}_]+',
  unicode: true,
  caseSensitive: false,
);

bool messageContainsLink(String text) => _tokens.allMatches(text).any((match) {
  final token = match.group(0)!;
  return !token.startsWith('@') && !token.startsWith('#');
});

TextSpan messageTextSpan(String text, {required bool outgoing}) {
  final spans = <InlineSpan>[];
  var end = 0;
  for (final match in _tokens.allMatches(text)) {
    if (match.start > end) {
      spans.add(TextSpan(text: text.substring(end, match.start)));
    }
    final token = match.group(0)!;
    final mention = token.startsWith('@') || token.startsWith('#');
    spans.add(
      TextSpan(
        text: token,
        style: TextStyle(
          color: mention
              ? (outgoing ? const Color(0xFF006D91) : const Color(0xFF72DCFF))
              : (outgoing ? const Color(0xFF1748BD) : const Color(0xFF82ACFF)),
          fontWeight: FontWeight.w600,
          decoration: mention ? TextDecoration.none : TextDecoration.underline,
        ),
      ),
    );
    end = match.end;
  }
  if (end < text.length) spans.add(TextSpan(text: text.substring(end)));
  return TextSpan(children: spans);
}
