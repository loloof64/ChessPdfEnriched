# Prochaine session : lecture des diagrammes (étape 4)

## État
- OCR : `ocr_page.py` (PaddleOCR-VL-1.6, GPU OK) donne type de bloc + bbox. Diagramme = bloc `image`.
- FEN : `read_fen.py` + poids fenify (`work/fenify-gpu.pt`, release v2023-07-10 de notnil/fenify, MIT,
  à retélécharger si `work/` est vide). Sortie du modèle = probabilités par case (13 classes), pas des logits.
- `work/` est ignoré par git (poids, images, essais).

## Résultats mesurés (`attaque_minorite_1.pdf` p2, 6 diagrammes extraits avec `pdfimages -png`)
- Recadrer l'intérieur du plateau est indispensable (sans cadre ni coordonnées). Essai : proportions
  (0.059w, 0.058h, 0.946w, 0.936h), valables pour ce livre seulement.
- Erreurs = uniquement des pièces fantômes (surtout des fous noirs) sur cases surlignées jaune/rouge ou
  sous les flèches. Aucune pièce manquante, aucune couleur inversée (vérifié sur 4 diagrammes sur 6).
- Un seuil de confiance ne sépare pas : fantômes de 0,56 à 0,97.
- Diagrammes avec noirs en bas (coordonnées H→A) : fenify lit l'affichage, FEN à pivoter de 180°.
  Pivotement vérifié exact sur le diagramme 2 gauche.
- `PartiesFischer.pdf` p3 : diagramme noir et blanc scanné, 64 cases justes (FEN
  `2r1r1k1/pb5p/1pn1p1p1/1N3pN1/3q1n1P/P3Q3/1PB2PP1/2R1R1K1`).

## Étape 1 : essai `neutralize.py` (surlignages/flèches)
- Principe : couleur claire/foncée de référence = médiane par parité de case ; pixels saturés, assez lumineux
  et loin de la couleur attendue remplacés par elle (+ franges anti-crénelage). Test : `work/try_neutralize.py`.
- Un premier essai sans critère de luminosité détruisait les pièces (reflets crème/bruns) : ne pas dilater librement.
- Mesure (`eval_fen.py`, FEN de référence écrites par Claude, 6 diagrammes, 87 pièces) :
  brut = 7 fantômes + 1 pièce fausse ; nettoyé = 6 fantômes + 0 fausse. Gain réel faible.
  Par diagramme (fantômes brut -> nettoyé) : 004 3->4, 005 1->0, 006 0->0, 007 2->1, 008 1->1 (+1 fausse -> 0), 009 0->0.
  (L'affirmation précédente « 006 et 009 améliorés » était fausse : ils étaient déjà justes en brut.)
- Diagnostic des fantômes restants (clean) : tous sont des fous noirs (classe 9) sur des cases foncées VIDES et
  SANS surlignage (004 : c1, c7, f8 ; 007 : c1 ; 008 : b4), plus un roi blanc à confiance 0,5 en h6 (004).
  Ce n'est donc ni le nettoyage ni le recadrage : c'est une faiblesse du modèle fenify sur cases foncées.
  Le nettoyage en retire certains (c'est son seul gain) mais en fait apparaître d'autres (004 c1, h6).
- Conclusion : le nettoyage seul ne suffit pas. Prochaine piste : classifieur de cases fine-tuné (surlignages
  synthétiques, cases foncées vides en négatifs), ou filtre de plausibilité (fous noirs sur case foncée
  isolés, un seul roi par camp) pour alimenter la liste « à revoir ».
- Piste suivante : classifieur de case ou vérifier le recadrage avant de resserrer les seuils.

## À faire, par priorité
1. Neutraliser surlignages et flèches avant l'inférence. Piège : le rouge des surlignages est proche du
   marron des cases foncées. Piste : estimer pour chaque case sa couleur de fond (claire ou foncée du
   plateau) et remplacer les pixels jaune/rouge saturés par cette couleur. Si ça échoue : fine-tuning de
   fenify, ou classifieur de cases (13 classes) entraîné avec des surlignages synthétiques.
2. Détection d'orientation (lire A–H / 1–8 imprimés, ou heuristique rois/pions) puis pivotement de la FEN.
3. Recadrage automatique du plateau (détecter le quadrillage), au lieu de proportions fixes.
4. Jeu de test : Claude écrit lui-même les FEN de référence en lisant les images (pas de FEN à fournir
   par Laurent, trop pénible à produire à la main) : les 6 diagrammes de `attaque_minorite_1.pdf` p2
   (3 gauche/droite pas encore vérifiés) + quelques dizaines d'autres, puis mesure du taux d'erreurs par
   case. Laurent ne relit que les cas douteux.
   Ajouter des contrôles de plausibilité sur chaque FEN lue (un seul roi par camp, <= 8 pions, <= 16
   pièces, pas de pion en 1re/8e rangée) pour alimenter la liste « à revoir » du lecteur.
5. Ensuite seulement : correction des figurines (OCR confond ♘ ♗ ♖ ♕, voir `ocr_page.py` sur
   `PartiesFischer.pdf` p3), puis format `.chessbook` et lecteur Flutter.

## Rappels
- Laurent : chat en français, code et commentaires en anglais.
- `PartiesFischer.pdf` est en notation figurine (Laurent le déplace dans `notation_figurine/`).
- Venv : `pipeline/.venv` (Python 3.13). Lancer avec `.venv/bin/python`.

## Filtre de plausibilité (`plausibility.py`, fait)
- `issues(board)` : drapeaux python-chess (rois, pions en 1re/8e rangée, >16 pièces...) + pièces promues <= pions manquants.
- Sur le jeu de test : ne signale que 1 lecture fautive sur 5 (004 nettoyé : deux rois blancs). Aucun faux positif.
  Les fous noirs fantômes sont légaux (peu de pions => fous en plus plausibles) : il faut le classifieur de cases.

## Étape 4.5 : fine-tuning sur données synthétiques (`synth.py`, `finetune.py`, fait)
- `synth.py` : planches synthétiques = fonds de bois du livre (cases vides de img-004/005) ou planches chessground,
  40 jeux de pièces chessground (tous types), surlignages et flèches aléatoires, flou de scan, jitter de recadrage,
  + glyphes réels du livre (pions/rois de img-004/005, 19 tuiles). `finetune.py N` : Adam 3e-5, batch 8 (OOM à 32),
  ~3000 pas ≈ 10 min sur la 3060, écrit `work/fenify-ft.pt` (ignoré par git).
- Résultats sur le jeu de test (fantômes/manquantes/fausses) : brut (7,0,1) ; nettoyé (6,0,0) ;
  fine-tuné sans glyphes réels (0,1,12) (pions lus comme autres pièces : jeux de pièces trop différents) ;
  **fine-tuné avec glyphes réels (0,0,1)** : seul g4 de img-008 (pion noir lu dame), non signalé par le filtre.
- Limites : les 4 diagrammes de test (006-009) sont du même livre et contiennent seulement pions et rois ;
  fous/cavaliers/tours/dames de CE livre ne sont pas testés (ni vus à l'entraînement). Le gain réel hors livre est inconnu.
  Fonds pris sur 004/005 uniquement ; `neutralize.py` n'est plus nécessaire avec ce modèle (non mesuré ensemble).
- `read_fen.py` prend déjà le modèle en argument : rien à brancher, passer `work/fenify-ft.pt`.
- Test hors livre : `PartiesFischer.pdf` p3 (noir et blanc scanné, toutes les pièces, crop manuel (225,1275,545,1595)
  sur `pdfimages -png -f 3 -l 3`) : base ET fine-tuné donnent 0 erreur. Pas de régression, mais un seul diagramme.
- `My 60 Memorable Games - Bobby Fischer.pdf` (scan, pages 12-40 : `pdfimages -png -f 12 -l 40`, pages entières) :
  `work/find_boards.py` (contours carrés ~320 px) trouve 15 diagrammes, `work/f60_run.py` les lit avec base et ft.
  Les deux modèles donnent la MÊME FEN sur les 15 ; 3 vérifiés à l'oeil (b03, b04, b13) : exacts, toutes pièces.
  Ces diagrammes sont propres (pas de surlignage), donc ne départagent pas base et ft : les deux marchent.
- Faux positif corrigé : `opposite_check` (b03, trait aux noirs) est maintenant ignoré, le trait étant inconnu.
- Laurent n'a pas d'autre livre : le gain hors livre du fine-tuning restera non mesuré tant qu'il n'y a pas de diagrammes surlignés.

## Régénérer `work/fenify-ft.pt` (poids ignorés par git, tout est reproductible)
Depuis `pipeline/`, avec `.venv/bin/python` :
1. Poids de base `work/fenify-gpu.pt` : release v2023-07-10 de notnil/fenify (voir « État » en haut).
2. Images des diagrammes de référence dans `work/am1/` (noms `img-004.png`... utilisés par `eval_fen.py` et `synth.py`) :
   `mkdir -p work/am1 && pdfimages -png ~/Documents/Echecs/Ebooks/DeFabrice/attaque_minorite_1.pdf -f 2 -l 2 work/am1/img`
   (page 2 ; vérifier que img-004..009 sont bien les 6 diagrammes, sinon ajuster `TRUTH` dans `eval_fen.py`).
3. Jeux de pièces et planches : dossier `assets/` du package pub `chessground-11.0.0`
   (`~/.pub-cache/hosted/pub.dev/`, chemin en dur dans `synth.py`) ; `flutter pub get` le recrée si absent.
4. `.venv/bin/python finetune.py 3000` (~10 min, GPU libre : batch 8, OOM au-dessus) -> `work/fenify-ft.pt`.
   Les lignes `REAL ...` donnent l'erreur sur les diagrammes réels ; attendu : `(0, 0, 1)` au total.
Dépendances non déclarées dans `pyproject.toml` (venues avec paddleocr) : numpy, scipy, opencv, pillow.

## Orientation (`orientation.py`, fait)
- Heuristique géométrique : écart de rang moyen entre l'armée noire et la blanche (pions inclus). `orient(board)` renvoie
  (plateau blancs en bas, pivoté ?, sûr ?). Seuil 2,0 ; en dessous : à revoir.
- Mesure sur 22 diagrammes (18 blancs en bas, 4 noirs en bas) : 20 sûrs et justes ; 1 juste mais « à revoir » (score 1,75) ;
  1 faux et « à revoir » (finale de pions avancés, score -1,67). Aucune erreur sûre.
- Pas testé : diagrammes avec coordonnées imprimées (les lire serait fiable) ; indices de texte (« trait aux noirs »).

## Recadrage automatique (`autocrop.py`, fait, ne plus y toucher sauf besoin)
- `find_board(img)` cherche le carré dont les 64 cases suivent un damier (patchs de coin de case). ~4 s/image (non optimisé).
- Sur les 6 diagrammes am1 : brut ghost/miss/wrong base (2,0,1) vs proportions fixes (7,0,1) ; ft (0,0,1) dans les deux cas.
  Décalage de ~5 px par rapport au vrai plateau, sans effet sur la lecture. Fischer (scan) : trouve le plateau entier.
- PRIORITÉ (consigne de Laurent) : la fonction principale est la reconnaissance des COUPS ; les diagrammes sont auxiliaires.
  Prochaine étape = figurines / coups (point 5 de « À faire »), pas d'autre polissage des diagrammes.

## Figurines : mesure sur `PartiesFischer.pdf` p3 (OCR PaddleOCR-VL, `work/pf-3.json`)
- Pas de couche texte (scan). Figurines de l'OCR inutilisables : 1er tableau = toutes LAISSÉES de côté (`d3`, `b7`, `g5`,
  `fe1`, `e8` au lieu de Qd3, Bb7, Bg5, Rfe1, Re8) ; 2e tableau = symboles parasites cohérents pour T (☰) mais ♂/♀ pour
  deux cavaliers ; texte courant : même symbole ♠ pour un cavalier ET un fou (`18 ♠c3 ♠xg5`) ; `�`, `w`, `☑` ailleurs.
- Conclusion : l'identité de la pièce ne peut pas venir du texte OCR. Il faut lire les glyphes de figurine eux-mêmes.
- Plan proposé : (1) localiser par CV les glyphes figurine (composantes connexes à gauche d'un mot SAN, dans les blocs
  table/text de l'OCR) ; (2) classer en K/Q/R/B/N, soit classifieur entraîné (`~/Documents/Programmation/entrainement_ocr_echecs/
  {6class,glyphs}` existe), soit clustering par livre + vote de légalité (rejeu des coups depuis le diagramme) ;
  (3) injecter la lettre dans le SAN, valider par rejeu python-chess.
