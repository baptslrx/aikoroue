# AikoRoue

Pour convertir un fichier, tu le glisses en maintenant **Maj (⇧)**. Une roue apparaît alors sous ta souris : lâche le fichier sur le format voulu, et le résultat est créé **à côté de l'original**. Tout se passe sur ton ordinateur, rien n'est envoyé sur Internet.

Le thème s'adapte au système : roue **noire** en mode sombre, **blanche** en mode clair, avec un accent **bleu clair**.

- **Anneau intérieur** : les formats de conversion
- **Anneau extérieur** : les outils
- **Centre** : annuler

**Changer le raccourci** : Maj est la touche par défaut, mais tu peux choisir la tienne (⌥ Option, Ctrl, une lettre, une combinaison…). Clic sur l'icône AikoRoue (clic droit sous Windows) → **Changer le raccourci…**, puis appuie sur la touche voulue.

## Téléchargements

Chaque envoi sur `main` compile automatiquement les trois versions (onglet **Actions**, « Compiler AikoRoue »).
Pour publier une version téléchargeable : **Actions → Compiler AikoRoue → Run workflow**, puis indique un numéro (ex. `v1.0.1`). La page **Releases** reçoit alors les fichiers.

| Système | Fichier | Installation |
|---|---|---|
| Windows 10/11 | `AikoRoue-Windows-Setup.exe` | Double-clic. Si Windows affiche « Windows a protégé votre ordinateur » : **Informations complémentaires → Exécuter quand même** (l'appli n'est pas signée). |
| Mac (Apple Silicon et Intel, macOS 13+) | `AikoRoue-Mac.zip` | Dézipper, glisser AikoRoue dans Applications. Au premier lancement : **Réglages Système → Confidentialité et sécurité → Ouvrir quand même**. |
| Linux x86_64 | `AikoRoue-Linux-x86_64.tar.gz` | Extraire, puis lancer `./installer.sh`. |

### Particularités

- **Windows** : par défaut, la roue s'ouvre quand on glisse depuis l'Explorateur ou le Bureau. Pour l'avoir aussi depuis les autres applis, active « Partout » dans le menu de l'icône.
- **Linux** : le raccourci Maj + glisser fonctionne avec **X11**. Sous **Wayland** (Ubuntu/Fedora récents), clique sur l'icône AikoRoue pour ouvrir la roue, puis glisses-y ton fichier. Si l'appli ne démarre pas : `sudo apt install libxcb-cursor0`.
- **Détourage** (enlever le fond d'une photo) : uniquement sur Mac (macOS 14+).

## Ce que sait faire la roue

| Type | Formats | Outils |
|---|---|---|
| Images | JPG · PNG · WEBP · HEIC · GIF · ICO · PDF (Mac : TIFF au lieu de WEBP/ICO) | Compresser · Réduire · Pivoter · Métadonnées · ZIP (+ Détourer sur Mac) |
| PDF | JPG · PNG · DOCX · TXT (+ RTF sur Mac) | Compresser · Fusionner · Séparer · Pivoter · Métadonnées · ZIP |
| Vidéos | MP4 · MOV · WEBM · GIF · MP3 (Mac : M4A) | Compresser · Sans son · Image · ZIP |
| Audio | MP3 · M4A · WAV · FLAC · OGG (Mac : M4A · WAV · AIFF · FLAC) | Compresser · ZIP |
| Documents | PDF · DOCX · TXT · MD · HTML (Mac : + RTF · ODT) | ZIP |
| Autres / dossiers | — | ZIP |

## Organisation du code

```
macos/      Appli Mac native (Swift, AppKit) — ./build.sh --install
desktop/    Appli Windows/Linux (Python, Qt) — python -m aikoroue
packaging/  Installateur Windows (Inno Setup) et script d'installation Linux
assets/     Icônes
.github/    Compilation automatique des trois versions
```

### Lancer la version Windows/Linux depuis le code

```
cd desktop
pip install -r requirements.txt
python -m aikoroue
```
