# System Monitor Bar

Widget de panneau pour **KDE Plasma 5.27** (plasmoid) et **Cinnamon 5.8** (applet) : CPU, RAM, GPU et VRAM (usage et températures), stockage (partitions, dossiers, partages réseau) et débit réseau descendant et montant.

## Fonctionnalités
- Affichage compact en groupes : `CPU 12% 45°  RAM 15% 9.1/60G  |  GPU 3% 44°  VRAM 18% 5.9/32G  |  NET ↓1.2M ↑45K  |  / 25%  home 40%`, avec une fine barre d'usage sous chaque valeur. Libellés au-dessus des valeurs sur un panneau épais, colonne sur panneau vertical.
- Températures colorées selon des seuils (alerte 70 °C, critique 85 °C par défaut).
- Clic : popup avec les cartes Processeur (avec le nom du CPU), Carte graphique, Réseau et Stockage. Processeur et Carte graphique : jauges circulaires (avec la fréquence CPU moyenne, l'horloge GPU, et sous la jauge CPU un petit bloc par thread matériel coloré selon son usage, creux sous 1 % ; le nombre de threads occupés à plus de 50 % reste dans l'infobulle du widget), pastille de température et historique d'utilisation en courbes lissées (≈ 2 min). Le bouton à droite de la légende du graphe CPU le remplace par un mini-graphe par thread (échelle 0-100 %), comme les processeurs logiques du Gestionnaire des tâches de Windows ; le choix est mémorisé.
- Fenêtre flottante : le bouton en haut du popup le détache dans une fenêtre qui reste ouverte et garde sa position, même après un redémarrage du bureau. Le clic sur le widget l'affiche ou la masque ; la fermer revient au popup. Sous KDE c'est une vraie fenêtre, sous Cinnamon un panneau déplaçable au-dessus des fenêtres.
- Processus : la flèche des cartes Processeur et Carte graphique déplie un panneau latéral avec les 60 processus les plus actifs (nom, PID, usage, mémoire), rafraîchi uniquement tant qu'il est ouvert. L'usage CPU est en pourcentage de toute la machine, comme la jauge. Sur NVIDIA, la liste GPU vient de `nvidia-smi pmon` ; sur AMD, de `/proc/*/fdinfo` (noyau récent, processus de l'utilisateur seulement).
- Fin de tâche : dans la liste CPU, sélectionner une ligne puis « Fin de tâche » envoie SIGTERM. Si le processus est toujours là 3 s plus tard, le bouton devient « Forcer l'arrêt » (SIGKILL). Les processus d'autres utilisateurs et ceux dont dépend la session (`plasmashell`, `kwin`, `cinnamon`, `Xorg`...) sont protégés. La liste n'est pas regroupée par application : arrêter un processus d'un navigateur ne ferme pas forcément tout le navigateur.
- Stockage :
  - partitions locales détectées automatiquement (`df -l`, sans `/boot` ni doublons de volume) ;
  - points de montage ajoutés à la main, y compris les partages réseau (NFS, SMB) : espace occupé du système de fichiers qui contient le chemin ;
  - dossiers ajoutés à la main : taille de leur contenu (`du -x`, en basse priorité), affichée en pourcentage de la taille du disque qui le contient, ou d'un quota optionnel.

  Les chemins ajoutés à la main sont mesurés en arrière-plan et mis en cache dans `$XDG_RUNTIME_DIR` (points de montage toutes les 10 s, dossiers toutes les 5 min par défaut) : un gros dossier ou un NAS injoignable ne bloque jamais le relevé.
- Réseau : débit ↓/↑ calculé depuis `/sys/class/net/*/statistics`. Par défaut, somme des interfaces physiques actives (exclut `lo`, ponts, docker, VPN). Interface réglable dans la configuration.
- GPU NVIDIA (`nvidia-smi`) ou AMD (sysfs), détection automatique.
- Consommation (en watts, dans les cartes du popup) : GPU via `nvidia-smi` ou amdgpu (sysfs) ; CPU via RAPL (`/sys/class/powercap`), paquet complet, calculée entre deux relevés. Les compteurs RAPL sont réservés à root (ils permettent des attaques par canal auxiliaire, voir PLATYPUS / CVE-2020-8694) : une étape unique, `sudo ./enable-cpu-power.sh`, installe un service systemd qui donne l'accès en lecture à ton seul utilisateur (celui de `sudo`), sans rien ouvrir aux autres. `sudo ./enable-cpu-power.sh --remove` annule tout. Sans cette étape, la consommation du CPU est masquée.
- Température CPU, première source trouvée :
  - AMD (`k10temp`, `zenpower`) : `Tdie` si exposé, sinon `Tctl` corrigé du décalage des Ryzen 1000/2000 « X » et Threadripper 1000/2000 ;
  - Intel (`coretemp`) : le « Package id » le plus chaud (tous sockets) ;
  - sinon la zone thermique noyau `x86_pkg_temp`.
- Mesures indisponibles (pas de GPU reconnu, pas de sonde, pas de réseau…) masquées automatiquement après 3 relevés sans donnée (option désactivable : elles s'affichent alors `--`).

## Installation
```
./install.sh      # installe ou met à jour, pour le bureau de la session
./uninstall.sh    # désinstalle
```
Le bureau est détecté avec `$XDG_CURRENT_DESKTOP` ; pour le forcer : `./install.sh cinnamon` ou `./install.sh kde`.

### Cinnamon
Clic droit sur le panneau > Applets > « System Monitor Bar » > bouton +. Une mise à jour avec `./install.sh` recharge l'applet déjà présent dans un panneau. S'il y en a plusieurs, redémarrer Cinnamon (Alt+F2, puis `r`) : Cinnamon 5.8 perd les instances quand il recharge une applet qui en a plusieurs.

### KDE Plasma
Clic droit sur le panneau > Mode édition > Ajouter des composants graphiques > « System Monitor Bar ».

Pour recharger Plasma si le widget n'apparaît pas :
```
kquitapp5 plasmashell && kstart5 plasmashell
```

## Configuration
Clic droit sur le widget > Configurer (Cinnamon : « Configurer… ») :
- **Général** : intervalle (500-10000 ms, défaut 2000), source GPU (auto/nvidia/amd), interface réseau (vide = auto), seuils de température d'alerte et critique.
- **Affichage** : pour chaque mesure (CPU, températures, fréquences, consommation, blocs d'usage des threads, RAM, quantités en Gio, GPU, VRAM, stockage, réseau), affichage dans le panneau et/ou le popup ; masquage des mesures indisponibles.
- **Stockage** : partitions détectées à afficher dans le panneau et/ou le popup (par défaut `/` dans le panneau, toutes dans le popup) ; dossiers et points de montage suivis (chemin, quota optionnel pour les dossiers, panneau / popup) ; fréquence de recalcul de la taille des dossiers.

Sous Cinnamon, les partitions détectées s'ajoutent toutes seules à la liste de l'onglet Stockage, et Panneau / Popup se cochent directement dans les listes. Les réglages sont propres à chaque instance de l'applet.

## Organisation du dépôt
- `package/` : plasmoid KDE (QML).
- `cinnamon/sysmonitor-bar@gbaratte/` : applet Cinnamon (`stats.js` pour les données, `panelView.js`, `popupView.js`, `processPanel.js` et `floatWindow.js` pour l'affichage).
- `package/contents/scripts/sysstats.sh` : relevé des mesures, commun aux deux bureaux (lien symbolique côté Cinnamon, copié à l'installation).
- `package/contents/scripts/procstats.sh` : liste des processus et liste des processus protégés, communes aux deux bureaux de la même façon.

Une nouvelle mesure se collecte donc une seule fois, dans `sysstats.sh`, mais s'affiche dans les deux interfaces.

## Pourquoi pas ksystemstats ?
Côté KDE, les capteurs `org.kde.ksysguard.sensors` donnent des valeurs erronées sur cette machine (température CPU à 0, usage NVIDIA qui renvoie la température, VRAM totale doublée). Le widget lit donc directement `/proc`, `/sys` et `nvidia-smi` via `sysstats.sh`, comme l'applet Cinnamon.
