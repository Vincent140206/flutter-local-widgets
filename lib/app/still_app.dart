import 'package:flutter/material.dart';

import '../core/theme/still_theme.dart';
import '../features/home/presentation/still_home_page.dart';

class StillApp extends StatelessWidget {
  const StillApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Still',
        debugShowCheckedModeBanner: false,
        theme: buildStillTheme(),
        home: const StillHomePage(),
      );
}
