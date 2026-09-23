import { monaco, configService, postToSwift, DARK_THEME, LIGHT_THEME } from './shared-init.js'

// --- Create editor ---
const editor = monaco.editor.create(document.getElementById('editor'), {
  value: '',
  language: 'plaintext',
  automaticLayout: true,
  minimap: { enabled: false },
  fontSize: 13,
  fontFamily: 'Menlo, monospace',
  wordWrap: 'on',
  scrollBeyondLastLine: false,
  overviewRulerLanes: 0,
  hideCursorInOverviewRuler: true,
  cursorBlinking: 'smooth',
  smoothScrolling: true,
  scrollbar: {
    verticalScrollbarSize: 8,
    horizontalScrollbarSize: 8,
    vertical: 'auto',
    horizontal: 'auto',
    useShadows: false
  },
  padding: { top: 8 }
})

// Disable Quick Open (Cmd+P) — file search is not supported in this editor
editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyP, () => {})

// Disable Command Palette (F1 / Cmd+Shift+P) — not supported in this editor
editor.addCommand(monaco.KeyCode.F1, () => {})
editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyMod.Shift | monaco.KeyCode.KeyP, () => {})

// The "Command Palette..." context-menu item is removed in shared-init.js.

// Right-click on a selection to type it into the Coding Agent's terminal
// (without submitting), so the user can add context before sending.
editor.addAction({
  id: 'pasteToAgent',
  label: 'Paste to Agent',
  contextMenuGroupId: '9_cutcopypaste',
  precondition: 'editorHasSelection',
  run: (ed) => {
    const text = ed.getModel().getValueInRange(ed.getSelection())
    postToSwift({ type: 'pasteToAgent', text })
  }
})

// --- Multi-model management ---
// One model per open file, keyed by UUID string from Swift.
// Switching tabs calls editor.setModel() — instant, preserves undo history.
const models = new Map()
// Deduplication: one Monaco model per file path, shared across tabs.
// Prevents the TypeScript language service from seeing duplicate declarations.
const fileModels = new Map()
let activeModelId = null
let contentChangedListener = null

// Dispose a model only once no tab points at it any more.
//
// Tabs share one model per file, so the last holder is the only one that may
// free it, and the `fileModels` entry has to go with it — left behind, the
// next tab to open that path adopts a disposed model. Shared by `closeModel`
// and by a tab navigating to a different file: both are "this tab stops
// pointing at this model", and the answer to "may it go?" is the same one.
function disposeIfUnreferenced(model) {
  if (!model) return
  for (const m of models.values()) {
    if (m === model) return
  }
  model.dispose()
  for (const [path, m] of fileModels) {
    if (m === model) { fileModels.delete(path); break }
  }
}

window.editorAPI = {
  // Create or update a model and switch the editor to it.
  // filePath gives the model a file:// URI so the TypeScript worker can
  // resolve imports between open files and infer file types from the path.
  // `line`, when given, is a 1-based line to scroll to and place the cursor on.
  // Revealing here rather than in a separate call keeps it atomic: a caller that
  // opened a file and then revealed would race the model swap, and land the
  // cursor in whatever was open before.
  openFile(modelId, text, languageId, filePath, line) {
    // Dispose listener BEFORE setValue() so the old listener doesn't
    // catch it and send a false dirty event to Swift.
    if (contentChangedListener) contentChangedListener.dispose()
    contentChangedListener = null

    const wantedUri = filePath ? monaco.Uri.file(filePath).toString() : null
    const previous = models.get(modelId)
    // A model this tab already owns that no longer names the file being opened
    // is a *navigation*, not a reload, and `setValue` was the wrong answer to
    // it: it left a model whose Uri said `foo.swift` holding `bar.swift`'s
    // text, with `fileModels` still mapping `foo.swift` to it — so the next tab
    // to open `foo.swift` adopted that model, showed bar's contents, and saved
    // them over foo. It also defeats the dedupe's own purpose, which is that
    // the TypeScript worker can trust a model's Uri to name its contents.
    const isNavigation = Boolean(previous && wantedUri && previous.uri.toString() !== wantedUri)

    let model = isNavigation ? undefined : previous
    // Whether this tab attached to a buffer some other tab already had open,
    // which may be carrying that tab's unsaved edits.
    let adopted = false

    if (!model) {
      // Reuse existing model for the same file (e.g. same file in two tabs).
      // Uses our own map instead of monaco.editor.getModel(uri) which can fail
      // with VS Code service overrides, creating duplicate models that confuse
      // the TypeScript language service ("Duplicate identifier" errors).
      if (filePath) model = fileModels.get(filePath)
      if (model) {
        // Deliberately no `setValue` and no `_cleanVersionId` stamp. `text` is
        // a fresh read from disk, and this buffer may hold another tab's
        // unsaved work: replacing it would discard that work, and stamping it
        // clean told that tab its edits were already saved — it kept its dirty
        // dot from Swift's own per-tab state while the model reported clean,
        // so ⌘W stopped offering to save them.
        adopted = true
      } else {
        const uri = filePath ? monaco.Uri.file(filePath) : undefined
        model = monaco.editor.createModel(text, languageId, uri)
        model._cleanVersionId = model.getAlternativeVersionId()
        if (filePath) fileModels.set(filePath, model)
      }
    } else {
      // This tab's own model, still naming this same file: `text` is a re-read
      // of it, so replacing the contents is exactly what was asked for.
      model.setValue(text)
      monaco.editor.setModelLanguage(model, languageId)
      model._cleanVersionId = model.getAlternativeVersionId()
    }

    // Remapped before the outgoing model is offered for disposal, so the scan
    // sees this tab's new claim and frees the old model only if no *other* tab
    // still holds it.
    models.set(modelId, model)
    editor.setModel(model)
    activeModelId = modelId
    if (isNavigation) disposeIfUnreferenced(previous)

    contentChangedListener = model.onDidChangeContent(() => {
      const dirty = model.getAlternativeVersionId() !== model._cleanVersionId
      postToSwift({ type: 'contentChanged', modelId, dirty })
    })
    if (adopted && model.getAlternativeVersionId() !== model._cleanVersionId) {
      // Swift marks a tab clean when it asks for a file, and the listener above
      // only fires on the *next* edit — so a buffer adopted already dirty has
      // to say so now, or this tab shows no dirty dot over unsaved work and
      // closes without offering to keep it.
      postToSwift({ type: 'contentChanged', modelId, dirty: true })
    }
    if (line) {
      // Clamp: the caller's line came from outside and the file may have
      // changed since. Monaco throws on an out-of-range line.
      const target = Math.max(1, Math.min(line, model.getLineCount()))
      editor.revealLineInCenter(target)
      editor.setPosition({ lineNumber: target, column: 1 })
    }
    editor.focus()
  },

  // Switch to an existing model (tab switch, no content reload).
  switchModel(modelId) {
    const model = models.get(modelId)
    if (!model) return
    if (contentChangedListener) contentChangedListener.dispose()
    editor.setModel(model)
    activeModelId = modelId
    contentChangedListener = model.onDidChangeContent(() => {
      const dirty = model.getAlternativeVersionId() !== model._cleanVersionId
      postToSwift({ type: 'contentChanged', modelId, dirty })
    })
    editor.focus()
  },

  // Get content from any model (not just the active one).
  getContent(modelId) {
    const model = models.get(modelId)
    return model ? model.getValue() : null
  },

  // Mark a model as clean (after save).
  markClean(modelId) {
    const model = models.get(modelId)
    if (model) {
      model._cleanVersionId = model.getAlternativeVersionId()
    }
  },

  // Dispose a model (tab closed).
  // Only actually disposes the Monaco model if no other tab references it,
  // since multiple tabs can share a model when they open the same file.
  closeModel(modelId) {
    const model = models.get(modelId)
    models.delete(modelId)
    if (activeModelId === modelId) {
      activeModelId = null
    }
    disposeIfUnreferenced(model)
  },

  // Force a layout pass (call after reparenting the WKWebView into a new container).
  layout() {
    editor.layout()
  },

  // Switch between light and dark theme.
  setTheme(isDark) {
    configService.updateValue('workbench.colorTheme', isDark ? DARK_THEME : LIGHT_THEME)
    document.documentElement.style.colorScheme = isDark ? 'dark' : 'light'
  }
}

// Signal readiness to Swift
postToSwift({ type: 'ready' })

// Yield to the event loop so WebKit paints the themed content before revealing.
setTimeout(() => document.body.classList.remove('loading'))
