/// Masks addresses, host names and device labels in an exported diagnostics
/// bundle (plan 18.1). Applied by default before anything leaves the device.
final _ipv4 = RegExp(r'\b(?:\d{1,3}\.){3}\d{1,3}\b');
// Full form needs 5+ groups so clock times like 12:34:56 stay readable.
final _ipv6 = RegExp(r'\b(?:[0-9a-fA-F]{1,4}:){4,7}[0-9a-fA-F]{1,4}\b|'
    r'\b[0-9a-fA-F]{1,4}(?::[0-9a-fA-F]{1,4})*::(?:[0-9a-fA-F]{1,4}(?::[0-9a-fA-F]{1,4})*)?');
final _hostName = RegExp(r'\b[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+)*\.ts\.net\b');

String redactDiagnostics(String text, {Iterable<String> labels = const []}) {
  var out = text;
  final sorted = labels.where((l) => l.isNotEmpty).toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  for (final label in sorted) {
    out = out.replaceAll(label, '<label>');
  }
  return out
      .replaceAll(_hostName, '<host>')
      .replaceAll(_ipv6, '<ip>')
      .replaceAll(_ipv4, '<ip>');
}
