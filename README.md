[Plugin.Omaimporter] 

A [Quickshell](https://quickshell.outfoxxed.me/) bar widget for [Omarchy](https://github.com/omacom/omarchy) that previews files on a mounted SD card or drive and copies a user selection into a destination folder.

## Features

- JPEG and camera RAW thumbnails
- Optional sequential renaming as files copy (e.g. `Danny Birthday Party_001.jpg`)
- Metadata preserved (source files are only ever copied, never moved or modified)
- Themable (follows the current Omarchy theme)
- Works with multiple mounted drives
- Keyboard and mouse navigation

<img width="1278" height="901" alt="screenshot-2026-09-08_11-52-09" src="https://github.com/user-attachments/assets/52ae8ccd-8731-4d38-ab94-260618accb04" />


## Install

### Via Omarchy CLI (recommended)

```
omarchy plugin add https://github.com/MonkeySausageClub/omaimporter.git --enable
```

### Manual install

Clone the repo into your Omarchy plugins directory:

```
git clone https://github.com/MonkeySausageClub/omaimporter.git ~/.config/omarchy/plugins/omaimporter
```

Then enable it:

```
omarchy plugin enable omaimporter
```

The widget appears in the right section of the bar by default.

## Usage

- **Click the bar icon** to open the importer overlay.
- Navigate folders with the breadcrumb bar or the address field.
- Select files with **Space** or **Enter**, or click the checkboxes.
- Optionally type a name in the **Rename** field — copied files get numbered sequentially (`Name_001`, `Name_002`, \u2026). Leave it blank to keep original names.
- Click **Import** to copy selected files to the destination folder.
- Press **Escape** to close the overlay.
- Use the bar icon or **Super+W** to toggle the overlay.

## License

MIT
