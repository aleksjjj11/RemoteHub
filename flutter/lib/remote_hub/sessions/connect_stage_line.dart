import 'package:flutter/material.dart';

import 'remote_hub_connector.dart';

/// The current [ConnectStage] of a connect with its cancel action (plan
/// 12.3); shown on the device card until the connect ends.
class ConnectStageLine extends StatelessWidget {
  const ConnectStageLine(
      {super.key, required this.stage, required this.onCancel, this.failure});

  final ConnectStage stage;
  final VoidCallback onCancel;

  /// The last failed dial while the connection is still being secured.
  final DialFailed? failure;

  String get _text {
    final f = failure;
    if (f == null) return stage.label;
    final reason = f.code?.userMessage ?? 'The connection failed.';
    return f.isFinal ? reason : '${stage.label} (retrying: $reason)';
  }

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      if (stage != ConnectStage.connected && !(failure?.isFinal ?? false))
        const SizedBox.square(
            dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
      const SizedBox(width: 8),
      Expanded(child: Text(_text)),
      TextButton(onPressed: onCancel, child: const Text('Cancel')),
    ]);
  }
}
