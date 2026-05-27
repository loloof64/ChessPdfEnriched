import 'package:flutter/foundation.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import 'hog_extractor.dart';

/// Classifies chess piece glyphs cropped from a rendered PDF page.
///
/// Used to auto-build the fontMap for PDFs that use figurine fonts.
///
/// Model input:  [1, 1767] float32 — HOG feature vector (see HogExtractor)
/// Model output: [1, 6]    float32 — softmax probabilities
/// Classes (index):  0=K  1=Q  2=R  3=B  4=N  5=NotAFigurine (rejection class)
class FigurineClassifier {
  static const List<String> classes = ['K', 'Q', 'R', 'B', 'N', 'NotAFigurine'];

  /// Length of the HOG feature vector expected by the model.
  static const int inputSize = HogExtractor.featureDim; // 1767

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
      debugPrint(
          '[FigurineClassifier] model loaded (HOG+MLP, input=${inputSize}d)');
      return c;
    } catch (e) {
      throw StateError('[FigurineClassifier] failed to load model: $e');
    }
  }

  /// Classify a single glyph.
  ///
  /// Returns the piece letter ('K', 'Q', 'R', 'B', 'N'), or null if the
  /// model is not loaded or the top prediction is the NotAFigurine class.
  String? classify(Float32List features) {
    if (!_isLoaded) return null;
    final scores = _run(features);
    final idx = _argmax(scores);
    if (classes[idx] == 'NotAFigurine') return null;
    return classes[idx];
  }

  /// Like [classify] but also returns the confidence score.
  /// Returns null if the model is not loaded or if the top prediction is
  /// the NotAFigurine rejection class.
  (String piece, double confidence)? classifyWithConfidence(
      Float32List features) {
    if (!_isLoaded) return null;
    final scores = _run(features);
    final idx = _argmax(scores);
    if (classes[idx] == 'NotAFigurine') return null;
    return (classes[idx], scores[idx]);
  }

  List<double> _run(Float32List features) {
    assert(features.length == inputSize,
        'Expected $inputSize features, got ${features.length}');

    // Input tensor shape: [1, 1767]
    final input = [features.toList()];
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
