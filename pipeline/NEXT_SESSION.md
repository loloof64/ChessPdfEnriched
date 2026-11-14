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
- Résultat sur les 6 diagrammes (img-004..009) : 005, 006, 007, 009 nettement meilleurs (fantômes disparus ;
  006 et 009 sans erreur apparente), mais 004 et 008 gardent/ajoutent des fantômes (004 : `K` en h6 et `b` en c1 ;
  008 : `b` en b4). Cause probable : pointes de flèche rouge sombre et recadrage décalé. Pas de jeu de test
  de référence encore : erreurs jugées à l'œil.
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
