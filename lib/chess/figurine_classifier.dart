import 'package:flutter/foundation.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

/// Classifies chess piece glyphs cropped from a rendered PDF page.
///
/// Used to auto-build the fontMap for PDFs that use figurine fonts.
///
/// Model input:  [1, 32, 32, 1] float32, grayscale, values in [0, 1]
/// Model output: [1, 5]  float32 softmax
/// Classes (index):  0=K  1=Q  2=R  3=B  4=N  (Pawn has no figurine letter)
class FigurineClassifier {
  static const List<String> classes = ['K', 'Q', 'R', 'B', 'N'];

  static const int inputSize = 32;
  static const String _modelAsset = 'assets/models/figurine_classifier.tflite';

  late Interpreter _interpreter;
  bool _isLoaded = false;

  FigurineClassifier._();

  /// Load the TFLite model from assets.
  static Future<FigurineClassifier> load() async {
    final c = FigurineClassifier._();
    try {
      c._interpreter = await Interpreter.fromAsset(_modelAsset);
      c._isLoaded = true;
      debugPrint('[FigurineClassifier] model loaded');
      return c;
    } catch (e) {
      throw StateError('[FigurineClassifier] failed to load model: $e');
    }
  }

  /// Classify a single glyph crop.
  ///
  /// [pixels] — Float32List of length 32×32, grayscale values in [0, 1],
  ///            row-major (top-left first).
  ///
  /// Returns the piece letter ('K', 'Q', 'R', 'B', 'N', or 'P'),
  /// or null if the model is not loaded.
  String? classify(Float32List pixels) {
    if (!_isLoaded) return null;
    final scores = _run(pixels);
    return classes[_argmax(scores)];
  }

  /// Like [classify] but also returns the confidence score.
  (String piece, double confidence)? classifyWithConfidence(Float32List pixels) {
    if (!_isLoaded) return null;
    final scores = _run(pixels);
    final idx = _argmax(scores);
    return (classes[idx], scores[idx]);
  }

  List<double> _run(Float32List pixels) {
    assert(pixels.length == inputSize * inputSize,
        'Expected ${inputSize * inputSize} pixels, got ${pixels.length}');

    // Build [1, 32, 32, 1] input tensor.
    final input = List.generate(
      1,
      (_) => List.generate(
        inputSize,
        (y) => List.generate(
          inputSize,
          (x) => [pixels[y * inputSize + x]],
        ),
      ),
    );

    final output = [List<double>.filled(classes.length, 0.0)];
    _interpreter.run(input, output);
    return output[0];
  }

  static int _argmax(List<double> scores) {
    int best = 0;
    for (int i = 1; i < scores.length; i++) {
      if (scores[i] > scores[best]) best = i;
    }
    return best;
  }

  void dispose() {
    if (_isLoaded) {
      _interpreter.close();
      _isLoaded = false;
    }
  }
}
