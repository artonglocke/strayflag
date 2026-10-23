import 'dart:io';

import 'package:strayflag/strayflag.dart';

Future<void> main(List<String> args) async {
  final code = await run(args);
  await stdout.flush();
  exit(code);
}
