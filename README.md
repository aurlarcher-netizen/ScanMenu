<p align="center"><img src="logo/logo.svg" width="160" alt="ScanMenu"></p>

<h1 align="center">ScanMenu</h1>

<p align="center">Scanner en un clic depuis la barre de menus macOS, directement dans le dossier de votre choix.</p>

---

## Fonctionnement

- **Clic gauche** sur l'icône : lance le scan et enregistre le fichier (`Scan 2026-11-02 à 14.30.12.pdf`) dans votre dossier, puis affiche une notification.
- **Clic droit** : menu de réglages
  - scanner (USB, réseau ou partagé, détecté automatiquement)
  - dossier de destination (par défaut `~/Documents/Scans`)
  - format : PDF, JPEG ou PNG
  - résolution : 150, 200, 300 ou 600 ppp
  - source : automatique (chargeur s'il contient du papier, sinon vitre), vitre ou chargeur
  - couleur ou niveaux de gris
  - afficher le fichier dans le Finder après le scan
  - démarrer avec le système

ScanMenu utilise le framework Apple **ImageCaptureCore** : tout scanner reconnu par l'app « Transfert d'images » fonctionne.

## Installation

Prérequis : macOS 13 ou plus récent, et les outils en ligne de commande d'Apple (pas besoin de tout Xcode) :

```bash
xcode-select --install
```

Puis :

```bash
git clone https://github.com/aurlarcher-netizen/ScanMenu.git
cd ScanMenu
./build.sh --install
```

L'app est compilée, copiée dans `/Applications` et lancée.

## Dépannage

Un journal détaillé est écrit dans `~/Library/Logs/ScanMenu.log` (clic droit → **Afficher le journal**).

Si plusieurs scanners portent le même nom sur le réseau, choisissez le bon dans clic droit → **Scanner** : chacun y apparaît séparément.

## Structure

| Fichier | Rôle |
| --- | --- |
| `Sources/main.swift` | Toute l'application (barre de menus + pilotage du scanner) |
| `build.sh` | Construit `ScanMenu.app` (`--install` pour l'installer et la lancer) |
| `logo/logo.svg` | Logo source |
| `logo/make-icon.sh` | Régénère les PNG et `AppIcon.icns` à partir du SVG |

## Licence

[MIT](LICENSE)
