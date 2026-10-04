import 'package:flutter/material.dart';

import 'keys.dart';
import 'widgets.dart';

class MenuOption {
  const MenuOption(this.label, this.action);

  final String label;
  final VoidCallback action;
}

/// A small list of actions for the Menu key, driven by the remote: Up/Down,
/// OK runs one, Back or Menu closes.
Future<void> showOptionsMenu(BuildContext context, String title, List<MenuOption> options) =>
    showDialog<void>(context: context, barrierColor: Colors.black54, builder: (_) => _OptionsMenu(title, options));

class _OptionsMenu extends StatefulWidget {
  const _OptionsMenu(this.title, this.options);

  final String title;
  final List<MenuOption> options;

  @override
  State<_OptionsMenu> createState() => _OptionsMenuState();
}

class _OptionsMenuState extends State<_OptionsMenu> {
  int _selected = 0;

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (!isPress(event)) return KeyEventResult.handled;
    switch (remoteKey(event)) {
      case RemoteKey.up:
        setState(() => _selected = (_selected - 1).clamp(0, widget.options.length - 1));
      case RemoteKey.down:
        setState(() => _selected = (_selected + 1).clamp(0, widget.options.length - 1));
      case RemoteKey.ok:
        Navigator.of(context).pop();
        widget.options[_selected].action();
      case RemoteKey.back || RemoteKey.menu:
        Navigator.of(context).pop();
      default:
        break;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Material(
        type: MaterialType.transparency,
        child: Center(
          child: Container(
            width: 640,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(color: Tv.panel, borderRadius: BorderRadius.circular(16)),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  widget.title,
                  style: const TextStyle(fontSize: Tv.body, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 16),
                for (final (i, option) in widget.options.indexed)
                  Container(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                    decoration: BoxDecoration(
                      color: i == _selected ? Tv.accent : Colors.white10,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(option.label, style: const TextStyle(fontSize: Tv.body)),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
