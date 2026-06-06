import 'package:flutter/foundation.dart';
import 'package:tflite_flutter/tflite_flutter.dart' as tfl;

/// Classifies HOG-feature vectors as text (NotAFigurine) vs figurine.
///
/// Returns a confidence score (0.0–1.0) indicating how confident the model is
/// that the input is text (NOT a chess piece figurine).
class NotAFigurineClassifier {
  NotAFigurineClassifier({required tfl.Interpreter interpreter})
      : _interpreter = interpreter;

  final tfl.Interpreter _interpreter;

  /// Classify a HOG feature vector using reconstruction error.
  /// The model is a one-class autoencoder trained on writing elements.
  /// - Low reconstruction error → writing element (text) → high confidence
  /// - High reconstruction error → not writing (figurine) → low confidence
  ///
  /// Returns null if classification fails; otherwise returns a confidence
  /// score (0.0–1.0) for the "NotAFigurine" (text) class.
  double? classifyAsNotFigurine(List<double> features) {
    if (features.length != 1767) return null;

    try {
      final input = [features];
      // Autoencoder outputs reconstructed features [1, 1767]
      final output = List<List<double>>.filled(1, List<double>.filled(1767, 0.0));
      _interpreter.run(input, output);

      if (output.isEmpty || output[0].isEmpty) return null;

      // Compute reconstruction error (MSE)
      final reconstructed = output[0];
      double mseError = 0.0;
      for (int i = 0; i < features.length; i++) {
        final diff = features[i] - reconstructed[i];
        mseError += diff * diff;
      }
      mseError /= features.length;

      // Convert error to confidence: low error → high confidence (text)
      // Use exponential decay: confidence = exp(-error)
      final confidence = (mseError < 100.0)
          ? _expFast(-mseError)
          : 0.0;

      debugPrint(
        '[NotAFigurineClassifier] MSE=$mseError confidence=$confidence',
      );

      return confidence.clamp(0.0, 1.0);
    } catch (e) {
      debugPrint('[NotAFigurineClassifier] Error during classification: $e');
      return null;
    }
  }

  // Fast approximate exponential for values near 0
  static double _expFast(double x) {
    if (x > 0) return 1.0;
    if (x < -20) return 0.0;
    // e^x ≈ 1 + x + x²/2! + x³/3! + ...
    return 1.0 + x + x * x / 2.0 + x * x * x / 6.0 + x * x * x * x / 24.0;
  }

  static Future<NotAFigurineClassifier> fromAsset() async {
    final interpreter = await tfl.Interpreter.fromAsset(
      'assets/models/notafigurine_classifier.tflite',
    );
    return NotAFigurineClassifier(interpreter: interpreter);
  }

  void dispose() {
    _interpreter.close();
  }
}
