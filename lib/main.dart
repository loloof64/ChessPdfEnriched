import 'dart:ui' as ui;

import 'package:chessground/chessground.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'screens/home_screen.dart';

void main() {
  runApp(const ChessPdfApp());
  // Schedule piece-image preloading for after the first frame so the GTK
  // event loop is running and the platform asset channel is available.
  // We bypass AssetImage.obtainKey (which reads AssetManifest.bin) and load
  // raw PNG bytes directly — this avoids the manifest lookup that fails on
  // Linux desktop.
  WidgetsBinding.instance.addPostFrameCallback((_) => _preloadPieceImages());
}

/// Preloads piece images for the sets used in this app into [ChessgroundImages]
/// so [PieceWidget] always uses the fast [RawImage] path.
Future<void> _preloadPieceImages() async {
  for (final assets in [PieceSet.cburnettAssets]) {
    for (final image in assets.values) {
      if (ChessgroundImages.instance.containsKey(image)) continue;
      try {
        final path = image.package != null
            ? 'packages/${image.package}/${image.assetName}'
            : image.assetName;
        final data = await rootBundle.load(path);
        final bytes = data.buffer.asUint8List();
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        ChessgroundImages.instance.add(image, frame.image);
      } catch (e) {
        debugPrint('[ChessPdf] piece preload failed for ${image.assetName}: $e');
      }
    }
  }
}

class ChessPdfApp extends StatelessWidget {
  const ChessPdfApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Chess PDF Enriched',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey),
      ),
      home: const HomeScreen(),
    );
  }
}
