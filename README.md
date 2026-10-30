# System Monitor Bar

Widget (plasmoid) KDE Plasma 5.27 pour le panneau : CPU, RAM, GPU et VRAM (usage et températures), débit réseau descendant et montant.

## Fonctionnalités
- Affichage compact en trois groupes : `CPU 12% 45°  RAM 15% 9.1 / 60 Gio  |  GPU 3% 44°  VRAM 18% 5.9 / 32 Gio  |  NET ↓ 1.2 Mo/s ↑ 45 Ko/s`, avec une fine barre d'usage sous chaque valeur. Libellés au-dessus des valeurs sur un panneau épais, colonne sur panneau vertical.
- Températures colorées selon des seuils (alerte 70 °C, critique 85 °C par défaut).
- Clic : popup avec deux cartes (Processeur, Carte graphique) : jauges circulaires (avec la fréquence CPU moyenne et l'horloge GPU), pastille de température et historique d'utilisation (≈ 2 min).
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
Clic droit sur le widget > Configurer : intervalle (500-10000 ms, défaut 2000), source GPU (auto/nvidia/amd), métriques affichées (dont le réseau), interface réseau (vide = auto), affichage des températures, masquage des mesures indisponibles, seuils d'alerte et critique.

## Pourquoi pas ksystemstats ?
Les capteurs `org.kde.ksysguard.sensors` donnent des valeurs erronées sur cette machine (température CPU à 0, usage NVIDIA qui renvoie la température, VRAM totale doublée). Le widget lit donc directement `/proc`, `/sys` et `nvidia-smi` via `package/contents/scripts/sysstats.sh`.
