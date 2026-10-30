# System Monitor Bar

Widget (plasmoid) KDE Plasma 5.27 pour le panneau : CPU, RAM, GPU et VRAM (usage et températures), stockage (partitions, dossiers, partages réseau) et débit réseau descendant et montant.

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
./install.sh      # installe ou met à jour
./uninstall.sh    # désinstalle
```
Puis clic droit sur le panneau > Mode édition > Ajouter des composants graphiques > « System Monitor Bar ».

Pour recharger Plasma si le widget n'apparaît pas :
```
kquitapp5 plasmashell && kstart5 plasmashell
```

## Configuration
Clic droit sur le widget > Configurer :
- **Général** : intervalle (500-10000 ms, défaut 2000), source GPU (auto/nvidia/amd), interface réseau (vide = auto), seuils de température d'alerte et critique.
- **Affichage** : pour chaque mesure (CPU, températures, fréquences, threads occupés, RAM, quantités en Gio, GPU, VRAM, stockage, réseau), affichage dans le panneau et/ou le popup ; masquage des mesures indisponibles.
- **Stockage** : partitions détectées à afficher dans le panneau et/ou le popup (par défaut `/` dans le panneau, toutes dans le popup) ; dossiers et points de montage suivis (chemin, quota optionnel pour les dossiers, panneau / popup) ; fréquence de recalcul de la taille des dossiers.

## Pourquoi pas ksystemstats ?
Les capteurs `org.kde.ksysguard.sensors` donnent des valeurs erronées sur cette machine (température CPU à 0, usage NVIDIA qui renvoie la température, VRAM totale doublée). Le widget lit donc directement `/proc`, `/sys` et `nvidia-smi` via `package/contents/scripts/sysstats.sh`.
