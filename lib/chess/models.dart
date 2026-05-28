/// Notation type used to parse chess moves in the PDF.
enum NotationMode {
  /// Standard letter-based algebraic notation (SAN): K, Q, R, B, N.
  textSan,

  /// Figurine algebraic notation (FAN): ♔, ♕, ♖, ♗, ♘, ♙.
  figurineFan,
}

/// Where the starting FEN for a page's game came from.
enum FenSource {
  /// Standard chess starting position (fallback when nothing else was found).
  standard,

  /// A FEN string was found as literal text on the page (e.g. "FEN: rnbq…").
  detectedInText,

  /// FEN inherited from the last move of the previous page (game continuation).
  inheritedFromPreviousPage,

  /// User manually provided the FEN through the UI.
  userProvided,

  /// Image gap detected and a game header is present — parser suspects this
  /// diagram shows the starting position of a new game (position unknown).
  suspectedDiagram,

  /// Image gap detected with no game header — parser suspects this is an
  /// intermediate diagram showing the current game state (game continues).
  suspectedIntermediateDiagram,

  /// User explicitly confirmed this diagram is an intermediate position;
  /// the game continues from the inherited or standard starting FEN.
  userConfirmedIntermediate,

  /// User explicitly confirmed this image is not a board diagram at all;
  /// the game continues from the inherited or standard starting FEN.
  userConfirmedNotADiagram,
}

/// A detected figurine glyph with its bounds and classified piece type.
class DetectedFigurine {
  const DetectedFigurine({
    required this.bounds,
    required this.piece,
    required this.confidence,
  });

  /// Position in PDF page coordinates (origin bottom-left, y up).
  final MoveBounds bounds;

  /// Classified piece letter ('K', 'Q', 'R', 'B', 'N').
  final String piece;

  /// TFLite model confidence (0.0–1.0).
  final double confidence;
}

/// Bounding box of a move token in PDF page coordinates.
/// Origin is bottom-left; y increases upward (PDF convention).
class MoveBounds {
  const MoveBounds({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final double left;
  final double top;
  final double right;
  final double bottom;

  factory MoveBounds.fromJson(Map<String, dynamic> json) => MoveBounds(
    left: (json['left'] as num).toDouble(),
    top: (json['top'] as num).toDouble(),
    right: (json['right'] as num).toDouble(),
    bottom: (json['bottom'] as num).toDouble(),
  );

  Map<String, dynamic> toJson() => {
    'left': left,
    'top': top,
    'right': right,
    'bottom': bottom,
  };
}

class CachedMove {
  const CachedMove({
    required this.moveNumber,
    required this.isBlack,
    required this.san,
    required this.rawToken,
    required this.fenBefore,
    required this.fenAfter,
    this.bounds,
  });

  final int moveNumber;
  final bool isBlack;

  /// Standard Algebraic Notation (e.g. "Nf3", "O-O", "e8=Q+").
  final String san;

  /// Original token as it appeared in the PDF (may contain figurine chars or annotations).
  final String rawToken;

  final String fenBefore;
  final String fenAfter;

  /// Position of this move token in the PDF page (PDF coordinate space).
  final MoveBounds? bounds;

  factory CachedMove.fromJson(Map<String, dynamic> json) => CachedMove(
    moveNumber: json['moveNumber'] as int,
    isBlack: json['isBlack'] as bool,
    san: json['san'] as String,
    rawToken: json['rawToken'] as String,
    fenBefore: json['fenBefore'] as String,
    fenAfter: json['fenAfter'] as String,
    bounds:
        json['bounds'] != null
            ? MoveBounds.fromJson(json['bounds'] as Map<String, dynamic>)
            : null,
  );

  Map<String, dynamic> toJson() => {
    'moveNumber': moveNumber,
    'isBlack': isBlack,
    'san': san,
    'rawToken': rawToken,
    'fenBefore': fenBefore,
    'fenAfter': fenAfter,
    if (bounds != null) 'bounds': bounds!.toJson(),
  };
}

class PageAnalysis {
  const PageAnalysis({
    required this.startFen,
    required this.fenSource,
    required this.moves,
    this.header,
  });

  final String startFen;
  final FenSource fenSource;
  final List<CachedMove> moves;

  /// Player-line detected as the game header, e.g. "Alekhine - Duras".
  /// Null when no header was found (e.g. a continuation page).
  final String? header;

  factory PageAnalysis.fromJson(Map<String, dynamic> json) => PageAnalysis(
    startFen: json['startFen'] as String,
    fenSource: FenSource.values.firstWhere(
      (e) => e.name == (json['fenSource'] as String? ?? 'standard'),
      orElse: () => FenSource.standard,
    ),
    moves:
        (json['moves'] as List<dynamic>)
            .map((e) => CachedMove.fromJson(e as Map<String, dynamic>))
            .toList(),
    header: json['header'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'startFen': startFen,
    'fenSource': fenSource.name,
    'moves': moves.map((m) => m.toJson()).toList(),
    if (header != null) 'header': header,
  };

  /// Return a copy with a new starting FEN and mark it as user-provided.
  PageAnalysis withUserFen(String fen, List<CachedMove> recomputedMoves) =>
      PageAnalysis(
        startFen: fen,
        fenSource: FenSource.userProvided,
        moves: recomputedMoves,
        header: header,
      );
}

/// Results from analyzing a PDF page: summary of what was found and processed.
class PageAnalysisResult {
  const PageAnalysisResult({
    required this.pageNumber,
    required this.gameCount,
    required this.moveCount,
    required this.figurinesDetected,
    required this.boardsDetected,
    required this.processingTimeMs,
    this.notationMode,
    this.errors,
  });

  final int pageNumber;
  final int gameCount;
  final int moveCount;
  final int figurinesDetected;
  final int boardsDetected;
  final int processingTimeMs;
  final NotationMode? notationMode;
  final List<String>? errors;

  @override
  String toString() {
    final parts = <String>[
      'Page $pageNumber: $gameCount game(s)',
      '$moveCount move(s)',
    ];
    if (figurinesDetected > 0) {
      parts.add('$figurinesDetected figurine(s)');
    }
    if (boardsDetected > 0) {
      parts.add('$boardsDetected board(s) detected');
    }
    parts.add('${processingTimeMs}ms');
    if (notationMode != null) {
      parts.add('(${notationMode!.name})');
    }
    if (errors != null && errors!.isNotEmpty) {
      parts.add('⚠ ${errors!.length} issue(s)');
    }
    return parts.join(' • ');
  }
}

/// Summary of figurine glyph detection results across all pages.
class FigurineSummary {
  const FigurineSummary({
    required this.totalGlyphsDetected,
    required this.glyphsByPage,
    required this.fontMapEntries,
  });

  final int totalGlyphsDetected;

  /// Detected glyphs per page (pageNum → count).
  final Map<int, int> glyphsByPage;

  /// Resolved character → piece mappings.
  final Map<String, String> fontMapEntries;

  @override
  String toString() => totalGlyphsDetected > 0
      ? '$totalGlyphsDetected figurine glyph(s) detected across ${glyphsByPage.length} page(s) • '
          '${fontMapEntries.length} mapping(s) learned'
      : 'No figurine glyphs detected';
}
