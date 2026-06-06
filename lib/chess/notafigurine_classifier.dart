import 'package:tflite_flutter/tflite_flutter.dart' as tfl;

/// Classifies HOG-feature vectors as text (NotAFigurine) vs figurine.
///
/// Returns a confidence score (0.0–1.0) indicating how confident the model is
/// that the input is text (NOT a chess piece figurine).
class NotAFigurineClassifier {
  NotAFigurineClassifier({required tfl.Interpreter interpreter})
      : _interpreter = interpreter;

  final tfl.Interpreter _interpreter;

  /// Classify a HOG feature vector.
  /// Returns null if classification fails; otherwise returns a confidence
  /// score (0.0–1.0) for the "NotAFigurine" (text) class.
  double? classifyAsNotFigurine(List<double> features) {
    if (features.length != 1767) return null;

    try {
      final input = [features];
      final output = List<List<double>>.filled(1, []);
      _interpreter.run(input, output);

      if (output.isEmpty || output[0].isEmpty) return null;
      // Assuming the model outputs a softmax distribution.
      // Return the first (NotAFigurine) class confidence.
      return output[0][0].clamp(0.0, 1.0);
    } catch (_) {
      return null;
    }
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
