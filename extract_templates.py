#!/usr/bin/env python3
"""
Extract template examples from PDF for retrain bootstrap.

Renders pages and extracts small candidate crops that look like chess pieces.
User then manually labels a few as templates to seed the retrain pipeline.
"""

import os
import sys
from pathlib import Path
import numpy as np
from PIL import Image
import cv2
from pdf2image import convert_from_path
import pdfplumber
import argparse

DPI = 150
IMG_SIZE = 32
MIN_CROP_SIZE = 10      # More lenient (was 15)
MAX_CROP_SIZE = 150     # Larger max (was 80)


def extract_candidates_from_page(page_image, min_size=MIN_CROP_SIZE, max_size=MAX_CROP_SIZE):
    """Extract candidate small crops from a page that might be chess pieces."""
    candidates = []

    # Convert to grayscale and threshold
    page_cv = cv2.cvtColor(np.array(page_image), cv2.COLOR_RGB2GRAY)

    # Find contours
    _, binary = cv2.threshold(page_cv, 127, 255, cv2.THRESH_BINARY_INV)
    contours, _ = cv2.findContours(binary, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)

    for contour in contours:
        x, y, w, h = cv2.boundingRect(contour)

        # Filter by size (chess pieces vary in size; be more lenient)
        aspect_ratio = w / max(h, 1)
        if not (min_size <= w <= max_size and min_size <= h <= max_size):
            continue
        if not (0.3 <= aspect_ratio <= 3.0):  # More lenient aspect ratio (was 0.5-2.0)
            continue

        # Extract crop
        crop = page_image.crop((x, y, x + w, y + h))
        candidates.append({
            'bbox': (x, y, w, h),
            'crop': crop,
            'size': (w, h),
        })

    return candidates


def save_candidates(candidates, output_dir, page_num, max_per_page=50):
    """Save candidate crops to disk for manual inspection."""
    Path(output_dir).mkdir(exist_ok=True)

    # Sort by size (prefer medium sizes)
    sorted_candidates = sorted(
        candidates,
        key=lambda c: abs(np.mean(c['size']) - 40)  # Prefer ~40px size
    )[:max_per_page]

    for i, candidate in enumerate(sorted_candidates):
        filename = f'{output_dir}/page{page_num:03d}_candidate{i:03d}.png'
        candidate['crop'].save(filename)

    return len(sorted_candidates)


def main():
    parser = argparse.ArgumentParser(description='Extract template candidates from PDF')
    parser.add_argument('--pdf', required=True, help='Path to PDF')
    parser.add_argument('--pages', default='1-5', help='Pages to extract from (e.g. "1-5")')
    parser.add_argument('--output', default='./candidates', help='Output directory')

    args = parser.parse_args()

    if '-' in args.pages:
        start, end = map(int, args.pages.split('-'))
    else:
        start = end = int(args.pages)

    output_dir = args.output
    Path(output_dir).mkdir(exist_ok=True)

    with pdfplumber.open(args.pdf) as pdf:
        total_pages = len(pdf.pages)
        end = min(end, total_pages)

    print(f"Extracting candidates from pages {start} to {end}...")
    total_candidates = 0

    for page_idx in range(start - 1, end):
        page_num = page_idx + 1
        print(f"  Page {page_num}...", end=' ', flush=True)

        # Render page
        images = convert_from_path(args.pdf, first_page=page_num, last_page=page_num, dpi=DPI)
        if not images:
            print("skipped")
            continue

        page_image = images[0]
        candidates = extract_candidates_from_page(page_image)
        saved = save_candidates(candidates, output_dir, page_num)
        total_candidates += saved

        print(f"{saved} candidates")

    print(f"\n✅ Extracted {total_candidates} candidates to: {output_dir}/")
    print(f"\nNext steps:")
    print(f"1. Open {output_dir}/ and look at the candidate crops")
    print(f"2. Copy clear examples of each piece (K, Q, R, B, N) to:")
    print(f"   ./glyphes_labeled/K/")
    print(f"   ./glyphes_labeled/Q/")
    print(f"   ./glyphes_labeled/R/")
    print(f"   ./glyphes_labeled/B/")
    print(f"   ./glyphes_labeled/N/")
    print(f"3. Then run: python retrain_figurine_classifier.py --pdf ... --pages 1-50")


if __name__ == '__main__':
    main()
