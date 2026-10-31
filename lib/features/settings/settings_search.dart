import 'package:flutter/material.dart';

class SettingsSearchEntry {
  const SettingsSearchEntry(
    this.id,
    this.sectionId,
    this.title, [
    this.keywords = '',
  ]);

  final String id;
  final String sectionId;
  final String title;
  final String keywords;

  bool matches(String query) =>
      matchesSettingsSearch('$title $keywords', query);
}

bool matchesSettingsSearch(String text, String query) {
  String normalize(String value) => value
      .toLowerCase()
      .replaceAll(RegExp('[àáâä]'), 'a')
      .replaceAll(RegExp('[èéêë]'), 'e')
      .replaceAll(RegExp('[ìíîï]'), 'i')
      .replaceAll(RegExp('[òóôö]'), 'o')
      .replaceAll(RegExp('[ùúûü]'), 'u')
      .replaceAll(RegExp('[^a-z0-9]+'), ' ')
      .trim();
  final haystack = normalize(text);
  return normalize(
    query,
  ).split(' ').where((word) => word.isNotEmpty).every(haystack.contains);
}

/// Shared only within one settings page; other uses of these controls need no
/// search controller and retain their normal appearance.
class SettingsSearchScope extends InheritedWidget {
  const SettingsSearchScope({
    super.key,
    required this.anchors,
    required this.selectedId,
    required super.child,
  });

  final Map<String, GlobalKey> anchors;
  final String? selectedId;

  @override
  bool updateShouldNotify(SettingsSearchScope oldWidget) =>
      anchors != oldWidget.anchors || selectedId != oldWidget.selectedId;
}

class SettingsSearchTarget extends StatelessWidget {
  const SettingsSearchTarget({
    super.key,
    required this.id,
    required this.child,
  });

  final String id;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<SettingsSearchScope>();
    if (scope == null) return child;
    final selected = scope.selectedId == id;
    return Ink(
      key: scope.anchors.putIfAbsent(id, () => GlobalKey(debugLabel: id)),
      decoration: BoxDecoration(
        color: selected
            ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.1)
            : null,
        border: selected
            ? Border.all(color: Theme.of(context).colorScheme.primary)
            : null,
        borderRadius: BorderRadius.circular(12),
      ),
      child: child,
    );
  }
}
