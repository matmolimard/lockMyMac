# lockMyMac

Application macOS de barre des menus qui **verrouille la session quand votre visage n'est plus devant l'écran**. Le critère est votre identité, pas la présence de quelqu'un : si une autre personne reste dans le champ après votre départ, le Mac se verrouille quand même.

lockMyMac ne fait que verrouiller. Le déverrouillage reste celui de macOS (Touch ID, mot de passe, Apple Watch) : l'app ne demande ni ne conserve aucun mot de passe et ne propose aucun déverrouillage facial.

## Fonctionnement

1. **Détection** — le framework Vision d'Apple repère les visages dans l'image.
2. **Identification** — chaque visage est transformé en empreinte (vecteur de 512 nombres) par un réseau FaceNet exécuté par Core ML, puis comparé aux empreintes enregistrées lors du parcours initial (15 empreintes, 5 positions de tête).
3. **Décision** — seul un visage reconnu comme le vôtre remet le compteur à zéro. Une image sans visage, avec un inconnu ou une image manquante ne font rien : le temps continue de courir. Au bout du délai (10 s par défaut), verrouillage.

Détails utiles :

- Analyse d'environ 1 image par seconde quand vous êtes reconnu, 3 par seconde pendant une absence ; le reste du flux est jeté sans être lu. La cadence du capteur est abaissée quand il le permet.
- « Absence en cours » ne s'affiche qu'après 2,5 s sans reconnaissance : une image ratée ne fait rien clignoter.
- Une fois l'absence affichée, il faut deux images reconnues d'affilée pour annuler le compte à rebours : une fausse reconnaissance isolée ne suffit pas.
- La caméra est libérée (voyant éteint) dès que la surveillance est suspendue, que la session est verrouillée, que l'écran dort ou qu'un autre utilisateur occupe l'écran. Au réveil ou au déverrouillage, le compteur repart de zéro.
- Caméra indisponible (débranchée, refusée, plus d'image pendant 5 s) : l'icône passe en alerte, une notification annonce que la protection est interrompue, et l'app réessaie toutes les 5 s. Une option des réglages permet de verrouiller à la place.

## Compilation et installation

Prérequis : macOS 14 ou plus récent, Xcode (pour `swift` et `coremlcompiler`), Python 3.11 ou [`uv`](https://docs.astral.sh/uv/) pour la préparation du modèle.

```bash
./scripts/build_model.sh    # une seule fois : télécharge les poids FaceNet (≈110 Mo) et crée Models/FaceEmbedding.mlmodelc
./scripts/build_app.sh      # compile et assemble build/lockMyMac.app
cp -R build/lockMyMac.app /Applications/
open /Applications/lockMyMac.app
```

`build_model.sh` installe PyTorch et coremltools dans `.build/model-venv` (≈1 Go, supprimable ensuite) ; c'est la seule étape qui utilise le réseau. L'application elle-même n'ouvre aucune connexion.

Signature : par défaut l'app est signée « ad hoc ». macOS redemande alors l'autorisation caméra après chaque recompilation. Avec un certificat de développement, la permission est conservée :

```bash
CODESIGN_IDENTITY="Apple Development: Prénom Nom (XXXXXXXXXX)" ./scripts/build_app.sh
```

Tests du moteur de décision : `swift test`.

## Utilisation

Au premier lancement, la fenêtre d'enregistrement s'ouvre. Ensuite tout passe par l'icône de la barre des menus : état, activer/suspendre, verrouiller maintenant, caméra, délai, mode test, ré-enregistrer ou supprimer le visage, lancer au démarrage, réglages.

**Actif au bureau, pas à la maison.** Dans le menu, cochez « Ne pas surveiller sur le Wi-Fi … » quand vous êtes chez vous (ou gérez la liste dans Réglages › Lieux sans surveillance). Sur ces réseaux la surveillance se suspend et la caméra reste éteinte ; partout ailleurs — bureau, réseau inconnu, Ethernet, pas de réseau — elle est active. macOS exige l'autorisation « Service de localisation » pour lire le nom du Wi-Fi ; lockMyMac ne lit que ce nom, jamais la position. Limite : un réseau portant le même nom que le vôtre et que votre Mac rejoindrait suspendrait aussi la surveillance.

**Vérification périodique.** Menu › Vérification : au lieu de filmer en continu, la caméra s'allume 2 à 4 secondes à intervalle choisi (30 s à 5 min). Deux vérifications de suite sans vous reconnaître verrouillent la session, soit entre une et deux fois l'intervalle après votre départ. Voyant presque toujours éteint, consommation moindre, et un mouvement de tête ne verrouille plus ; en échange, la session reste ouverte plus longtemps après votre départ. Le mode test reste en continu.

**Passez par le mode test avant d'activer la surveillance.** Il utilise exactement la même chaîne, affiche l'image avec un score par visage et le compte à rebours, mais remplace le verrouillage par un message. Vérifiez-y que votre score reste nettement au-dessus du seuil (0,65 par défaut) à votre poste habituel, avec votre éclairage habituel, et réglez seuil et délai.

Vérifier la reconnaissance sans caméra, sur des photos :

```bash
build/lockMyMac.app/Contents/MacOS/lockMyMac --compare photo1.jpg photo2.jpg photo3.jpg
```

## Scénarios

| Scénario | Comportement | Vérification |
|---|---|---|
| Je pars seul | Verrouillage 10 s après la dernière reconnaissance | Test automatique |
| Je pars, quelqu'un reste | Idem : l'inconnu ne retient rien | Test automatique |
| Quelqu'un passe derrière moi | Rien : il suffit qu'un des visages soit le mien | Test automatique |
| Je tourne brièvement la tête | Compte à rebours affiché puis annulé au retour | Test automatique |
| Je reviens avant expiration | Annulation, y compris à la dernière seconde | Test automatique |
| Caméra indisponible | État « protection interrompue », notification, nouvel essai | Implémenté, à vérifier en conditions réelles |
| Veille puis réveil | Caméra coupée ; au réveil le compteur repart de zéro | Saut de temps testé automatiquement ; cycle réel à vérifier |

Les tests automatiques rejouent ces scénarios sur le moteur de décision avec des résultats de reconnaissance simulés. La reconnaissance elle-même a été vérifiée sur des portraits publics (même personne : 0,83 à 0,98 ; personnes différentes : −0,07 à 0,54). **La chaîne complète avec une vraie caméra et votre visage n'a pas pu être testée à la place de l'utilisateur : c'est le rôle du mode test.**

## Limites de la reconnaissance avec une caméra classique

- **Pas de détection de vivacité.** Une webcam ne voit qu'une image plate : une photo ou une vidéo de vous présentée à la caméra est reconnue comme vous. Conséquence limitée ici, puisque l'app ne déverrouille jamais : au pire, la session ne se verrouille pas. Ce n'est pas Face ID (pas de capteur de profondeur ni d'infrarouge).
- **Sosies et proches.** Deux personnes qui se ressemblent peuvent dépasser le seuil (0,54 observé entre deux hommes d'allure proche). Monter le seuil réduit ce risque et augmente les verrouillages intempestifs.
- **Éclairage et pose.** Contre-jour, pénombre, visage en partie masqué (main, masque, casque), profil prolongé vers un second écran : vous n'êtes plus reconnu et le Mac se verrouille après le délai. L'erreur va du côté sûr, mais peut agacer ; allongez le délai ou ré-enregistrez votre visage dans vos conditions réelles.
- **Visages lointains.** Sous environ 56 pixels de large, un visage n'est pas identifié et compte comme inconnu.
- **Biais du modèle.** FaceNet/VGGFace2 n'a pas la même précision pour tous les visages. Seul le mode test dit ce qu'il vaut pour vous.
- **Pas une barrière contre quelqu'un déjà à votre clavier.** Par conception, aucun mot de passe n'est demandé : une personne devant la session ouverte peut suspendre la surveillance ou quitter l'app pendant les 10 secondes.

## Contraintes de macOS

- **Aucune API Apple publique n'identifie un visage.** Vision détecte les visages, leurs repères et leur orientation, mais ne dit pas à qui ils appartiennent ; le matériel de Touch ID/Face ID n'est pas accessible aux apps. L'identification repose donc sur un modèle tiers (FaceNet) converti en Core ML. Ce n'est pas une simple détection de présence.
- **Aucune API publique ne verrouille la session.** lockMyMac appelle `SACLockScreenImmediate` du framework privé `login.framework`, la fonction derrière ⌃⌘Q. C'est un vrai verrouillage, mais Apple peut la retirer : l'app contrôle après coup que l'écran est bien verrouillé et signale l'échec sinon (repli : mise en veille de l'écran, qui ne verrouille que si le mot de passe est exigé immédiatement). Conséquence : pas de bac à sable, pas de Mac App Store.
- **L'état verrouillé/déverrouillé** vient de notifications non documentées (`com.apple.screenIsLocked`) ; un contrôle toutes les 5 s sert de filet.
- **Voyant de la caméra** allumé en permanence pendant la surveillance : c'est matériel et voulu par Apple.
- **Capot fermé** avec écran externe : la caméra intégrée disparaît, la protection est interrompue (et signalée). Choisissez une caméra externe.
- **Lancement au démarrage** (`SMAppService`) : l'app doit rester au même emplacement, de préférence `/Applications`.
- **Caméra de l'iPhone (Continuité)** : proposée dans le choix de caméra, jamais prise en mode automatique. L'iPhone doit être verrouillé, proche du Mac, sur le même compte Apple, Wi-Fi et Bluetooth actifs. Il reste mobilisé (et chauffe/se décharge) tant que la surveillance tourne ; dès que vous le prenez en main, la caméra disparaît et la protection est interrompue (signalé). Ré-enregistrez votre visage avec cette caméra.
- **Distribution** à d'autres personnes : il faudrait un certificat Developer ID et une notarisation.
- **Consommation** : conçue pour être faible (une inférence par seconde sur le Neural Engine, 640×480), mais non mesurée sur batterie.

## Données et confidentialité

- Aucun réseau, compte, télémétrie ni envoi d'image. Aucune image ni vidéo n'est écrite sur disque.
- Seules les empreintes sont stockées : `~/Library/Application Support/lockMyMac/empreintes-visage.json`, lisible par votre seul compte. Ce sont des données biométriques ; elles ne sont pas chiffrées au-delà de FileVault.
- « Supprimer mon visage » efface ce fichier. Désinstallation complète : supprimer l'app, ce dossier, et `defaults delete app.lockmymac.LockMyMac`.

## Licence

Code sous licence MIT (voir `LICENSE`). Le modèle n'est pas inclus dans le dépôt : il est téléchargé par `build_model.sh` depuis [facenet-pytorch](https://github.com/timesler/facenet-pytorch) (code et poids publiés sous licence MIT ; poids entraînés sur le jeu de données VGGFace2, dont les conditions sont à vérifier avant un usage commercial).
