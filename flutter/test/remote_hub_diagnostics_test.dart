import 'package:flutter_hbb/remote_hub/diagnostics/log_deletion.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('deleting diagnostics clears the memory log and the native log files',
      () {
    final log = ['event 1', 'event 2'];
    var nativeCalls = 0;
    final failed = deleteDiagnostics(
      clearMemoryLog: log.clear,
      deleteNativeLogs: () {
        nativeCalls++;
        return '';
      },
    );
    expect(failed, isNull);
    expect(log, isEmpty);
    expect(nativeCalls, 1, reason: 'the files on disk are deleted too');
  });

  test('a native failure is reported and the memory log is still cleared',
      () {
    final log = ['event'];
    expect(
        deleteDiagnostics(
            clearMemoryLog: log.clear,
            deleteNativeLogs: () => 'INTERNAL_ERROR: permission denied'),
        isNotNull);
    expect(log, isEmpty);

    log.add('again');
    expect(
        deleteDiagnostics(
            clearMemoryLog: log.clear,
            deleteNativeLogs: () => throw StateError('no library')),
        isNotNull);
    expect(log, isEmpty);
  });
}
