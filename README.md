# ChessPdfEnriched

Lire des livres d'échecs scannés comme des livres interactifs : les coups et les diagrammes sont cliquables, un clic
affiche la position sur un échiquier.

Deux programmes :

| Programme | Dossier | Rôle |
|---|---|---|
| **Pipeline** (Python) | `pipeline/` | transforme un PDF en fichier `.chessbook` (OCR, diagrammes, coups) |
| **Lecteur** (Flutter) | racine, `lib/` | ouvre un `.chessbook` : texte, coups cliquables, échiquier, correction des diagrammes |

Le format du `.chessbook` est décrit dans [schema/chessbook.md](schema/chessbook.md). Le point d'avancement détaillé
(mesures, limites, pièges) est dans [pipeline/NEXT_SESSION.md](pipeline/NEXT_SESSION.md).

## 1. Pipeline : générer un `.chessbook` à partir d'un PDF

### Prérequis

- Linux (testé sous Ubuntu 26.04), carte NVIDIA avec pilote récent (le projet installe les roues CUDA 12.6 de PyTorch et
  de Paddle ; la RTX 3060 12 Go suffit).
- [`uv`](https://docs.astral.sh/uv/getting-started/installation/) (gestionnaire de venv et de dépendances Python).
- `poppler-utils` : `sudo apt install poppler-utils` (fournit `pdftoppm` et `pdftotext`).

### Installer le venv

```bash
cd pipeline
./setup_venv.sh
```

Le script vérifie `uv` et poppler, puis lance `uv sync` : il crée `pipeline/.venv` (Python 3.13) et installe toutes les
dépendances déclarées dans `pyproject.toml` (PyTorch, Paddle/PaddleOCR-VL, python-chess, OpenCV, scikit-learn, etc.). Le
premier passage télécharge plusieurs Go, et le premier lancement de l'OCR télécharge aussi son modèle.

Sans `uv` : `python3.13 -m venv .venv`, puis installer à la main PyTorch (`--index-url https://download.pytorch.org/whl/cu126`),
`paddlepaddle-gpu` (index Paddle CUDA 12.6) et `pip install -e .` pour le reste. Ce chemin n'est pas testé.

### Poids des diagrammes

La lecture des diagrammes utilise un modèle [fenify](https://github.com/notnil/fenify) (licence MIT) affiné sur des
échiquiers synthétiques. Le fichier `pipeline/work/fenify-ft.pt` n'est **pas** dans git (127 Mo, dossier `work/` ignoré).
Pour l'obtenir sur une nouvelle machine :

1. soit copier `pipeline/work/fenify-ft.pt` depuis une machine qui l'a ;
2. soit le régénérer : télécharger les poids de base `fenify-gpu.pt` (release `v2023-07-10` de notnil/fenify) dans `pipeline/work/`,
   puis suivre « Régénérer `work/fenify-ft.pt` » dans [pipeline/NEXT_SESSION.md](pipeline/NEXT_SESSION.md) (`finetune.py`, environ 10 minutes
   sur GPU).

Le programme s'arrête tout de suite, avant l'OCR, si le fichier est absent (option `--weights` pour un autre chemin).

### Lancer

```bash
cd pipeline
.venv/bin/python make_chessbook.py ~/Documents/Echecs/Ebooks/DeFabrice/attaque_minorite_1.pdf --lang fr -o attaque.chessbook
```

| Option | Rôle |
|---|---|
| `--lang fr` ou `en` | notation des coups imprimée dans le livre : `fr` = C F T D R (Cavalier, Fou, Tour, Dame, Roi), `en` = N B R Q K |
| `-o fichier.chessbook` | fichier produit (défaut : `<nom du pdf>.chessbook` dans le dossier courant) |
| `--pages 1-40` ou `3,5,8-10` | ne traiter que ces pages (numéros du PDF ; défaut : toutes) |
| `--title "Titre"` | titre affiché (défaut : titre du PDF, sinon nom du fichier) |
| `--dpi 200` | résolution du rendu des pages |
| `--no-scans` | n'embarque pas les images des pages (fichier plus petit) |
| `--work dossier` | dossier de cache (défaut : `pipeline/work/<nom du pdf>/`) |
| `--weights fichier.pt` | poids du lecteur de diagrammes |

Pour chaque page, le programme :

1. rend la page en image ; lit le texte dans la couche texte du PDF s'il y en a une (au moins 60 mots), sinon fait l'OCR
   avec PaddleOCR-VL (environ une minute par page sur une RTX 3060) ;
2. nettoie les défauts connus de l'OCR : blocs de texte vides et passages répétés dans le bloc voisin ;
3. repère les images, lit la position de celles qui sont des échiquiers et la compare à la partie de la page
   (`matches_move` dans le fichier : c'est un bon contrôle de la lecture) ;
3b. localise chaque coup sur l'image de la page (pour le fac-similé) : par les boîtes des mots du PDF quand il a une couche texte, sinon avec un second OCR (PP-OCRv5, boîtes mot par mot) dont le texte est aligné caractère par caractère sur celui du modèle principal ;
4. lit les coups, convertit en notation anglaise, les rejoue avec python-chess depuis la position de départ ; les variantes
   `[ ... ]` partent de la position avant le dernier coup. Un coup illégal est une erreur probable de l'OCR : il est marqué
   `ok: false` (en rouge dans le lecteur) et la ligne s'arrête là ;
5. pour une page qui ne commence pas au coup 1, cherche dans les autres pages la position d'où le texte se rejoue sans erreur
   (ex. : page 4 du PDF de Fabrice, qui reprend la partie de la page 6 au coup 16).

Un résumé par page est affiché à la fin : nombre de coups, de coups illégaux, de diagrammes lus et confirmés par la partie.

**Reprise** : les étapes lentes (rendu, OCR) sont gardées dans le dossier de cache. Si le programme est interrompu, relancer la
même commande reprend où il s'était arrêté. Pour refaire l'OCR d'une page, supprimer `work/<pdf>/blocks/p<N>.json`.

**Corrections** : relancer le programme sur un livre déjà généré remplace tout sauf `corrections.json`, le fichier où le lecteur
enregistre vos corrections de diagrammes. Une correction n'est appliquée que si le diagramme généré est resté identique ; sinon
elle est signalée « à revoir ».

### Limites connues

- **Notation en figurines (♘f3) : non gérée** par `make_chessbook.py`. Des essais existent (`figurines.py`, `inline.py`,
  `legality.py`) mais ils ne sont pas intégrés ; voir `pipeline/NEXT_SESSION.md`.
- La lecture des diagrammes n'est **pas fiable à 100 %** : un pion noir sous une case surlignée a été lu comme une dame avec 98,7 %
  de confiance. Vérifier les diagrammes à l'œil et corriger dans le lecteur (clic droit).
- Les diagrammes ne sont lus que s'ils sont à peu près carrés et ressemblent à un échiquier ; les petits plateaux des captures
  d'écran sont parfois mal recadrés (signalés par l'absence de `matches_move`).
- Notation descriptive des livres anciens, deux colonnes de coups dans un tableau, etc. : non gérés.
- Les tests des modules sont des auto-vérifications : `.venv/bin/python legality.py`, `orientation.py`, `plausibility.py`.

## 2. Lecteur Flutter

Prérequis : Flutter 3.47.x sous Linux (`flutter doctor`) et `zenity` pour la boîte de dialogue d'ouverture de fichier.
**Ne pas passer à Flutter 3.50** pour l'instant : sur cette configuration la fenêtre Linux s'y affiche décalée et rognée.

```bash
flutter pub get
flutter run -d linux
```

- **Ouvrir un livre** : bouton « Ouvrir un livre » (ou l'icône dossier en haut) et choisir un fichier `.chessbook`. On peut aussi
  passer le chemin : `flutter run -d linux --dart-entrypoint-args chemin.chessbook`, ou la variable `CHESSBOOK=chemin.chessbook`.
- **Lire** : par défaut le **fac-similé** : la page d'origine telle quelle (image du PDF), avec des zones cliquables posées sur les coups et les
  diagrammes. Cliquer sur un coup affiche la position, avec la flèche du dernier coup et son numéro (`3. Cf3`, `2... d5`). Un coup entouré de
  rouge est illégal. L'icône page/image de la barre du haut bascule vers le **texte reconstitué** (blocs de texte replacés, utile si le livre n'a pas
  les images des pages, option `--no-scans`).
- **Pages** : boutons précédente et suivante, ou taper un numéro dans le champ puis valider.
- **Zoom** : boutons − et +, ou le menu au milieu : « Page entière » (toute la page visible), « Largeur de page », ou un pourcentage
  (100 % = taille réelle de la page ; au-delà de la largeur du volet, la page défile aussi horizontalement).
- **Échiquier** : le bouton « Retourner l'échiquier » inverse la vue.
- **Corriger un diagramme** : clic droit sur le diagramme, ou le bouton « Corriger ce diagramme » après l'avoir sélectionné.
  Glisser une pièce de la palette sur une case, la sortir du plateau pour la supprimer, puis Enregistrer. La correction est
  écrite dans `corrections.json` à l'intérieur du `.chessbook`.

Tests : `flutter test` (le test d'enregistrement des corrections a besoin d'un livre généré dans `pipeline/work/fab/` et est
ignoré sinon).
