# Multi-Cursors Design & Architecture

This document describes the design and implementation of multi-cursor support in the terminal-based text editor.

## Key Features

1. **`Ctrl+D` (Save Cursor)**:
   - Captures and saves the current cursor state (cursor position, visual anchor/selection, and mode).
   - Reverts the editor to **Normal Mode** to allow the current cursor to navigate independently.
   - Successive `Ctrl+D` keypresses append additional cursors.

2. **Visual Representation (Rendering)**:
   - **Selections**: All visual ranges corresponding to saved cursors are synchronized to the global `SelectionManager` so that they highlight in the editor as standard selections (gray background `\x1b[48;5;239m`).
   - **Secondary Cursors**: Saved cursor endpoints are drawn as secondary cursors on the screen using inverted video mode (`\x1b[7m`), providing a clean, terminal-native block cursor appearance.
   - **Newline Cursors**: Cursors resting at the trailing newline of a line are correctly represented as inverted trailing spaces.

3. **`Escape` (Clear All)**:
   - Instantly clears all secondary saved cursors and selections, retaining only the active primary cursor.
   - Reverts to Normal Mode.

---

## Data Structure

```zig
const SavedCursor = struct {
    pos: Point,
    visual_anchor: ?Point,
    mode: Mode,
};

var saved_cursors = std.ArrayList(SavedCursor).empty;
```

---

## Integration Workflow

```mermaid
graph TD
    A[Keypress] -->|Ctrl+D| B[Save current cursor + selection]
    B --> C[Revert to Normal Mode]
    A -->|Escape| D[Clear saved_cursors]
    D --> E[Revert to Normal Mode]
    A -->|Movement/Nav| F[Move current cursor]
    F --> G[Render Loop]
    C --> G
    E --> G
    G --> H[Sync current & saved selections to SelectionManager]
    H --> I[Draw buffer: selections + secondary cursors \x1b[7m]
```
