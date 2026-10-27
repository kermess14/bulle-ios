# Bulle pour iPad et iPhone

Une vraie appli (Swift, le langage d'Apple) qui lit vos BD rangées **dans l'iPad lui-même** : CBZ et PDF, sans serveur
ni compte. Première version (0.1) : bibliothèque en pochettes (les dossiers deviennent des séries), lecteur plein écran,
glisser ou taper sur les bords pour tourner, pincer ou double-taper pour zoomer, sens manga, côtés de tape inversés,
reprise là où on s'était arrêté, « Marquer comme lu / non lu » (appui long sur une pochette).

Pas encore : CBR (RAR), lecture case par case, connexion à un serveur Bulle.

## Mettre des albums dans l'appli
- Bouton **+** : choisir des fichiers ou un dossier (iCloud, clé USB, NAS dans l'app Fichiers…) ; ils sont copiés dans l'appli.
- Ou dans l'app **Fichiers** : « Sur mon iPad › Bulle », y déposer des dossiers et des albums.
- Ou « Ouvrir dans Bulle » depuis une autre appli (dossier « Ajoutés »).

## Fabriquer l'appli (sans Mac)
GitHub la fabrique sur ses Mac à chaque `git push` (onglet **Actions**, « Appli iPad / iPhone »). À la fin, dans la page
de l'exécution, partie **Artifacts** : **Bulle-ipa** (un zip qui contient `Bulle.ipa`).
Si la fabrication échoue, l'artifact **journal-de-fabrication** contient les erreurs : à donner à Claude.

## L'installer sur l'iPad (identifiant Apple gratuit, sans compte développeur)
1. Sur le PC : installer **iTunes** (version du site d'Apple, pas celle du Microsoft Store) et **Sideloadly**.
2. Brancher l'iPad en USB, accepter « Faire confiance à cet ordinateur ».
3. Dans Sideloadly : glisser `Bulle.ipa`, entrer son identifiant Apple, **Start**.
4. Sur l'iPad : Réglages › Confidentialité et sécurité › **Mode développeur** : activer (l'iPad redémarre).
5. Réglages › Général › **VPN et gestion de l'appareil** : faire confiance à son identifiant Apple.

Avec un identifiant gratuit, l'appli s'arrête au bout de **7 jours** : refaire l'étape 3 (les albums et la lecture restent
dans l'iPad). 3 applis installées ainsi au plus. Pour TestFlight et l'App Store : compte développeur Apple (payant).

## À savoir pour l'App Store, plus tard
- Le modèle de découpage des cases de Bulle (dérivé d'Ultralytics YOLO, licence AGPL-3.0) **ne peut pas** être mis tel
  quel dans une appli vendue sur l'App Store : il faudra un autre modèle (licence libre permissive) ou la licence payante
  d'Ultralytics. Cette version ne l'utilise pas.
- Nom, icône, description, captures d'écran et règles de confidentialité seront demandés par Apple.
