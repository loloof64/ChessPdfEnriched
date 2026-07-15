#!/usr/bin/env python3
"""
Standalone script to retrain figurine classifier on book-specific glyph styles.

Workflow:
1. Extract candidate glyphes from PDF via template matching
2. Label candidates (auto + manual correction if needed)
3. Train RandomForest model on HOG features
4. Export as pickle for deployment

Usage:
    python retrain_figurine_classifier.py --pdf path/to/book.pdf --pages 1-50 --output ./new_classifier
"""

import argparse
import os
import sys
from pathlib import Path
import pickle
import numpy as np
from PIL import Image
import cv2
from skimage import transform
from skimage.feature import hog
import glob
from sklearn.ensemble import RandomForestClassifier
import tqdm

try:
    import pdfplumber
    from pdf2image import convert_from_path
    PDF_AVAILABLE = True
except ImportError:
    PDF_AVAILABLE = False
    print("⚠️  PDF libraries not installed. Install with: pip install pdfplumber pdf2image")


# Configuration
IMG_SIZE = 32
HOG_ORIENTATIONS = 9
HOG_PIXELS_PER_CELL = (4, 4)
HOG_CELLS_PER_BLOCK = (2, 2)
PIECE_CLASSES = ['K', 'Q', 'R', 'B', 'N', 'NotAFigurine']
TEMPLATE_MATCH_THRESHOLD = 0.7
DPI = 150


def extract_hog_features(img_gray):
    """Extract HOG features from grayscale image."""
    img_resized = transform.resize(img_gray, (IMG_SIZE, IMG_SIZE), anti_aliasing=True)
    hog_features = hog(
        img_resized,
        orientations=HOG_ORIENTATIONS,
        pixels_per_cell=HOG_PIXELS_PER_CELL,
        cells_per_block=HOG_CELLS_PER_BLOCK,
        feature_vector=True
    )
    # Add aspect ratio
    aspect_ratio = img_gray.shape[1] / max(img_gray.shape[0], 1)
    extra = np.array([aspect_ratio])
    return np.concatenate([hog_features, extra])


def render_pdf_page(pdf_path, page_idx, dpi=150):
    """Render one PDF page to PIL Image."""
    if not PDF_AVAILABLE:
        return None
    try:
        images = convert_from_path(pdf_path, first_page=page_idx+1, last_page=page_idx+1, dpi=dpi)
        return images[0] if images else None
    except Exception as e:
        print(f"Error rendering page {page_idx}: {e}")
        return None


def load_book_templates(glyphs_dir):
    """Load existing labeled glyphs as templates."""
    templates = {}
    if not os.path.exists(glyphs_dir):
        return templates

    for piece in PIECE_CLASSES[:-1]:  # Exclude NotAFigurine for templates
        piece_dir = os.path.join(glyphs_dir, piece)
        templates[piece] = []
        if os.path.exists(piece_dir):
            for img_file in sorted(glob.glob(f'{piece_dir}/*.png')):
                try:
                    img = Image.open(img_file).convert('L')
                    templates[piece].append(np.array(img))
                except Exception as e:
                    print(f"Error loading template {img_file}: {e}")
    return templates


def extract_glyphes_from_pdf(pdf_path, templates, start_page=1, end_page=None, output_dir='./glyphs_extracted'):
    """
    Extract glyph candidates from PDF using template matching.

    Returns list of dicts: {page, piece, bbox, crop, features}
    """
    if not PDF_AVAILABLE:
        print("PDF libraries not available")
        return []

    Path(output_dir).mkdir(exist_ok=True)
    glyphes = []

    with pdfplumber.open(pdf_path) as pdf:
        total_pages = len(pdf.pages)
        if end_page is None:
            end_page = total_pages
        end_page = min(end_page, total_pages)

    print(f"Extracting glyphes from pages {start_page} to {end_page}...")

    for page_idx in tqdm.tqdm(range(start_page - 1, end_page), desc="Pages"):
        page_num = page_idx + 1
        page_image = render_pdf_page(pdf_path, page_idx, dpi=DPI)
        if page_image is None:
            continue

        page_cv = cv2.cvtColor(np.array(page_image), cv2.COLOR_RGB2GRAY)

        for piece_name, template_list in templates.items():
            for template in template_list:
                if template.shape[0] == 0 or template.shape[1] == 0:
                    continue

                result = cv2.matchTemplate(page_cv, template, cv2.TM_CCOEFF_NORMED)
                locs = np.where(result >= TEMPLATE_MATCH_THRESHOLD)
                th, tw = template.shape

                for y, x in zip(locs[0], locs[1]):
                    # Avoid duplicates
                    is_duplicate = any(
                        abs(x - g['bbox'][0]) < tw/2 and abs(y - g['bbox'][1]) < th/2
                        for g in glyphes
                    )
                    if is_duplicate:
                        continue

                    try:
                        crop = page_image.crop((x, y, x + tw, y + th))
                        crop_gray = cv2.cvtColor(np.array(crop), cv2.COLOR_RGB2GRAY)
                        features = extract_hog_features(crop_gray)

                        glyphes.append({
                            'page': page_num,
                            'piece': piece_name,
                            'bbox': (x, y, x + tw, y + th),
                            'crop': crop,
                            'crop_array': crop_gray,
                            'features': features,
                        })
                    except Exception as e:
                        pass

    print(f"Extracted {len(glyphes)} glyphes")
    return glyphes


def save_labeled_glyphes(glyphes, output_dir='./glyphs_labeled'):
    """Save extracted glyphes to disk organized by piece."""
    Path(output_dir).mkdir(exist_ok=True)

    counts = {piece: 0 for piece in PIECE_CLASSES}

    for piece in PIECE_CLASSES:
        piece_dir = os.path.join(output_dir, piece)
        Path(piece_dir).mkdir(exist_ok=True)

    for g in glyphes:
        piece = g['piece']
        counts[piece] += 1
        filename = f'{output_dir}/{piece}/{counts[piece]:04d}.png'
        g['crop'].save(filename)

    print(f"Saved glyphes:")
    for piece in PIECE_CLASSES:
        if counts[piece] > 0:
            print(f"  {piece}: {counts[piece]}")

    return counts


def load_labeled_glyphes(glyphs_dir):
    """Load labeled glyphes from disk."""
    X, y = [], []
    class_to_idx = {piece: i for i, piece in enumerate(PIECE_CLASSES)}

    for piece in PIECE_CLASSES:
        piece_dir = os.path.join(glyphs_dir, piece)
        if not os.path.exists(piece_dir):
            continue

        for img_file in sorted(glob.glob(f'{piece_dir}/*.png')):
            try:
                img = Image.open(img_file).convert('L')
                img_gray = np.array(img)
                features = extract_hog_features(img_gray)
                X.append(features)
                y.append(class_to_idx[piece])
            except Exception as e:
                print(f"Error loading {img_file}: {e}")

    return np.array(X), np.array(y)


def train_random_forest(X, y, output_path='./figurine_classifier.pkl'):
    """Train RandomForest on HOG features and export as pickle."""
    print(f"Training RandomForest on {len(X)} samples, {len(np.unique(y))} classes...")

    # Estimate hyperparameters based on dataset size
    n_samples = len(X)
    n_estimators = max(50, min(200, 50 + (n_samples // 5)))
    max_depth = min(15 + (n_samples // 20), 30)
    min_samples_split = max(2, n_samples // 10)

    clf = RandomForestClassifier(
        n_estimators=n_estimators,
        max_depth=max_depth,
        min_samples_split=min_samples_split,
        random_state=42,
        n_jobs=-1,  # Use all CPU cores
        verbose=1,
    )

    clf.fit(X, y)

    # Save model
    Path(output_path).parent.mkdir(exist_ok=True)
    with open(output_path, 'wb') as f:
        pickle.dump(clf, f)

    # Print accuracy
    accuracy = clf.score(X, y)
    print(f"✅ Model trained with {accuracy:.1%} accuracy")
    print(f"✅ Saved to: {output_path}")
    return True


def main():
    parser = argparse.ArgumentParser(description='Retrain figurine classifier on book-specific styles')
    parser.add_argument('--pdf', required=True, help='Path to PDF')
    parser.add_argument('--pages', default='1-20', help='Pages to process (e.g. "1-50", default: 1-20 for testing)')
    parser.add_argument('--output', default='./classifier_output', help='Output directory')
    parser.add_argument('--skip-extract', action='store_true', help='Skip extraction, use existing glyphes')
    parser.add_argument('--skip-train', action='store_true', help='Skip training (just extract)')

    args = parser.parse_args()

    # Parse page range
    if '-' in args.pages:
        start, end = map(int, args.pages.split('-'))
    else:
        start = end = int(args.pages)

    output_dir = Path(args.output)
    output_dir.mkdir(exist_ok=True)
    glyphes_dir = output_dir / 'glyphes'

    # Step 1: Load templates (from existing labeled glyphes if available)
    print("Loading templates...")
    templates = load_book_templates('./glyphes_labeled')
    if not templates:
        print("❌ No templates found. Run Step 4.6 in the Colab notebook first to crop templates,")
        print("   or create ./glyphes_labeled/{K,Q,R,B,N}/ folders with sample images.")
        return

    print(f"Templates loaded: {sum(len(v) for v in templates.values())} total")

    # Step 2: Extract glyphes from PDF
    if not args.skip_extract:
        if not PDF_AVAILABLE:
            print("❌ PDF libraries not available")
            return
        glyphes = extract_glyphes_from_pdf(args.pdf, templates, start, end, str(glyphes_dir))
        save_labeled_glyphes(glyphes, str(glyphes_dir))
    else:
        print("Skipping extraction, using existing glyphes")

    # Step 3: Train model
    if not args.skip_train:
        X, y = load_labeled_glyphes(str(glyphes_dir))
        if len(X) < 10:
            print(f"❌ Not enough samples: {len(X)} (need >= 10)")
            return

        model_path = output_dir / 'figurine_classifier.pkl'
        train_random_forest(X, y, str(model_path))

        print(f"\n✅ Retrain complete!")
        print(f"   New model: {model_path}")
        print(f"   Next: convert to TFLite or use Dart FFI loader")


if __name__ == '__main__':
    main()
