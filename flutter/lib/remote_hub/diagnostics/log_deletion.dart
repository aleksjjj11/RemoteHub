/// Deletes the Remote Hub diagnostics on the owner's request (plan 18.3):
/// the event log the app keeps in memory and the log files the native
/// logger wrote to disk, of every Remote Hub process.
///
/// [clearMemoryLog] empties the in-memory log; [deleteNativeLogs] removes
/// the files and returns "" or a coded error. The memory log is cleared
/// first and also when the files cannot all be deleted. Returns null when
/// everything was deleted, otherwise the message for the owner.
String? deleteDiagnostics({
  required void Function() clearMemoryLog,
  required String Function() deleteNativeLogs,
}) {
  clearMemoryLog();
  final String error;
  try {
    error = deleteNativeLogs();
  } catch (_) {
    return 'The diagnostic log files could not be deleted.';
  }
  if (error.isEmpty) return null;
  return 'Some diagnostic log files could not be deleted.';
}
