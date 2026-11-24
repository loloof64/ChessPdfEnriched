# Prochaine session : nouveaux livres de Fabrice

# État au 24 nov. 2026 (fin de session) : à lire en premier

Tout est committé (dernier commit `b5b3f56`), aucun tag posé par Claude (Laurent tague lui-même). Les sections plus bas sont l'historique des
étapes (nov. 2026) : utiles pour comprendre un module, pas pour savoir où on en est.

## Poids des diagrammes
- Release **`weights-5`** publiée par Laurent ; `fetch_weights.py` la télécharge (SHA vérifié, pas de remplacement automatique, `--force` sinon).
- Recette de réentraînement : ajouter le diagramme à `HAND` dans `finetune_real.py` (stem du livre, id), puis
  `finetune_real.py --weights work/fenify-ft.v1.pt --out work/fenify-ftN.pt` (toujours depuis v1 = weights-1, pas depuis les poids courants ; ~35-40 min,
  autocrop sur CPU, pas de ligne de progression avant « N train »). Copier vers `work/fenify-ft.pt`, Laurent publie `weights-N`, puis mettre à jour
  URL + SHA dans `fetch_weights.py`, README et CHANGELOG.
- Pourquoi réentraîner plutôt qu'une règle : sur un plateau hachuré, le modèle ft lit un cavalier blanc contouré comme noir à 0,992 (> TRUSTED 0,99,
  donc le modèle de base n'est pas consulté). Les tests d'encre / de creux ne séparent pas les couleurs sur plateau hachuré (essayés, abandonnés).

## Livres validés par Laurent
Najdorf t1/t2, Hérisson t1/t2, Benoni t1/t2, Centre classique, Lutte pour les majorités, Petit centre, Position critique 1-4 (PC5 : p5 confirmée
corrigée, livre pas validé en entier), Calcul de variantes 1-4, Française t1-t3, Tour contre pion, Comment réfléchir t1/t5, Dame contre pion,
Attaque de la minorité 1-3.

## Correctifs génériques récents (tous committés)
- `plausibility.add_missing_king` : un diagramme où un seul camp est présent reçoit l'autre roi sur une case d'arrière-rangée libre, non attaquée,
  la plus proche de la colonne e.
- `moves.py` : un coup numéroté qu'une ligne englobante aurait pu jouer à la place de son dernier coup (`[6...d6 ... 7.g3 6...Fb4]`) est un frère,
  même suivi d'un `]` ; un bloc court qui revient plus tard (« ... des Dames. Rc7 ») ne coupe plus un bloc sauf s'il le termine.
- Pages : `column_order` coupe les colonnes au milieu de l'étendue du texte (pas de la page) ; un bloc OCR « algorithm » est du texte.
- Diagrammes : une image vide est remplacée par la page, une image contenant plusieurs plateaux est découpée en quarts (calés sur le cadre).

## Suite (ordre de Laurent)
1. Convertir d'autres livres de Fabrice (notation française). Objectif : sortie sans erreur dès la première passe ; si c'est le cas, passer à l'étape 2.
2. Plus tard : livres en notation textuelle ANGLAISE (`--lang en`, jamais testé sur un vrai livre).

## Méthode qui marche
- Laurent signale « livre X, page N : diag erroné / coup rouge / manquant / trait faux ». Reproduire HORS LIGNE depuis les caches
  (`work/<livre>/blocks`, `ppocr`, `diagrams`, `pages`), trouver la cause racine, écrire d'abord l'auto-test `--check` qui échoue
  (moves.py / wordboxes.py / plausibility.py / trait.py / make_chessbook_cli.py), corriger, puis comparer ancien/nouveau sur TOUS les livres en cache
  avant de proposer un commit (a attrapé plusieurs régressions).
- Régression : `make_chessbook_cli.py` sur les livres en cache avec `--no-scans -o <scratch>`, comparer les coups illégaux par page aux
  chessbooks livrés (`~/Documents/Echecs/chessbooks/...`, quelques minutes en tout).
- Une seule page : `make_chessbook_cli.py --pages N -o <scratch> --weights work/fenify-ft.pt` (~20 s).
- Annoncer la durée avant tout long calcul ; ne pas régénérer un livre ni lancer tous les livres sans demande.

## Limites connues, pas traitées
- Départ des passages : seulement depuis les diagrammes à ±2 pages ; un passage d'un seul coup exige qu'un seul diagramme de la page le rende légal.
- Erreurs du modèle de lecture (pièce fantôme) ; notation en figurines non gérée par le pipeline principal.
- Refusé par Laurent : resserrer le redémarrage d'ancre en milieu de page ; correction manuelle de SAN dans le lecteur.
- Profil `cpu` non testé (installation, vitesse de PaddleOCR-VL sans GPU).
- Cache `~/.cache/uv` de 42 Go (disque `/home` presque plein) : `uv cache prune` à sa demande seulement.
- Espagnol : textes d'interface à relire par un natif.

## Consignes de travail de Laurent
- Corriger à la racine pour tous les livres (pas de rapport livre par livre) ; commiter quand il le demande, sans tag, petits commits avec une
  ligne CHANGELOG sous Unreleased ; code et commentaires en anglais, discussion en français.
- Préférer les preuves directes de l'image (coordonnées imprimées, pièces pleines/contourées, le point de trait) aux heuristiques :
  plusieurs bugs venaient de mes propres heuristiques. Les vrais livres sont incohérents : une récupération doit être unique et confirmée par la suite.

# Historique (nov. 2026)

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

## Test du classifieur `6class` sur les figurines de PartiesFischer p3 (sonde `work/fig_probe.py`, jetable)
- Jeu `entrainement_ocr_echecs/6class` (6 classes K Q R B N NotAFigurine, ~10 000 glyphes 20x22 par classe) + RandomForest
  sur pixels 20x24 : sur les 13 premières figurines de la page (cellules des 4 tableaux) il répond NotAFigurine (0,5-0,9) pour
  12 sur 13 ; une seule dame trouvée. Il ne transfère donc PAS à ce livre (polices de figurines différentes).
- Les figurines sont des composantes connexes uniques (~28-36 px de large, 33-35 de haut, la tour est plus étroite : 20x29),
  donc la localisation par composantes à gauche d'un mot SAN est faisable ; seule la classification pose problème.
- Décision : regroupement par livre (k-means sur les glyphes candidats, 5 classes) + étiquetage par légalité des coups
  rejoués. Pas d'entraînement global.

## Regroupement de figurines par livre (spike `work/fig_cluster.py`, jetable) : ça marche
- Données : `PartiesFischer.pdf` 8 pages, 200 dpi (`pdftoppm -r 200`), OCR de toutes les pages (`work/ocr_all.py`, ~3 min,
  JSON dans `work/pfall/`). Candidats = premier glyphe de chaque cellule de coup des blocs `table` ; filtre : hauteur >= 30 px et
  encre < 45 % (les lettres sont grasses et denses) ; k-means k=5 sur pixels 40x48.
- Résultat : clusters PURS à l'oeil : fous (2), cavaliers (7), tours (8), « couronne simple » (5, sans doute rois),
  dames (7 dont 2 intrus : un `6` et un `b` passés dans le filtre). Total 29 candidats sur 58 (filtre un peu strict).
- Reste à faire : (1) localiser aussi les figurines des blocs `text` (coups en ligne, plus petits) ; (2) rejeter les lettres
  (intrus) ; (3) étiqueter chaque cluster K/Q/R/B/N par vote de légalité (rejeu depuis le diagramme) ; (4) injecter dans le SAN.

## Figurines dans les tableaux (`figurines.py`, fait pour les blocs `table`)
- `table_cells` : fenêtre de 40 px à gauche de chaque cellule de coup, tronquée au premier blob d'encre (`first_blob`, pour
  qu'une lettre voisine ne décale pas la distance). Pas de composante connexe seule : fragile si figurine collée à la lettre.
- Classification par EXEMPLES choisis par un humain une fois par livre (`work/picks.json` : `{"Q": [[page, "texte OCR"]], ...,
  "": [exemples de coups de pion/roque]}`), plus proche exemplaire (distance euclidienne sur pixels 40x48), refus > 11.
  Le k-means non supervisé a été abandonné : mélange les classes rares (fou avec roi) sur ~45 échantillons.
  Les pions sont des exemples négatifs : sans eux, les `d` ressemblent à des fous.
- Mesure sur PartiesFischer (8 pages, 45 cellules) : p1 `Nf6 Nc3`, p2 `Nc6 Bd3`, p3 (12/12 : Qd3 Bb7 Bg5 Rfe1 Re8 Rc8 Rac1 Nd5
  Ne4), p5 `Rxa7 Ne4 Ra6 Rd8 Rd3 Rxb6` plausibles. Seul manque connu : p8 `d2+` (Qd2+ lu comme pion, distance 13,5 ; les autres
  `Qd3+ Qc3+ Qb2+` sont justes). Pas d'exemple de ROI dans les tableaux : classe K jamais testée.
- Pièges : zsh ne découpe pas `$args` (utiliser bash -c). Usage : `figurines.py picks.json p-1.png p-1.json ...`.
- À faire : (1) rejeu python-chess qui corrige les cas comme `d2+` (pion illégal => pièce qui peut aller en d2 avec échec) ;
  (2) assembler la partie principale (tableaux + titres + texte courant) ; (3) blocs `text` (variantes en ligne) ; (4) `.chessbook`.

## Assemblage de la partie principale : constat (PartiesFischer, pages 1-8), rien d'implémenté
- Les coups de la ligne principale sont répartis entre : blocs `table` (coups bien alignés), blocs `text` en 2 colonnes
  (x~500 : numéros + coups blancs, x~1020 : coups noirs, ex. p4 `22 fx e3 23 xg2 24 e4!` / `xg2! d4 dis.+`), `paragraph_title`
  (`29 ©7+`) et fragments isolés (`xd5`, `e7`, `f6`, `c5`). Les figurines y sont perdues ou garbled, et il n'y a pas de cellules.
- Les variantes en ligne (`7...cxd4 8 exd4 ☠e7 ...`) forment la majorité des coups du livre : c'est là que la valeur se joue.
- Il faut donc un lecteur de lignes au niveau glyphe, indépendant de la structure `table` : (1) segmenter les lignes d'un bloc
  (projection horizontale), (2) segmenter les mots (écarts), (3) classer le premier glyphe de chaque mot par exemplaires
  (figurine / lettre / chiffre), (4) aligner avec les mots SAN du texte OCR, (5) rejeu python-chess. Les glyphes
  `~/Documents/Programmation/entrainement_ocr_echecs/glyphs/{digit,lowercase,uppercase,punctuation}` pourraient servir à lire
  les coups sans l'OCR (non testé).

## Figurines en ligne (`inline.py`, spike, rendement faible)
- Chaîne : lignes (projection horizontale, ligne >12 px) -> mots (écart >9 px à 200 dpi) -> premier blob du mot -> boîte
  serrée redimensionnée 32x40 -> plus proche exemplaire (mêmes `picks.json` que `figurines.py`, coupure 14) ; puis les
  symboles parasites de l'OCR (`GARBAGE_MOVE`) sont remplacés dans l'ordre par les lettres trouvées ; si les nombres
  diffèrent le bloc reste inchangé (REV).
- Vérifié juste à l'oeil sur 3 lignes de p2 (`Bc4 Be7 Re1 Nxd5 Bb5`, 5/5 sans faux positif) ; sur les 8 pages ~7 blocs de coups
  récupérés (p2 `7 Bc4 ... 12 Bb5`, p3/p4 `Position after ... Nb5!/Be4!`, p4 `Nd6`, p5 `33 Rc2`, p7 `47 Rg8 Rxa6 ... 48...Bb6`
  (dernier suspect : `Bb6` plutôt `Rb6`)) ; la grande majorité reste REV.
- Causes (diag `work/inline_diag.py`) : (a) faux positifs dans le texte sans coups (lettres capitales B/F/W/E... à distance <14 :
  `Prematurely forceful`, `Fairly typical` donnent 1-3 « figurines ») ; (b) rappel faible dans les blocs de variantes (p4 : 30 trouvées
  pour 44 symboles OCR ; p6 11/20 ; p7 8/17), car exemplars issus des seuls tableaux (taille/graisse différentes) ;
  (c) l'OCR omet parfois le symbole (`22 fx e3 23 xg2` : zéro symbole).
- Pistes : auto-apprentissage des exemplaires en ligne à partir des blocs OK ; rejeter les capitales par le contexte
  (un coup suit un numéro de coup) ; alignement par mot plutôt que par bloc ; filtre de légalité python-chess (le plus
  discriminant : `Bb6` illégal si aucun fou ne peut aller en b6).

## Filtre de légalité (`legality.py`, fait, testé sur cas synthétiques + 3 séquences réelles de PartiesFischer)
- `decode(board, [(lettre, texte)])` : lettre = classe devinée par le classifieur (`KQRBN`), `?` = figurine vue, classe inconnue,
  `""` = pas de figurine. Statuts : `ok`, `fixed` (lettre illégale, une seule autre pièce légale), `ambiguous` (plusieurs lectures
  légales : la plus fréquente N>B>R>Q>K est jouée, les autres listées), `illegal` (arrêt de la séquence). Un `+` imprimé doit
  réellement donner échec (`Kd2+` écarté devant `Qd2+`).
- Mesure : avec les lettres exactes du classifieur, les 3 séquences réelles (début de partie 1-10 du livre, variante `5 e4 Nxc3 ...
  Bb4+` de p1, variante `7 Bc4 ... 10 Re1` de p2) passent `ok`. Avec la classe INCONNUE (`?`) la légalité seule ne tranche pas :
  `xd5` = Nxd5/Qxd5, `e7` = Be7/Ne7/Qe7 -> `ambiguous`. La légalité sert donc de VETO/réparation sur les lettres du classifieur, pas
  de substitut. Et `f3` sans figurine vue reste pion : un cavalier oublié (`7 f3` = Nf3) n'est détectable que par l'image.
- Il manque encore : assembler les jetons (tableaux + blocs texte + fragments de colonnes) en séquences avec leur position de
  départ (diagrammes ou début de partie) ; c'est le travail suivant (`mainline.py`).

## PDF de Fabrice (`attaque_minorite_1.pdf`) : décodé + lecteur (nov. 2026)
- Le PDF est un document Word : texte réel seulement page 1 ; pages 2 = 6 diagrammes (déjà utilisés), pages 3-6 = CAPTURES d'écran
  d'un cours (coups en français `1.d4 Cf6 ... Tab1`, diagrammes minuscules à coordonnées inversées). Extraction : `pdfimages -png -p`
  puis agrandissement x2 (PaddleOCR-VL lit alors le français très proprement, `work/ocr_fab.py`).
- `french_moves.py` : C F T D R -> N B R Q K, variantes `[ ... ; ... ]` (pile + `;` = frère), rejeu depuis la position de départ.
  Les cases en prose (`pions a4 et b4`) sont ignorées : coup nu accepté seulement dans une suite avec numéro, ou avec `x`/pièce/
  roque/`!?`. Résultat : p3 77 coups 0 illégal (partie jusqu'à 33.Txc6), p6 66 coups 0 illégal (partie complète 1.e4...0-1),
  p5 122 coups 1 illégal (fin de texte). p4 : commence au coup 16 sans position de départ -> pas de coups (à lire sur un diagramme).
- `export_chessbook.py` écrit `work/fab/attaque_minorite.chessbook` (schéma `schema/chessbook.md` : pages, blocs, coups cliquables avec
  FEN, scans). PAS de diagrammes (`diagrams: []`) : les petits plateaux des captures ne sont pas encore lus.
- Lecteur Flutter (`lib/main.dart`, remplace le gabarit compteur) : `CHESSBOOK=chemin.chessbook flutter run -d linux` ; texte à
  gauche, coups cliquables (rouge = illégal), plateau `StaticChessboard` à droite. Pas de sélecteur de fichier, pas d'éditeur,
  pas de `corrections.json` ; non vérifié visuellement par Claude (pas d'accès à l'écran), seulement analyse + test + lancement.

## Lecteur Flutter : affichage Linux (nov. 2026)
- Après la mise à jour de Flutter 3.50 (même jour), la fenêtre Linux se dessinait décalée/réduite (coin 640x360, reste noir), y compris
  pour une app minimale (un seul `Text`) : défaut du moteur, pas du lecteur. Corrigé par `flutter downgrade` (version d'avant la mise à jour du jour ; ne pas remettre à jour sans vérifier) ;
  essais proposés : `--no-enable-impeller`, `--enable-software-rendering`, `flutter downgrade`.
- Vérifié visuellement par Laurent : texte à gauche, coups cliquables, plateau à droite ; la position après `8...Cf8` est exacte.
- Lecteur : bouton « Ouvrir » (file_picker, zenity sous Linux) ; plus de livre par défaut. Reste : corrections, éditeur, navigation clavier.

## Livre complet de Fabrice (`build_fabrice.py`, nov. 2026)
- `cd pipeline && .venv/bin/python build_fabrice.py` écrit `work/fab/attaque_minorite.chessbook` : p1-2 texte réel (`pdftotext -bbox-layout`),
  p2 : 6 diagrammes lus (autocrop + fenify-ft + orientation, confiance 0,999 ; d1-d2 identiques aux FEN vérifiées, d3-d6 retournés
  car noirs en bas), p3 77 coups, p4 42 coups (départ = position après 16.Te3 de la partie de p6 : même partie), p5 122 (1 illégal), p6 66.
- Les petits diagrammes des captures p3-p6 ne sont PAS lus ; `attaque_minorite_2.pdf` (8 p.) et `_3.pdf` (13 p.) existent aussi.
- Pièges : `pdftohtml` écrit des jpg à côté du PDF (jamais l'utiliser sans `-i`) ; `read_fen` : l'indice de case fenify 0 = a1.
- Lecteur : étiquette `3. Cf3` / `2... d5` (numéro déduit du FEN, texte = coup imprimé), diagrammes cliquables sous le texte.
- Mise en page fidèle (lecteur) : chaque bloc de texte et chaque image est positionné à son `bbox` d'origine (Stack à l'échelle de la page),
  police estimée par l'aire du bloc et la longueur du texte (`sqrt(w*h/(len*0.62))`) : approximatif, peut déborder du cadre.
  Les images vues par l'OCR (petits échiquiers des captures p3-p5, `pN_fK.png`) sont gardées à leur place, FEN non lue (`fen: null`).
  Pas encore : gras/italique/couleurs du livre, filets, numéros de page ; le fac-similé (scan en fond) n'est pas affiché.

## Erreur de lecture p2_d5 (signalée par Laurent)
- Pion noir b5 (case jaune + pointes de flèches) lu DAME à 98,7 % par fenify-ft (2e choix : fou ; le pion n'est pas dans le top 2) : seuil de
  confiance inutile. Corrigé à la main dans `build_fabrice.py` (`CORRECTIONS`, `reviewed: true`). C'est l'erreur (0,0,1) connue du jeu de test (img-008 g4).
- À faire : mécanisme de corrections dans le lecteur (`corrections.json`, clic droit : éditeur de position) ; et entraîner avec des flèches/surlignages
  qui recouvrent la pièce (pointes rouges sur la case voisine) pour corriger la cause plutôt que le symptôme.

## Page 5 de Fabrice : texte mal placé (corrigé)
- Cause : PaddleOCR-VL a mis le texte de la colonne de droite (27...a5 ... 30...axb3) à la FIN du bloc du bas à gauche et laissé le bloc de droite
  VIDE. Les coups étaient lus une fois (rien de perdu) mais le texte était dessiné hors de son cadre. `reocr_empty.py` ré-OCRise les blocs
  `text` vides ET retire le doublon du bloc précédent (sans cette coupe : coups lus deux fois, 2 illégaux). Appliqué à p5 ; p3, p4, p6 sans bloc vide.
- Le petit échiquier de gauche de p5 est un bloc `chart` (pas `image`) : l'export garde maintenant les deux.
- Police du lecteur : démarre à 80 px et réduit jusqu'à tenir dans le cadre (l'ancienne estimation ne faisait que réduire, d'où un texte trop petit).
- À surveiller sur les autres livres : bloc vide = texte déplacé dans le bloc voisin.

## `make_chessbook_cli.py` : programme générique PDF -> .chessbook (nov. 2026)
- Remplace `build_fabrice.py` (supprimé : positions en dur) ; `french_moves.py` renommé `moves.py` (option de langue fr/en). Voir le README
  (installation du venv par `pipeline/setup_venv.sh`, options, reprise, corrections conservées).
- Vérifié sur `attaque_minorite_1.pdf` : coups IDENTIQUES au livre fait à la main sur les 6 pages (p3 77/0 illégal, p4 42 avec départ trouvé seul
  = position de p6 au ply 31, p5 122/1, p6 66/0), diagrammes de p2 identiques (la correction `p2_d5` reste valide). Les plateaux des captures p3-p5
  sont maintenant lus : p4 2/2 et p5 2/2 retrouvés dans la partie (`matches_move`), p3 : d1 à 1 case près (tour a8 lue dame), d2 faux (cadre mal
  aligné par `autocrop` : ambiguïté d'une case sur un damier périodique) : signalés par l'absence de `matches_move`.
- Nettoyage OCR généralisé (`dedupe`) : un bloc qui répète à sa fin le début d'un bloc suivant est coupé ; vu sur p3 à 200 dpi (22.Tb6...33.Txc6 lus
  deux fois -> 2 illégaux) et p5. Blocs `text` vides : ré-OCR sur un recadrage.
- Ids : plateaux `pN_dK`, autres images `pN_iK` (logos, chiffres) ; la numérotation des plateaux ne dépend pas des autres images.
- Pas fait : figurines ; `uv.lock` n'a pas été régénéré (la résolution `uv lock` dépasse 2 min : lancer `uv sync` sur la machine, qui le fait) ;
  autocrop à améliorer (ambiguïté d'une case) ; PDF de Fabrice 2 et 3 non traités avec le programme générique.

## Corrections de rendu (nov. 2026, retours de Laurent)
- p1 de Fabrice : chevauchement = image recadrée dans le RENDU de la page (contient aussi le texte, redessiné par le lecteur). Pages à couche texte :
  l'image intégrée est maintenant extraite du PDF (`image_blocks`, pypdfium2 `get_bitmap(render=True)`, RGBA).
- p5 : `a3=` (signe `=` collé à un coup) n'était pas reconnu : le coup 30...a3 de la variante est lu (123 coups). Regex : `=` autorisé si non suivi d'une lettre/chiffre.
- p5 bas droite : police mesurée avec les coups en GRAS (identique à l'affichage) pour que les blocs riches en coups ne débordent plus.
- Zoom : « Page entière » existe (toute la page visible) ; pas de bouton pour masquer l'échiquier (Laurent : ok pour page entière).

## Règle générique anti-chevauchement (lecteur) + durcissement (nov. 2026)
- Au lieu de rustines par page : la police d'un bloc est la plus grande qui tient dans son cadre ET qui ne dépasse pas le haut de tout bloc/figure
  situé en dessous (même colonne, démarrant dans les 40 % bas du cadre ; sinon c'est une figure habillée par le texte : ignorée). Mesure avec les
  coups en gras. Reste approximatif : un fac-similé (scan en fond + coups cliquables) serait fidèle à coup sûr mais exige les boîtes MOT par MOT,
  que PaddleOCR-VL ne donne pas.
- Revue de sécurité : images intégrées d'un PDF non fiable : taille lue AVANT décodage (`get_px_size`), plafond 40 Mpx et 60 images par page,
  miniature 4000 px, `Image.MAX_IMAGE_PIXELS` explicite. Non traité : page de dimensions énormes (pdftoppm) ; `--dpi` borné par l'utilisateur.

## attaque_minorite_2.pdf (retours de Laurent, nov. 2026) : causes et correctifs
- Pages 4-7 « aucun coup » : (1) p8 contient DEUX parties à la suite, traitées comme une seule -> la 2e perdue ; correctif : un « 1. » suivi d'un coup,
  alors que des coups ont déjà été joués, démarre une nouvelle partie (`moves.replay`). (2) variante donnée SANS crochets dans le commentaire
  (« Si 24.Fxd5 les Noirs ») : le rejeu mourait au 1er coup illégal ; correctif : après un coup numéroté illégal, reprise au prochain numéro de coup
  attendu dont le coup est légal. (3) critère d'acceptation d'une position de départ trop strict (5 % d'erreurs) -> `max(2, bons // 8)`.
- p8 « 26.Td2 » ambigu (deux tours peuvent y aller, le livre ne précise pas) : `_disambiguate` choisit le candidat après lequel les coups suivants
  restent légaux (`Rdd2`). Résultat p8 : 168 coups, 0 illégal (2 parties complètes).
- Pages 1-3 (couche texte) : un bloc par LIGNE (boîte exacte de chaque ligne, donc tailles et positions fidèles) au lieu d'un bloc par paragraphe ;
  p2-p3 n'ont aucun coup (théorie numérotée « 1. Paralyser... ») : l'avertissement « NO START POSITION » était faux (`has_moves`).
- Résultats : p4 43 coups (1 illégal = variante sans crochets), p5 56 (5 illégaux : colonne de droite qui reprend une variante ouverte sur l'autre
  colonne), p6 19, p7 39, p4-p5 diagrammes confirmés par la partie (3/3 et 2/2) ; p6-p7 diagrammes lus mais non retrouvés dans la partie (à vérifier).
- Diagrammes : un recadrage « anneau extérieur » (préférer le carré dont l'extérieur n'alterne pas) a été ESSAYÉ puis retiré : moins bon (confirmés 5 -> 4 sur
  attaque_minorite_2). Retenu : `candidate_boxes` (meilleur carré + 8 décalages d'une case) et choix de celui dont la lecture est une position RÉELLE
  de la partie (positions de tous les coups de toutes les pages). Confirmés : attaque_minorite_2 8/11 (p4 3/3, p5 2/2, p6 1/3, p7 2/3), attaque_minorite_1
  p4 2/2, p5 2/2, p3 0/2 (positions peut-être absentes de la partie). Les non confirmés restent à vérifier à l'oeil (pas de `matches_move`).
- Fichier produit : `pipeline/work/attaque_minorite_2.chessbook` (`make_chessbook_cli.py ... -o work/attaque_minorite_2.chessbook`).

## Fidélité de mise en page des pages à couche texte (nov. 2026, retour de Laurent sur attaque_minorite_2 p1-p3)
- Constat (rendu réel obtenu par `test/render_page_test.dart`, polices Noto chargées : `BOOK=... PAGES=1,2,3 flutter test test/render_page_test.dart --update-goldens`
  puis lire `test/render/pageN.png`) : texte sur fond blanc, sans formes ni couleurs = trop loin de l'original (cadres, boîtes rouges, flèches, ovale).
- Correctif : pour les pages à couche texte, `strip_text` retire les objets texte du PDF (pypdfium2 `remove_obj`) et rend la page SANS texte = fond
  (`backgrounds/pN.png`, clé `background` de la page) ; couleur (`FPDFPageObj_GetFillColor`) et gras (nom de police) de chaque ligne -> `style` du bloc.
  Le lecteur dessine le fond, les images en zones cliquables transparentes, puis le texte par-dessus (centré dans sa boîte de ligne).
- Deux bugs de mesure corrigés au passage : (1) la police était mesurée avec le style du contexte AU-DESSUS du Material (pas celui de l'affichage) ;
  (2) `letterSpacing` du thème (0,25 px, non proportionnel) -> mis à 0, plus 2 % de marge de largeur.
- Pages OCR (captures) : pas de fond (le texte est dans l'image) ; rendu = texte repositionné, sans gras/filets du livre.

## Fac-similé : la page d'origine + zones cliquables (nov. 2026, demande de Laurent : « les livres diffèrent trop des originaux »)
- Chaque coup du `.chessbook` a `rects` = [x, y, w, h] sur `scans/pNNNN.png` (une par ligne couverte). `wordboxes.py` : pages à couche texte = boîtes des mots de
  `pdftotext -bbox-layout` (stockées par ligne : `words`) ; pages scannées = 2e OCR classique (PP-OCRv5, `return_word_box=True`, cache `work/<pdf>/ppocr/pN.json`) dont
  le texte, par bloc, est aligné caractère par caractère (difflib) sur celui de PaddleOCR-VL ; un coup n'a de zone que si >= 60 % de ses caractères sont alignés.
- Mesure : attaque_minorite_2 p4 43/43, p5 49/56, p6 19/19, p7 39/39, p8 168/168 ; attaque_minorite_1 p3 77/77, p4 42/42, p5 123/123, p6 66/66.
  Vérifié à l'oeil sur p4 (rectangles dessinés sur l'image) : exact, y compris variantes entre crochets.
- Lecteur : fac-similé par défaut (bouton page/image pour basculer vers le texte reconstitué) ; fichiers du zip lus à la demande (`Book.file`, cache de 12).
- Reste : coups non localisés (p5 de _2 : 7) restent non cliquables en fac-similé (cliquables en mode texte) ; seule la hauteur d'une ligne est couverte, les
  coups coupés en fin de ligne n'ont pas de zone de continuation précise.

## Diagrammes : recherche fine du recadrage guidée par la partie (nov. 2026, retour : p3 d1 et d2 de attaque_minorite_1 faux)
- Cause : le modèle lisait PARFAITEMENT (0 case fausse) avec le bon recadrage ; l'autocrop était décalé d'une case ET de ~11 px (damier périodique), ce que les décalages
  d'une case entière ne couvraient pas. La position vraie (lue à l'oeil) est celle de la partie après 21...bxc6.
- Correctif générique : si aucun des 9 recadrages (meilleur + décalages d'une case) ne donne une position de la partie, `dense_boxes` (pas d'un tiers de case sur +-1,6 case, 3 tailles)
  est essayé par lots (`read_boxes`, GPU si dispo) ; la 1re lecture qui EST une position de la partie gagne. Sinon la lecture du meilleur carré est conservée.
- Résultat : plateaux retrouvés dans la partie : attaque_minorite_2 p4 3/3, p5 2/2, p6 3/3, p7 3/3 ; attaque_minorite_1 p3 2/2, p4 2/2, p5 2/2.
  Limite : un diagramme qui montre une position absente de toute partie (variante) garde la lecture du meilleur carré, sans confirmation.
- Zones cliquables trop étroites (retour de Laurent) : (1) `span` d'un coup inclut maintenant le numéro de coup collé (`23...Fxd5`, `29.axb3`), comme le gras du livre ;
  (2) le lecteur élargit chaque zone de 0,22 x la hauteur de ligne de chaque côté. Vérifié sur p4 de attaque_minorite_2 (rectangles dessinés sur l'image).

## Page 5 de attaque_minorite_2 : variantes qui ne vont pas au bout (retour de Laurent) + trait des diagrammes (nov. 2026)
- Cause des 5 coups rouges de p5 : (1) l'OCR répétait la fin de la colonne de gauche au début de la colonne de droite avec des espaces différents (« 42.Txc3 » /
  « 42. Txc3 ») : `dedupe` compare maintenant SANS aucun espace ; (2) mentions de coups dans le commentaire (« par Th1 ») : un coup isolé illégal est ignoré, pas rouge ;
  (3) crochet fermant mal placé par l'OCR (« [42.Dd1??] Txe2+ 43.Dxe2 Dxb1 ] ») : un coup illégal juste après un `]` mais légal dans la variante qu'on vient de fermer la rouvre.
  Rouge = coup directement numéroté, ou coup de pièce/prise dans une suite numérotée ; jamais un simple mot de case (« c6 se trouve sous tension »).
  Régression évitée de peu : p3 de attaque_minorite_1 était tombée à 37 coups/4 rouges (règle trop large) ; revenue à 77/0.
- Résultats : am2 p4 43/1, p5 54/0, p6 18/0, p7 39/0, p8 168/0 ; am1 p3 77/0, p4 42/0, p5 123/1, p6 66/0 ; tous les diagrammes d'une partie confirmés par elle.
- Trait des diagrammes : `trait.py`, rond à côté du plateau (hors du cadre OCR : cherché sur la page entière) ; EN HAUT (rang 1) = Blancs, EN BAS (rang 8) = Noirs, creux/plein
  sans importance (anneau fin et pâle). Validé 17/17 sur les diagrammes dont le trait est donné par la partie. La partie prime ; le rond sert pour les autres
  (`side_source`: game | dot). Le lecteur affiche « Trait aux Blancs/Noirs » sous l'échiquier.
