import 'dart:math' as math;
import 'dart:typed_data';

/// HOG (Histogram of Oriented Gradients) feature extractor.
///
/// Parameters match the Python training notebook exactly:
///   imageSize      = 32×32 (glyph resized before extraction)
///   orientations   = 9
///   pixelsPerCell  = 4×4
///   cellsPerBlock  = 2×2
///   blockNorm      = L2-Hys
///   extraFeatures  = [width/height, mean_gray, std_gray]
///
/// For a 32×32 input:
///   cells  = 8×8
///   blocks = 7×7
///   HOG    = 7×7×4×9 = 1764 values
///   total  = 1764 + 3 = 1767 floats  (= [featureDim])
class HogExtractor {
  static const int imageSize     = 32;
  static const int _orientations = 9;
  static const int _pxPerCell    = 4;
  static const int _cpb          = 2; // cells per block (each dimension)
  static const int _nCells       = imageSize ~/ _pxPerCell;          // 8
  static const int _nBlocks      = _nCells - _cpb + 1;               // 7
  static const int _blockSize    = _cpb * _cpb * _orientations;      // 36
  static const int featureDim    = _nBlocks * _nBlocks * _blockSize + 3; // 1767

  /// Extract HOG features from a 32×32 grayscale image.
  ///
  /// [gray]  — Float32List of length [imageSize]×[imageSize], row-major,
  ///           values in [0, 1].  Produced by [_cropAndResize32] or similar.
  /// [origW] — Width of the original glyph crop (before resize to 32×32).
  /// [origH] — Height of the original glyph crop.
  ///
  /// Returns a [Float32List] of length [featureDim] (1767).
  static Float32List extract(Float32List gray, int origW, int origH) {
    assert(gray.length == imageSize * imageSize,
        'Expected ${imageSize * imageSize} pixels, got ${gray.length}');

    // ── 1. Gradients — central difference, zero at boundary ───────────────
    // gx[y,x] = gray[y, x+1] - gray[y, x-1]   (0 at x=0 and x=imageSize-1)
    // gy[y,x] = gray[y+1, x] - gray[y-1, x]   (0 at y=0 and y=imageSize-1)
    final gx = Float64List(imageSize * imageSize);
    final gy = Float64List(imageSize * imageSize);

    for (int y = 0; y < imageSize; y++) {
      for (int x = 1; x < imageSize - 1; x++) {
        gx[y * imageSize + x] =
            gray[y * imageSize + x + 1] - gray[y * imageSize + x - 1];
      }
    }
    for (int y = 1; y < imageSize - 1; y++) {
      for (int x = 0; x < imageSize; x++) {
        gy[y * imageSize + x] =
            gray[(y + 1) * imageSize + x] - gray[(y - 1) * imageSize + x];
      }
    }

    // ── 2. Magnitude and unsigned angle [0°, 180°) ────────────────────────
    final mag = Float64List(imageSize * imageSize);
    final ang = Float64List(imageSize * imageSize);
    const toDeg = 180.0 / math.pi;

    for (int i = 0; i < imageSize * imageSize; i++) {
      mag[i] = math.sqrt(gx[i] * gx[i] + gy[i] * gy[i]);
      // atan2 → (-π, π] → degrees → fold to [0°, 180°)
      // Note: Dart's % can return negative for negative left-hand side,
      // so the explicit `if (a < 0) a += 180` handles that correctly.
      double a = math.atan2(gy[i], gx[i]) * toDeg;
      a = a % 180.0;
      if (a < 0) a += 180.0;
      ang[i] = a;
    }

    // ── 3. Cell histograms ─────────────────────────────────────────────────
    const double binWidth = 180.0 / _orientations; // 20°
    // Flat array: [cellY * _nCells + cellX, orientation]
    final cellHist = Float64List(_nCells * _nCells * _orientations);

    for (int y = 0; y < imageSize; y++) {
      final cy = y ~/ _pxPerCell;
      for (int x = 0; x < imageSize; x++) {
        final cx   = x ~/ _pxPerCell;
        final m    = mag[y * imageSize + x];
        final bf   = ang[y * imageSize + x] / binWidth; // [0, _orientations)
        final b0   = bf.toInt() % _orientations;
        final b1   = (b0 + 1) % _orientations;
        final t    = bf - bf.toInt(); // fractional part
        final base = (cy * _nCells + cx) * _orientations;
        cellHist[base + b0] += m * (1.0 - t);
        cellHist[base + b1] += m * t;
      }
    }

    // ── 4. Block normalization (L2-Hys) ───────────────────────────────────
    const double eps  = 1e-5;
    const double eps2 = eps * eps;
    final block  = Float64List(_blockSize);
    final hogOut = Float64List(_nBlocks * _nBlocks * _blockSize);
    int outIdx = 0;

    for (int by = 0; by < _nBlocks; by++) {
      for (int bx = 0; bx < _nBlocks; bx++) {
        // Collect the 2×2 cells belonging to this block
        int bi = 0;
        for (int cy = by; cy < by + _cpb; cy++) {
          for (int cx = bx; cx < bx + _cpb; cx++) {
            final base = (cy * _nCells + cx) * _orientations;
            for (int o = 0; o < _orientations; o++) {
              block[bi++] = cellHist[base + o];
            }
          }
        }

        // First L2 pass
        double sum1 = 0;
        for (int i = 0; i < _blockSize; i++) { sum1 += block[i] * block[i]; }
        final norm1 = math.sqrt(sum1 + eps2);
        for (int i = 0; i < _blockSize; i++) {
          block[i] = (block[i] / norm1).clamp(0.0, 0.2);
        }

        // Second L2 pass (re-normalize after clipping)
        double sum2 = 0;
        for (int i = 0; i < _blockSize; i++) { sum2 += block[i] * block[i]; }
        final norm2 = math.sqrt(sum2 + eps2);
        for (int i = 0; i < _blockSize; i++) {
          hogOut[outIdx++] = block[i] / norm2;
        }
      }
    }

    // ── 5. Extra features ─────────────────────────────────────────────────
    double mean = 0;
    for (int i = 0; i < gray.length; i++) { mean += gray[i]; }
    mean /= gray.length;

    double variance = 0;
    for (int i = 0; i < gray.length; i++) {
      final d = gray[i] - mean;
      variance += d * d;
    }
    final std = math.sqrt(variance / gray.length);

    // ── 6. Assemble result ────────────────────────────────────────────────
    final result = Float32List(featureDim);
    for (int i = 0; i < hogOut.length; i++) { result[i] = hogOut[i]; }
    result[hogOut.length]     = origW / math.max(origH, 1);
    result[hogOut.length + 1] = mean;
    result[hogOut.length + 2] = std;

    return result;
  }
}
