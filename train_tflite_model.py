import os
os.environ['CUDA_VISIBLE_DEVICES'] = '-1'  # Force CPU only

import numpy as np
from pathlib import Path
from PIL import Image
import glob
from tensorflow import keras
import tensorflow as tf

PIECE_CLASSES = ['K', 'Q', 'R', 'B', 'N', 'NotAFigurine']
IMG_SIZE = 32

def extract_hog_features(img_gray):
    from skimage import transform
    from skimage.feature import hog
    img_resized = transform.resize(img_gray, (IMG_SIZE, IMG_SIZE), anti_aliasing=True)
    hog_features = hog(img_resized, orientations=9, pixels_per_cell=(4,4), cells_per_block=(2,2), feature_vector=True)
    aspect_ratio = img_gray.shape[1] / max(img_gray.shape[0], 1)
    return np.concatenate([hog_features, [aspect_ratio]])

# Load glyphes
X, y = [], []
for piece_idx, piece in enumerate(PIECE_CLASSES):
    path = f'glyphes_labeled/{piece}'
    if Path(path).exists():
        for img_file in sorted(glob.glob(f'{path}/*.png')):
            img = Image.open(img_file).convert('L')
            X.append(extract_hog_features(np.array(img)))
            y.append(piece_idx)

X, y = np.array(X), np.array(y)
print(f"Training on {len(X)} samples...")

# Train Keras model
model = keras.Sequential([
    keras.layers.Dense(64, activation='relu', input_shape=(1765,)),
    keras.layers.Dense(32, activation='relu'),
    keras.layers.Dense(len(PIECE_CLASSES), activation='softmax'),
])
model.compile(optimizer='adam', loss='sparse_categorical_crossentropy', metrics=['accuracy'])
model.fit(X, y, epochs=30, batch_size=32, validation_split=0.2)

# Convert to TFLite
converter = tf.lite.TFLiteConverter.from_keras_model(model)
tflite_model = converter.convert()

with open('new_classifier/figurine_classifier.tflite', 'wb') as f:
    f.write(tflite_model)

print(f"✅ TFLite ready: {len(tflite_model)/(1024*1024):.2f} MB")
