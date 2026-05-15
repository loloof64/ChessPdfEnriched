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

  /// No FEN found in text, but the top of the page appears to be mostly a
  /// board diagram image — the real starting position is unknown.
  suspectedDiagram,
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
  });

  final String startFen;
  final FenSource fenSource;
  final List<CachedMove> moves;

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
  );

  Map<String, dynamic> toJson() => {
    'startFen': startFen,
    'fenSource': fenSource.name,
    'moves': moves.map((m) => m.toJson()).toList(),
  };

  /// Return a copy with a new starting FEN and mark it as user-provided.
  PageAnalysis withUserFen(String fen, List<CachedMove> recomputedMoves) =>
      PageAnalysis(
        startFen: fen,
        fenSource: FenSource.userProvided,
        moves: recomputedMoves,
      );
}
