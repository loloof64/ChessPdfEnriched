# Projet : lecteur interactif de livres d'échecs scannés

## Objectif
Transformer des livres d'échecs scannés (PDF) en livres interactifs : les diagrammes et les coups
sont cliquables, et un clic affiche la position correspondante sur un échiquier statique.

## Décisions prises
- **Langue** : français ou anglais selon le livre. Choisie dans l'interface AVANT le traitement
  (paramètre du pipeline, pas de détection coup par coup). Option « figurines » (♘f3) en plus.
- **Modèles gratuits (Hugging Face)** : un modèle OCR spécialisé pour le texte et la mise en page
  (PaddleOCR-VL-1.6, 0,9B, Apache-2.0 ; alternatives GLM-OCR, DeepSeek-OCR), un modèle de lecture
  de diagrammes pour la FEN (fenify / Galatea board reader, MIT, TorchScript CPU, entrée 300x300).
  Qualité sur diagrammes de livres scannés NON testée : prévoir un jeu de test.
- **Deux programmes** (la racine du dépôt est le projet Flutter, le lecteur) :
  - `pipeline/` (Python, sous-dossier) : OCR avec positions, découpage des diagrammes, FEN, détection et
    validation des coups (python-chess), export `.chessbook`.
  - racine (Flutter/Dart, `lib/`) : lecteur. Aucun OCR. Cibles : desktop (Linux en priorité, Windows/macOS
    possibles), pas de Web.
  - `schema/` : description du format, partagée.
- **Échiquier Flutter** : package `chessground` (lichess, GPL-3.0, `StaticChessboard` pour la lecture
  seule, éditeur de position inclus) + `dartchess` pour la logique. Vérifier les licences si diffusion.

## Détection des coups
- Regex SAN selon la langue. Français : C, F, T, D, R convertis en N, B, R, Q, K avant rejeu.
  Anglais : aucune conversion. Notation figurine : remplacement des symboles.
- Notation descriptive des livres anciens : conversion séparée (plus tard).
- Règles de confusion OCR propres à chaque langue (l/1, O/0, B/8, e/c...).
- Rejeu avec un moteur de règles : un coup illégal = erreur d'OCR probable, signalé sans planter.
- Contexte : un diagramme fixe la position de départ ; les coups numérotés sont rejoués depuis la
  dernière position connue ; les variantes entre parenthèses forment une pile.

## Format `.chessbook` (archive zip)
```
livre.chessbook
  manifest.json       langue, titre, version du schéma
  pages/              données générées (blocs de texte, coups avec SAN + FEN résultante + ok,
                      diagrammes avec bbox, image, FEN, confidence, reviewed)
  diagrams/           images recadrées de chaque diagramme (ex. p42_1.png)
  scans/              pages d'origine (optionnel, mode fac-similé)
  corrections.json    corrections manuelles, SEUL fichier écrit par le lecteur
```
- Identifiants stables (ex. `p42_d1`, `p42_m7`).
- Types de corrections : `diagram_fen`, `move_san`, `ignore`. Chaque correction garde un
  `source_hash` de la valeur d'origine ; si le hash change après retraitement, la correction est
  marquée « à revoir » (jamais appliquée en silence, jamais perdue).
- Relancer le pipeline remplace `pages/` et `diagrams/` mais conserve `corrections.json`.
- Sauvegarde sûre : extraction dans un dossier de travail, réécriture du zip dans un fichier
  temporaire puis remplacement.
- Le lecteur ne modifie jamais les données générées.

## Interface lecteur
- Texte du livre d'un côté, échiquier fixe de l'autre ; clic sur un coup ou un diagramme = position.
- Clic droit : éditer un diagramme (éditeur de position) ou un coup (champ texte).
- Liste « à revoir » : diagrammes peu sûrs, coups illégaux, corrections orphelines.

## Environnement (vérifié sous Ubuntu)
- OS : Ubuntu 26.04 LTS. Plateforme principale du lecteur : Linux desktop.
- GPU : NVIDIA GeForce RTX 3060, 12 Go de VRAM, pilote 580.178.04 (CUDA 13.0), ~239 Mo utilisés au repos.
- PyTorch embarque son runtime CUDA : pas de CUDA Toolkit séparé nécessaire. Le pilote 580 suffit
  largement (les wheels Paddle CUDA 12.6 demandent un pilote >= 550.54.14).
- Flutter 3.47.7 (stable) : `flutter doctor` sans problème (toolchain Linux desktop OK).
- Python système : 3.14.4. NE PAS l'utiliser pour le pipeline (voir ci-dessous).

## Environnement Python du pipeline : Python 3.13 en environnement virtuel
- Raison : PaddleOCR / PaddleOCR-VL documente officiellement Python 3.8 à 3.13. Le support de
  Python 3.14 n'est pas confirmé (en particulier les wheels `paddlepaddle-gpu`), et certaines
  dépendances de l'écosystème GPU n'ont pas encore de wheels cp314. PyTorch 2.9/2.10 supportent
  3.14, mais le goulot est Paddle.
- Créer un venv dédié en Python 3.13 dans `pipeline/` (par exemple `.venv`), sans toucher au
  Python 3.14 du système. Outil conseillé : `uv` (`uv venv --python 3.13 pipeline/.venv`), qui
  installe 3.13 à côté du système si besoin.
- Fixer la version dans le projet (`pipeline/.python-version` ou `requires-python = ">=3.13,<3.14"`
  dans `pyproject.toml`) pour que l'environnement soit reproductible.
- Toujours activer ce venv (ou utiliser `uv run`) avant d'installer ou de lancer quoi que ce soit
  dans `pipeline/`. Ne jamais faire de `pip install` hors venv.
- Installer PyTorch avec le build CUDA adapté, puis PaddlePaddle GPU (index officiel Paddle,
  CUDA 12.6) et `paddleocr[doc-parser]` ou équivalent pour PaddleOCR-VL. Vérifier chaque import
  et la détection du GPU (`torch.cuda.is_available()`, `paddle.device.is_compiled_with_cuda()`)
  avant d'aller plus loin.
- Dépendances système probables : `poppler-utils` (apt) pour lire les PDF.
- Si Paddle pose problème sous 3.13, repli possible : Python 3.12.

## Premières étapes
1. Vérifier la machine : GPU, Flutter (déjà OK, voir ci-dessus), `poppler-utils`.
1b. Créer le venv Python 3.13 du pipeline et valider les imports et le GPU.
2. Initialiser `pipeline/` et `schema/` (le lecteur Flutter est à la racine) et écrire le schéma du format.
3. Test de bout en bout sur UNE page : OCR avec positions, découpage des diagrammes, FEN,
   affichage sur échiquier.
4. Mesurer la fiabilité de la lecture des diagrammes sur des positions de FEN connues.
5. Construire ensuite l'interface complète et le système de corrections.

## À fournir par l'utilisateur
- 5 à 10 pages scannées représentatives (diagrammes, texte courant, variantes), langue de chaque livre.
- Quelques diagrammes dont la FEN exacte est connue.
