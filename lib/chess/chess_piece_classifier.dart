import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

class ChessPieceClassifierException implements Exception {
  final String message;
  const ChessPieceClassifierException(this.message);
  @override
  String toString() => message;
}

/// Classifies chess piece types in individual board squares using TensorFlow Lite.
///
/// Model input:  [1, 64, 64, 3] float32 (normalized to [0,1])
/// Model output: [1, 13] float32 softmax (13 piece classes)
///
/// Classes: 0=empty, 1=wP, 2=wN, 3=wB, 4=wR, 5=wQ, 6=wK,
///                   7=bP, 8=bN, 9=bB, 10=bR, 11=bQ, 12=bK
class ChessPieceClassifier {
  static const List<String> classes = [
    'empty',
    'wP',
    'wN',
    'wB',
    'wR',
    'wQ',
    'wK',
    'bP',
    'bN',
    'bB',
    'bR',
    'bQ',
    'bK',
  ];

  static const int _inputSize = 64; // 64x64 square images
  static const String _modelAsset = 'assets/models/chess_pieces.tflite';

  late Interpreter _interpreter;
  bool _isLoaded = false;

  /// Load the TFLite model from assets.
  /// Throws a [ChessPieceClassifierException] if the model cannot be loaded.
  static Future<ChessPieceClassifier> load({String? debugLogFile}) async {
    final classifier = ChessPieceClassifier._();
    try {
      classifier._interpreter = await Interpreter.fromAsset(_modelAsset);
      classifier._isLoaded = true;
      _log(debugLogFile, '[ChessPieceClassifier] model loaded successfully');
      return classifier;
    } catch (e) {
      throw ChessPieceClassifierException(
        'Failed to load TFLite model.\n'
        'Make sure libtensorflowlite_c-linux.so is built and placed in the '
        'blobs/ folder (see README).\n'
        'Underlying error: $e',
      );
    }
  }

  ChessPieceClassifier._();

  /// Appends [message] to [logFile] if set, otherwise falls back to
  /// [debugPrint]. Terminal/logcat output gets truncated or drops lines
  /// under heavy volume — writing straight to a file never does.
  static void _log(String? logFile, String message) {
    if (logFile == null) {
      debugPrint(message);
      return;
    }
    try {
      File(logFile).writeAsStringSync('$message\n', mode: FileMode.append);
    } catch (e) {
      debugPrint('[ChessPieceClassifier] failed to write log: $e');
    }
  }

  /// Classify 64 square images and return full score vectors (64 × 13).
  ///
  /// Returns null if not loaded or wrong input count.
  List<List<double>>? classify64SquaresWithScores(List<Float32List> squareImages) {
    if (!_isLoaded || squareImages.length != 64) return null;

    final scores = <List<double>>[];
    for (int i = 0; i < 64; i++) {
      final inputTensor = _reshapeToInputShape(squareImages[i]);
      final output = [List<double>.filled(13, 0.0)];
      _interpreter.run(inputTensor, output);
      scores.add(List<double>.unmodifiable(output[0]));
    }
    return scores;
  }

  /// Classify 64 square images (one for each board square).
  ///
  /// [squareImages]: list of 64 Float32Lists, each 64×64×3 pixels normalized [0,1]
  /// Returns: list of 64 class strings ('empty', 'wP', etc.)
  ///          If not loaded: returns null.
  List<String>? classify64Squares(List<Float32List> squareImages) {
    final scores = classify64SquaresWithScores(squareImages);
    if (scores == null) return null;
    return scores.map<String>(argmaxClass).toList();
  }

  /// Reshape a single 64×64×3 image to [1, 64, 64, 3] batch format for the model.
  static List<dynamic> _reshapeToInputShape(Float32List imagePixels) {
    final batch = List<List<List<List<double>>>>.generate(
      1,
      (_) => List<List<List<double>>>.generate(
        _inputSize,
        (y) => List<List<double>>.generate(
          _inputSize,
          (x) => List<double>.filled(3, 0.0),
        ),
      ),
    );

    int idx = 0;
    for (int y = 0; y < _inputSize; y++) {
      for (int x = 0; x < _inputSize; x++) {
        for (int c = 0; c < 3; c++) {
          batch[0][y][x][c] = imagePixels[idx++];
        }
      }
    }

    return batch;
  }

  /// Get the class name with the highest logit score.
  static String argmaxClass(List<double> logits) {
    int maxIdx = 0;
    double maxVal = logits[0];
    for (int i = 1; i < logits.length; i++) {
      if (logits[i] > maxVal) {
        maxVal = logits[i];
        maxIdx = i;
      }
    }
    return classes[maxIdx];
  }

  void dispose() {
    if (_isLoaded) {
      _interpreter.close();
      _isLoaded = false;
    }
  }
}
