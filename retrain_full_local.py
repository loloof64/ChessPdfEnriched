#!/usr/bin/env python3
"""
Full local retrain of the 6-class figurine classifier.

Faithfully replicates train_figurine_move_classifier.ipynb:
  - Reference HOG implementation (mirrors lib/chess/hog_extractor.dart
    line-for-line — NOT skimage.feature.hog, whose internals differ)
  - 1767-dim features: 1764 HOG + [aspect_ratio, mean_gray, std_gray]
  - Same MLP architecture, optimizer, callbacks and TFLite export

Data:
  - Historical dataset (~10k/class incl. NotAFigurine negatives) from
    chess_glyphs_classifier.zip
  - NEW filled-style glyphs from ./glyphes_labeled/{K,Q,R,B,N}, heavily
    augmented (x60) so the new style is ~20% of each piece class instead
    of being drowned at 0.4%.

Output: ./new_classifier/figurine_classifier.tflite  (input [1,1767], output [1,6])
"""

import os
os.environ['CUDA_VISIBLE_DEVICES'] = '-1'  # local CUDA is broken (libdevice) — CPU only

import random
import zipfile
import numpy as np
from pathlib import Path
from collections import defaultdict
from PIL import Image

# ──────────────────────────────────────────────────────────────────────────
# Configuration
# ──────────────────────────────────────────────────────────────────────────
HIST_ZIP        = os.path.expanduser(
    '~/Documents/Programmation/entrainement_ocr_echecs/6class/chess_glyphs_classifier.zip')
NEW_GLYPHS_DIR  = './glyphes_labeled'
SCRATCH_DIR     = '/tmp/claude-1000/-home-laurent-Documents-Programmation-Projets-Persos-Flutter-ChessPdfEnriched/56d39aef-710f-47f6-b893-f59df4825976/scratchpad/hist_glyphs'
OUTPUT_TFLITE   = './new_classifier/figurine_classifier.tflite'

CLASS_NAMES       = ['K', 'Q', 'R', 'B', 'N', 'NotAFigurine']
IMG_SIZE          = 32
MAX_ROTATION_DEG  = 35
EPOCHS            = 80
BATCH_SIZE        = 128
VAL_SPLIT         = 0.15
NEW_STYLE_AUGS    = 60   # augmentations per new-style glyph

# HOG constants — must stay in sync with hog_extractor.dart
_ORIENTATIONS = 9
_PX_PER_CELL  = 4
_CPB          = 2
_N_CELLS      = IMG_SIZE // _PX_PER_CELL          # 8
_N_BLOCKS     = _N_CELLS - _CPB + 1               # 7
_BLOCK_SIZE   = _CPB * _CPB * _ORIENTATIONS       # 36
FEATURE_DIM   = _N_BLOCKS * _N_BLOCKS * _BLOCK_SIZE + 3  # 1767

_CY   = np.repeat(np.arange(IMG_SIZE), IMG_SIZE) // _PX_PER_CELL
_CX   = np.tile(  np.arange(IMG_SIZE), IMG_SIZE) // _PX_PER_CELL
_BASE = (_CY * _N_CELLS + _CX) * _ORIENTATIONS


# ──────────────────────────────────────────────────────────────────────────
# Reference feature extraction (mirrors Dart HogExtractor.extract())
# ──────────────────────────────────────────────────────────────────────────
def _compute_hog_features(img_32x32: np.ndarray) -> np.ndarray:
    """Vectorized HOG — matches Dart HogExtractor.extract() exactly."""
    gx = np.zeros((IMG_SIZE, IMG_SIZE), dtype=np.float64)
    gy = np.zeros((IMG_SIZE, IMG_SIZE), dtype=np.float64)
    gx[:, 1:-1] = img_32x32[:, 2:] - img_32x32[:, :-2]
    gy[1:-1, :] = img_32x32[2:, :] - img_32x32[:-2, :]

    mag = np.sqrt(gx ** 2 + gy ** 2)
    ang = np.degrees(np.arctan2(gy, gx)) % 180.0

    bin_width = 180.0 / _ORIENTATIONS
    bf = ang.ravel() / bin_width
    b0 = bf.astype(np.int32) % _ORIENTATIONS
    b1 = (b0 + 1) % _ORIENTATIONS
    t  = bf - b0
    mf = mag.ravel()

    flat = np.bincount(
        np.concatenate([_BASE + b0, _BASE + b1]),
        weights=np.concatenate([mf * (1.0 - t), mf * t]),
        minlength=_N_CELLS * _N_CELLS * _ORIENTATIONS,
    )
    cell_hists = flat.reshape(_N_CELLS, _N_CELLS, _ORIENTATIONS)

    eps2    = 1e-5 ** 2
    hog_out = np.empty(_N_BLOCKS * _N_BLOCKS * _BLOCK_SIZE, dtype=np.float64)
    out_i   = 0
    for by in range(_N_BLOCKS):
        for bx in range(_N_BLOCKS):
            block = cell_hists[by:by + _CPB, bx:bx + _CPB, :].ravel().copy()
            block /= np.sqrt(np.dot(block, block) + eps2)
            np.clip(block, 0.0, 0.2, out=block)
            block /= np.sqrt(np.dot(block, block) + eps2)
            hog_out[out_i:out_i + _BLOCK_SIZE] = block
            out_i += _BLOCK_SIZE
    return hog_out


def extract_features(arr_32x32: np.ndarray, orig_w: int, orig_h: int) -> np.ndarray:
    img_gray = arr_32x32.astype(np.float64)
    hog_feat = _compute_hog_features(img_gray)
    extra = np.array([
        orig_w / max(orig_h, 1),
        np.mean(img_gray),
        np.std(img_gray),
    ], dtype=np.float64)
    return np.concatenate([hog_feat, extra]).astype(np.float32)


# ──────────────────────────────────────────────────────────────────────────
# Augmentation (same recipe as the notebook)
# ──────────────────────────────────────────────────────────────────────────
def augment_to_array(pil_img, n, size=IMG_SIZE):
    orig_w, orig_h = pil_img.width, pil_img.height
    base = np.array(pil_img.convert('L').resize((size, size), Image.LANCZOS),
                    dtype=np.float32) / 255.0

    results = []
    for _ in range(n):
        arr = np.clip(base * random.uniform(0.8, 1.2), 0.0, 1.0).astype(np.float32)

        pil = Image.fromarray((arr * 255).astype(np.uint8))
        pil = pil.rotate(random.uniform(-MAX_ROTATION_DEG, MAX_ROTATION_DEG),
                         resample=Image.BICUBIC, fillcolor=255)
        arr = np.array(pil, dtype=np.float32) / 255.0

        scale    = random.uniform(0.80, 1.20)
        new_size = max(4, int(size * scale))
        small = np.array(
            Image.fromarray((arr * 255).astype(np.uint8)).resize(
                (new_size, new_size), Image.LANCZOS),
            dtype=np.float32) / 255.0
        canvas = np.ones((size, size), dtype=np.float32)
        off    = (size - new_size) // 2
        sy, sx = max(0, off), max(0, off)
        ey     = min(sy + small.shape[0], size)
        ex     = min(sx + small.shape[1], size)
        canvas[sy:ey, sx:ex] = small[:ey - sy, :ex - sx]
        arr = canvas

        if random.random() > 0.5:
            arr = arr[:, ::-1].copy()

        arr += np.random.normal(0, 0.03, arr.shape).astype(np.float32)
        results.append((np.clip(arr, 0.0, 1.0).astype(np.float32), orig_w, orig_h))
    return results


# ──────────────────────────────────────────────────────────────────────────
# Data loading
# ──────────────────────────────────────────────────────────────────────────
def index_glyphs(glyphs_dir, class_names):
    paths, labels, counts = [], [], defaultdict(int)
    for class_idx, class_name in enumerate(class_names):
        class_dir = os.path.join(glyphs_dir, class_name)
        if not os.path.exists(class_dir):
            continue
        for filename in sorted(os.listdir(class_dir)):
            filepath = os.path.join(class_dir, filename)
            if os.path.isfile(filepath) and filename.lower().endswith('.png'):
                paths.append(filepath)
                labels.append(class_idx)
                counts[class_name] += 1
    return paths, labels, counts


def main():
    random.seed(42)
    np.random.seed(42)

    # Sanity-check the reference extractor dimension
    dummy = extract_features(np.full((IMG_SIZE, IMG_SIZE), 0.5, np.float32), 20, 30)
    assert len(dummy) == FEATURE_DIM, f'Expected {FEATURE_DIM}, got {len(dummy)}'
    print(f'✅ Feature extractor OK ({FEATURE_DIM} dims)')

    # 1. Extract historical dataset
    hist_glyphs_dir = os.path.join(SCRATCH_DIR, 'glyphs_results', 'glyphs')
    if not os.path.exists(hist_glyphs_dir):
        print(f'Extracting {HIST_ZIP} → {SCRATCH_DIR}...')
        Path(SCRATCH_DIR).mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(HIST_ZIP) as zf:
            zf.extractall(SCRATCH_DIR)
    hist_paths, hist_labels, hist_counts = index_glyphs(hist_glyphs_dir, CLASS_NAMES)
    print(f'Historical dataset: {len(hist_paths)} images')
    for name in CLASS_NAMES:
        print(f'  {name}: {hist_counts[name]}')

    # 2. Index new filled-style glyphs
    new_paths, new_labels, new_counts = index_glyphs(NEW_GLYPHS_DIR, CLASS_NAMES)
    print(f'\nNew filled-style glyphs: {len(new_paths)} images')
    for name in CLASS_NAMES:
        if new_counts[name]:
            print(f'  {name}: {new_counts[name]} (× {NEW_STYLE_AUGS} augs → ~{new_counts[name] * (NEW_STYLE_AUGS + 1)})')
    if not new_paths:
        print('❌ No new glyphs found in', NEW_GLYPHS_DIR)
        return

    X_all, y_all = [], []

    # 3. Historical originals → features (no augmentation: already ~10k/class)
    print('\nExtracting features from historical dataset...')
    for i, (fp, lbl) in enumerate(zip(hist_paths, hist_labels)):
        with Image.open(fp) as img:
            arr = np.array(img.convert('L').resize((IMG_SIZE, IMG_SIZE), Image.LANCZOS),
                           dtype=np.float32) / 255.0
            X_all.append(extract_features(arr, img.width, img.height))
            y_all.append(lbl)
        if (i + 1) % 10000 == 0:
            print(f'  {i + 1}/{len(hist_paths)}')

    # 4. New glyphs: originals + heavy augmentation
    print('\nExtracting + augmenting new filled-style glyphs...')
    for i, (fp, lbl) in enumerate(zip(new_paths, new_labels)):
        with Image.open(fp) as img:
            arr = np.array(img.convert('L').resize((IMG_SIZE, IMG_SIZE), Image.LANCZOS),
                           dtype=np.float32) / 255.0
            X_all.append(extract_features(arr, img.width, img.height))
            y_all.append(lbl)
            for aug_arr, ow, oh in augment_to_array(img, NEW_STYLE_AUGS):
                X_all.append(extract_features(aug_arr, ow, oh))
                y_all.append(lbl)
        if (i + 1) % 50 == 0:
            print(f'  {i + 1}/{len(new_paths)}')

    X = np.array(X_all, dtype=np.float32)
    y = np.array(y_all, dtype=np.int32)
    del X_all, y_all
    print(f'\nDataset: {X.shape[0]} samples × {X.shape[1]} features')
    for idx, name in enumerate(CLASS_NAMES):
        print(f'  {name}: {(y == idx).sum()}')

    # 5. Train (same architecture/callbacks as the notebook)
    import tensorflow as tf
    from sklearn.model_selection import train_test_split

    X_train, X_val, y_train, y_val = train_test_split(
        X, y, test_size=VAL_SPLIT, stratify=y, random_state=42)
    print(f'\nTrain: {len(X_train)}  Val: {len(X_val)}')

    model = tf.keras.Sequential([
        tf.keras.layers.Input(shape=(FEATURE_DIM,)),
        tf.keras.layers.Dense(512, activation='relu'),
        tf.keras.layers.BatchNormalization(),
        tf.keras.layers.Dropout(0.3),
        tf.keras.layers.Dense(256, activation='relu'),
        tf.keras.layers.BatchNormalization(),
        tf.keras.layers.Dropout(0.3),
        tf.keras.layers.Dense(128, activation='relu'),
        tf.keras.layers.Dropout(0.2),
        tf.keras.layers.Dense(len(CLASS_NAMES), activation='softmax'),
    ], name='figurine_hog_mlp')

    model.compile(
        optimizer=tf.keras.optimizers.Adam(1e-3),
        loss='sparse_categorical_crossentropy',
        metrics=['accuracy'],
    )

    history = model.fit(
        X_train, y_train,
        validation_data=(X_val, y_val),
        epochs=EPOCHS,
        batch_size=BATCH_SIZE,
        callbacks=[
            tf.keras.callbacks.EarlyStopping(
                patience=12, restore_best_weights=True, monitor='val_accuracy'),
            tf.keras.callbacks.ReduceLROnPlateau(
                factor=0.5, patience=6, min_lr=1e-6, monitor='val_accuracy'),
        ],
        verbose=1,
    )
    print(f'\n✅ Best val accuracy: {max(history.history["val_accuracy"]):.4%}')

    # 6. Per-class validation report (watch the new-style pieces!)
    y_pred = np.argmax(model.predict(X_val, verbose=0), axis=1)
    print('\nPer-class validation accuracy:')
    for idx, name in enumerate(CLASS_NAMES):
        mask = y_val == idx
        if mask.sum():
            acc = (y_pred[mask] == idx).mean()
            print(f'  {name}: {acc:.2%}  ({mask.sum()} samples)')

    # 7. Export TFLite
    converter    = tf.lite.TFLiteConverter.from_keras_model(model)
    tflite_model = converter.convert()
    Path(OUTPUT_TFLITE).parent.mkdir(exist_ok=True)
    with open(OUTPUT_TFLITE, 'wb') as f:
        f.write(tflite_model)
    print(f'\n✅ Saved: {OUTPUT_TFLITE} ({len(tflite_model) / 1024:.0f} KB)')

    # Spot-check the TFLite file
    interp = tf.lite.Interpreter(model_path=OUTPUT_TFLITE)
    interp.allocate_tensors()
    inp = interp.get_input_details()[0]
    out = interp.get_output_details()[0]
    print(f'   Input : {inp["shape"]}  Output: {out["shape"]}')
    assert list(inp['shape']) == [1, FEATURE_DIM], 'Input shape mismatch!'

    print('\nNext: cp new_classifier/figurine_classifier.tflite assets/models/')


if __name__ == '__main__':
    main()
