#!/usr/bin/env python3
"""
Simple HTTP service for figurine classification.

Load the RandomForest model and serve predictions via HTTP.

Usage:
    python figurine_classifier_service.py

Then call from Dart:
    POST http://localhost:5000/predict
    Body: {"features": [1.0, 2.0, ..., 1768 values]}
    Response: {"class": "K", "confidence": 0.95}
"""

import pickle
import numpy as np
from flask import Flask, request, jsonify
import sys

app = Flask(__name__)

# Load model
try:
    with open('new_classifier/figurine_classifier.pkl', 'rb') as f:
        model = pickle.load(f)
    print("✅ Model loaded")
except Exception as e:
    print(f"❌ Failed to load model: {e}")
    sys.exit(1)

CLASSES = ['K', 'Q', 'R', 'B', 'N', 'NotAFigurine']

@app.route('/predict', methods=['POST'])
def predict():
    """Classify a glyph from HOG features."""
    try:
        data = request.json
        features = np.array(data['features'], dtype=np.float32).reshape(1, -1)

        # Predict
        pred_idx = model.predict(features)[0]
        confidence = np.max(model.predict_proba(features)[0])

        result = {
            'class': CLASSES[pred_idx],
            'confidence': float(confidence),
            'all_scores': {CLASSES[i]: float(model.predict_proba(features)[0][i])
                          for i in range(len(CLASSES))}
        }
        return jsonify(result)
    except Exception as e:
        return jsonify({'error': str(e)}), 400

@app.route('/health', methods=['GET'])
def health():
    return jsonify({'status': 'ok', 'model': 'RandomForest', 'classes': CLASSES})

if __name__ == '__main__':
    print("🚀 Starting classifier service on http://localhost:5000")
    print("   POST /predict with {\"features\": [...]}")
    print("   GET /health for status")
    app.run(host='localhost', port=5000, debug=False)
