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
