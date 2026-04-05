# OCRFlow

A native macOS app for batch OCR (Optical Character Recognition) powered by Apple's Vision framework. Fast, private, and works entirely offline.

![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue)
![Swift](https://img.shields.io/badge/swift-5.0-orange)
![License](https://img.shields.io/badge/license-MIT-green)

## Features

- **Batch processing** — drag and drop multiple images or entire folders at once
- **Apple Vision OCR** — fast mode and accurate mode to suit your needs
- **Multi-language** — Simplified Chinese, Traditional Chinese, English, Japanese, Korean, French, German, Spanish, and more
- **Text post-processing** — merge line breaks, remove empty lines, trim whitespace, fix hyphenated words
- **Flexible export** — export all results as a single text file with configurable separators
- **Fully offline** — no network access, no data leaves your machine
- **macOS-native** — built with SwiftUI, feels right at home on macOS

## Screenshots

> _Add screenshots here_

## Requirements

- macOS 13.0 (Ventura) or later
- Apple Silicon or Intel Mac

## Installation

### Option 1 — Download DMG (Recommended)

1. Go to the [Releases](../../releases) page
2. Download the latest `OCRFlow.dmg`
3. Open the DMG and drag **OCRFlow.app** to your Applications folder
4. First launch: right-click the app → **Open** to bypass Gatekeeper (unsigned build)

### Option 2 — Build from Source

```bash
git clone https://github.com/YOUR_USERNAME/OCRFlow.git
cd OCRFlow
open OCRFlow.xcodeproj
```

Then press **⌘R** in Xcode to build and run.

## Usage

1. Drag images (PNG, JPG, TIFF, PDF) into the app, or click **+** in the sidebar
2. (Optional) Open **Settings** to choose OCR engine, languages, and post-processing options
3. Click **开始识别** (Start OCR) in the toolbar
4. View results in the detail panel; copy or export as needed

## Project Structure

```
OCRFlow/
├── OCRFlowApp.swift          # App entry point
├── ContentView.swift         # Root view + Settings sheet
├── Models/
│   └── ImageItem.swift       # Data model for a single image item
├── ViewModels/
│   └── OCRViewModel.swift    # Main state & OCR logic
└── Views/
    ├── SidebarView.swift     # File list sidebar
    ├── DetailView.swift      # Preview + OCR result panel
    ├── DropZoneView.swift    # Empty-state drop zone
    └── DropHelper.swift      # Drag-and-drop handling
```

## Contributing

Pull requests are welcome! For major changes, please open an issue first to discuss what you would like to change.

1. Fork the repo
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License — see [LICENSE](LICENSE) for details.
