# System Monitor Bar

Widget de panneau pour **KDE Plasma 5.27** (plasmoid) et **Cinnamon 5.8** (applet) : CPU, RAM, GPU et VRAM (usage et températures), stockage (partitions, dossiers, partages réseau) et débit réseau descendant et montant.

## Fonctionnalités
- Affichage compact en groupes : `CPU 12% 45°  RAM 15% 9.1/60G  |  GPU 3% 44°  VRAM 18% 5.9/32G  |  NET ↓1.2M ↑45K  |  / 25%  home 40%`, avec une fine barre d'usage sous chaque valeur. Libellés au-dessus des valeurs sur un panneau épais, colonne sur panneau vertical.
- Températures colorées selon des seuils (alerte 70 °C, critique 85 °C par défaut).
- Clic : popup avec les cartes Processeur (avec le nom du CPU), Carte graphique, Réseau et Stockage. Processeur et Carte graphique : jauges circulaires (avec la fréquence CPU moyenne, le nombre de threads CPU occupés à plus de 50 % et l'horloge GPU), pastille de température et historique d'utilisation (≈ 2 min).
- Stockage :
  - partitions locales détectées automatiquement (`df -l`, sans `/boot` ni doublons de volume) ;
  - points de montage ajoutés à la main, y compris les partages réseau (NFS, SMB) : espace occupé du système de fichiers qui contient le chemin ;
  - dossiers ajoutés à la main : taille de leur contenu (`du -x`, en basse priorité), affichée en pourcentage de la taille du disque qui le contient, ou d'un quota optionnel.

  Les chemins ajoutés à la main sont mesurés en arrière-plan et mis en cache dans `$XDG_RUNTIME_DIR` (points de montage toutes les 10 s, dossiers toutes les 5 min par défaut) : un gros dossier ou un NAS injoignable ne bloque jamais le relevé.
- Réseau : débit ↓/↑ calculé depuis `/sys/class/net/*/statistics`. Par défaut, somme des interfaces physiques actives (exclut `lo`, ponts, docker, VPN). Interface réglable dans la configuration.
- GPU NVIDIA (`nvidia-smi`) ou AMD (sysfs), détection automatique.
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
- **Affichage** : pour chaque mesure (CPU, températures, fréquences, threads occupés, RAM, quantités en Gio, GPU, VRAM, stockage, réseau), affichage dans le panneau et/ou le popup ; masquage des mesures indisponibles.
- **Stockage** : partitions détectées à afficher dans le panneau et/ou le popup (par défaut `/` dans le panneau, toutes dans le popup) ; dossiers et points de montage suivis (chemin, quota optionnel pour les dossiers, panneau / popup) ; fréquence de recalcul de la taille des dossiers.

Sous Cinnamon, les partitions détectées s'ajoutent toutes seules à la liste de l'onglet Stockage, et Panneau / Popup se cochent directement dans les listes. Les réglages sont propres à chaque instance de l'applet.

## Organisation du dépôt
- `package/` : plasmoid KDE (QML).
- `cinnamon/sysmonitor-bar@gbaratte/` : applet Cinnamon (`stats.js` pour les données, `panelView.js` et `popupView.js` pour l'affichage).
- `package/contents/scripts/sysstats.sh` : relevé des mesures, commun aux deux bureaux (lien symbolique côté Cinnamon, copié à l'installation).

Une nouvelle mesure se collecte donc une seule fois, dans `sysstats.sh`, mais s'affiche dans les deux interfaces.

## Pourquoi pas ksystemstats ?
Côté KDE, les capteurs `org.kde.ksysguard.sensors` donnent des valeurs erronées sur cette machine (température CPU à 0, usage NVIDIA qui renvoie la température, VRAM totale doublée). Le widget lit donc directement `/proc`, `/sys` et `nvidia-smi` via `sysstats.sh`, comme l'applet Cinnamon.
