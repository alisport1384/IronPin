import 'dart:io';

// Preserve the original CLI; source parsing now uses Flutter background compute.
Future<void> main(List<String> args) async {
  final output = args.isEmpty ? 'research/live-smoke.json' : args.first;
  final process = await Process.start(
      'flutter',
      [
        'test',
        'tool/live_sources_test.dart',
        '--concurrency=1',
        '--reporter',
        'expanded',
        '--dart-define=IRONPIN_LIVE_REPORT=$output',
      ],
      mode: ProcessStartMode.inheritStdio);
  exitCode = await process.exitCode;
}
