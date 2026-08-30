import { monaco, configService, postToSwift } from './shared-init.js'

// --- Diff API ---
// Renders a vertical stack of inline diff editors, one per file. Each editor is
// sized to its content height so the page (not the editor) scrolls and there is
// no trailing empty editor background below the content. Binary files render a
// "not shown" badge; oversize files render a click-to-load placeholder.
const container = document.getElementById('diffs')
const emptyState = document.getElementById('empty-state')

// Line height in pixels — must match Monaco's lineHeight (~19px at fontSize 13).
const LINE_HEIGHT = 19
const MIN_EDITOR_HEIGHT = 60
// Extra lines added to the initial estimate to cover diff decorations/widgets.
const PADDING_LINES = 2
// Padding added to the measured content height when sizing the container.
const HEIGHT_PADDING = 8

// Localized strings injected by Swift (fall back to English if absent).
const STR = {
  binary: 'Binary file (not shown)',
  largeFile: 'Large file — %d changes, click to load',
  copyFile: 'Copy File Path',
  copied: 'File path copied',
  addComment: 'Add review comment…',
  commentAdd: 'Add',
  commentSave: 'Save',
  commentCancel: 'Cancel',
  commentEdit: 'Edit',
  commentDelete: 'Delete',
  commentOrphaned: 'Line no longer in diff'
}

// Active diff editors keyed by file path: { host, editor, original, modified }.
const sections = new Map()

// --- Review comments (state pushed from Swift; JS never owns it) ---
// Swift is the single source of truth: every mutation is posted up, the store
// answers with a full setComments(), and only then do the zones change.
let commentsByFile = new Map() // filePath -> [comment]
const commentZones = new Map() // filePath -> [zoneId]
let inputZoneState = null // { filePath, zoneId } for the single open input zone
// Guard against re-entrant rendering: renderComments() lays the editor out,
// and a layout must never be able to drive another render of the same file.
// Holds the file currently rendering (not a bare flag) so a layout that
// cascades into a *different* file's onDidUpdateDiff still renders it.
let renderingFor = null
// Editors awaiting their first onDidUpdateDiff before we report contentReady.
let pendingCount = 0
let reported = false
let safetyTimer = null

const sharedDiffOptions = {
  automaticLayout: true,
  renderSideBySide: false,
  readOnly: true,
  minimap: { enabled: false },
  fontSize: 13,
  fontFamily: 'Menlo, monospace',
  scrollBeyondLastLine: false,
  overviewRulerLanes: 0,
  hideUnchangedRegions: { enabled: true },
  // The glyph margin is the click/hover target that advertises commenting.
  glyphMargin: true,
  // The page scrolls, not the editor: hide the editor's own vertical scrollbar
  // and let wheel events bubble so the container can be sized to content.
  scrollbar: {
    vertical: 'hidden',
    horizontal: 'auto',
    verticalScrollbarSize: 0,
    horizontalScrollbarSize: 8,
    alwaysConsumeMouseWheel: false,
    handleMouseWheel: false
  }
}

const STATUS_CLASS = { A: 'added', M: 'modified', D: 'deleted', R: 'renamed' }

function reportContentReady() {
  if (reported) return
  reported = true
  if (safetyTimer) { clearTimeout(safetyTimer); safetyTimer = null }
  postToSwift({ type: 'contentReady' })
}

// Estimate an initial container height from the line count so the editor has a
// sensible size before its diff is computed (avoids a 0px flash).
function calculateEditorHeight(originalText, modifiedText) {
  const origLines = originalText ? originalText.split('\n').length : 0
  const modLines = modifiedText ? modifiedText.split('\n').length : 0
  const lines = Math.max(origLines, modLines) + PADDING_LINES
  return Math.max(lines * LINE_HEIGHT, MIN_EDITOR_HEIGHT)
}

// Resize a diff editor's container to fit its actual content height. This is
// what makes each editor shrink/grow to exactly its content (accounting for
// hideUnchangedRegions folding) so the stacked page has no trailing gray gap.
function resizeDiffEditor(diffEditor, host) {
  const modifiedEditor = diffEditor.getModifiedEditor()
  const contentHeight = modifiedEditor.getContentHeight()
  const newHeight = Math.max(contentHeight + HEIGHT_PADDING, MIN_EDITOR_HEIGHT)
  host.style.height = `${newHeight}px`
  diffEditor.layout()
}

function disposeSection(entry) {
  if (entry.editor) entry.editor.dispose()
  if (entry.original) entry.original.dispose()
  if (entry.modified) entry.modified.dispose()
}

function clearDiffs() {
  for (const entry of sections.values()) disposeSection(entry)
  sections.clear()
  // The zone ids died with their editors. Drop them without touching
  // commentsByFile: Swift owns that, and the next render must still find it.
  // Bare assignment, not closeInputZone() — the editors are already disposed.
  commentZones.clear()
  inputZoneState = null
  // Remove every child except the empty-state placeholder.
  for (const child of Array.from(container.children)) {
    if (child !== emptyState) child.remove()
  }
}

function makeHeader(file) {
  const header = document.createElement('div')
  header.className = 'diff-header'

  const badge = document.createElement('span')
  badge.className = `status-badge ${STATUS_CLASS[file.status] || 'modified'}`
  badge.textContent = file.status || 'M'
  header.appendChild(badge)

  const path = document.createElement('span')
  path.className = 'file-path'
  path.textContent = file.filePath
  header.appendChild(path)

  // Copy button: always visible next to the file path, copies the full relative
  // path and flashes a checkmark as confirmation (Swift performs the actual
  // pasteboard write via the copyPath message; the DOM icon is just feedback).
  const copy = document.createElement('button')
  copy.className = 'copy-btn'
  copy.type = 'button'
  copy.title = STR.copyFile
  copy.setAttribute('aria-label', STR.copyFile)

  const copyIcon = document.createElementNS('http://www.w3.org/2000/svg', 'svg')
  copyIcon.setAttribute('viewBox', '0 0 16 16')
  copyIcon.classList.add('icon-copy')
  copyIcon.innerHTML =
    '<path d="M0 6.75C0 5.784.784 5 1.75 5h1.5a.75.75 0 0 1 0 1.5h-1.5a.25.25 0 0 0-.25.25v6.5c0 .138.112.25.25.25h6.5a.25.25 0 0 0 .25-.25v-1.5a.75.75 0 0 1 1.5 0v1.5A1.75 1.75 0 0 1 8.25 15h-6.5A1.75 1.75 0 0 1 0 13.25Zm5-5C5 .784 5.784 0 6.75 0h7.5C15.216 0 16 .784 16 1.75v7.5A1.75 1.75 0 0 1 14.25 11h-7.5A1.75 1.75 0 0 1 5 9.25Zm1.75-.25a.25.25 0 0 0-.25.25v7.5c0 .138.112.25.25.25h7.5a.25.25 0 0 0 .25-.25v-7.5a.25.25 0 0 0-.25-.25Z" />'
  const checkIcon = document.createElementNS('http://www.w3.org/2000/svg', 'svg')
  checkIcon.setAttribute('viewBox', '0 0 16 16')
  checkIcon.classList.add('icon-check')
  checkIcon.innerHTML =
    '<path d="M13.78 4.22a.75.75 0 0 1 0 1.06l-7.25 7.25a.75.75 0 0 1-1.06 0L2.22 9.28a.751.751 0 0 1 1.06-1.06L6 10.94l6.72-6.72a.75.75 0 0 1 1.06 0Z" />'

  const reset = () => {
    copy.classList.remove('copied')
    copy.title = STR.copyFile
    copy.setAttribute('aria-label', STR.copyFile)
  }
  copy.addEventListener('click', () => {
    postToSwift({ type: 'copyPath', filePath: file.filePath })
    copy.classList.add('copied')
    copy.title = STR.copied
    copy.setAttribute('aria-label', STR.copied)
    setTimeout(reset, 1500)
  })

  copy.appendChild(copyIcon)
  copy.appendChild(checkIcon)
  header.appendChild(copy)

  return header
}

// Build a real Monaco diff editor into `host` for the given file content.
function mountDiffEditor(host, file) {
  const original = monaco.editor.createModel(file.originalText ?? '', file.languageId || 'plaintext')
  const modified = monaco.editor.createModel(file.modifiedText ?? '', file.languageId || 'plaintext')

  const diffEditor = monaco.editor.createDiffEditor(host, sharedDiffOptions)
  diffEditor.setModel({ original, modified })

  // handleMouseWheel is off so vertical wheel events bubble to the page (the
  // page scrolls between files). But that also swallows horizontal gestures, so
  // route horizontal-dominant wheel events (trackpad swipe, shift+scroll) into
  // the diff editor's horizontal scroll. Vertical-dominant events are left to
  // the page so browsing between files keeps working.
  host.addEventListener('wheel', (e) => {
    const horizontalIntent = e.shiftKey && e.deltaY !== 0
    const dominantX = Math.abs(e.deltaX) > Math.abs(e.deltaY)
    if (!horizontalIntent && !dominantX) return
    const delta = scaleWheelDelta(
      horizontalIntent ? e.deltaY : e.deltaX,
      e.deltaMode
    )
    if (delta === 0) return
    const modifiedEditor = diffEditor.getModifiedEditor()
    modifiedEditor.setScrollLeft(modifiedEditor.getScrollLeft() + delta)
    e.preventDefault()
  })

  return { editor: diffEditor, original, modified }
}

// Normalize a wheel delta to pixels. Line-based (mouse wheels) and page-based
// deltas arrive unscaled in WKWebView; Monaco expects pixel deltas.
function scaleWheelDelta(raw, deltaMode) {
  if (deltaMode === WheelEvent.DOM_DELTA_LINE) return raw * LINE_HEIGHT
  if (deltaMode === WheelEvent.DOM_DELTA_PAGE) return raw * 100
  return raw
}

// --- Comment zones ---
// Every zone lives in the modified editor: with renderSideBySide off there is
// only one visible editor, and deleted lines render there as inline view zones.

// Anchor an old-side (deleted) line to the modified-editor line its block
// renders after. A pure deletion reports modifiedEndLineNumber === 0 and its
// block is drawn after modifiedStartLineNumber; a modification block occupies
// modifiedStart..modifiedEnd, so its comment belongs below the last line.
// Returns 0 (above the first line) when the line is no longer in any change.
function anchorForOldLine(diffEditor, oldLine) {
  const changes = diffEditor.getLineChanges() || []
  for (const ch of changes) {
    if (ch.originalStartLineNumber <= oldLine && oldLine <= ch.originalEndLineNumber) {
      return ch.modifiedEndLineNumber === 0
        ? ch.modifiedStartLineNumber
        : ch.modifiedEndLineNumber
    }
  }
  return 0
}

function buildCommentNode(comment) {
  const node = document.createElement('div')
  node.className = 'review-comment'
  // Keep clicks on the comment block from re-triggering the editor's mouse
  // handling (which would read this zone as a deletion block and open an input).
  node.addEventListener('mousedown', (e) => e.stopPropagation())

  if (comment.isOrphaned) {
    const badge = document.createElement('span')
    badge.className = 'review-orphaned'
    badge.textContent = STR.commentOrphaned
    node.appendChild(badge)
  }

  const text = document.createElement('span')
  text.className = 'review-text'
  text.textContent = comment.text
  node.appendChild(text)

  const edit = document.createElement('button')
  edit.type = 'button'
  edit.className = 'review-btn'
  edit.textContent = STR.commentEdit
  edit.addEventListener('click', () => openInputZone(comment.filePath, {
    side: comment.side,
    line: comment.line,
    endLine: comment.endLine ?? null,
    lineText: comment.lineText,
    // An orphan renders pinned at the top; its input must open there too, not
    // at the stale line the comment no longer corresponds to.
    isOrphaned: comment.isOrphaned,
    editingId: comment.id,
    initialText: comment.text
  }))
  node.appendChild(edit)

  const del = document.createElement('button')
  del.type = 'button'
  del.className = 'review-btn review-btn-delete'
  del.textContent = STR.commentDelete
  del.addEventListener('click', () => postToSwift({ type: 'commentDeleted', id: comment.id }))
  node.appendChild(del)

  return node
}

// Rebuild every comment zone for one file. Called from setComments (state
// changed) and from onDidUpdateDiff (the geometry the anchors depend on
// changed — old-side anchors need the computed diff, and hideUnchangedRegions
// re-folding invalidates earlier zone placement).
function renderComments(filePath) {
  if (renderingFor === filePath) return
  const entry = sections.get(filePath)
  if (!entry || !entry.editor) return

  const previous = renderingFor
  renderingFor = filePath
  try {
    const modified = entry.editor.getModifiedEditor()
    const list = commentsByFile.get(filePath) || []
    const existing = commentZones.get(filePath) || []
    const added = []
    modified.changeViewZones((accessor) => {
      for (const id of existing) accessor.removeZone(id)
      for (const comment of list) {
        let afterLine
        if (comment.isOrphaned) {
          afterLine = 0 // pin orphans above the first line of the file's diff
        } else if (comment.side === 'old') {
          afterLine = anchorForOldLine(entry.editor, comment.endLine ?? comment.line)
        } else {
          afterLine = comment.endLine ?? comment.line
        }
        added.push(accessor.addZone({
          afterLineNumber: afterLine,
          heightInLines: 2,
          domNode: buildCommentNode(comment),
          showInHiddenAreas: true
        }))
      }
    })
    commentZones.set(filePath, added)
    // The zones changed the content height; re-fit the section to it.
    resizeDiffEditor(entry.editor, entry.host.querySelector('.diff-body') || entry.host)
  } finally {
    renderingFor = previous
  }
}

function closeInputZone() {
  if (!inputZoneState) return
  const state = inputZoneState
  inputZoneState = null
  const entry = sections.get(state.filePath)
  if (entry && entry.editor) {
    entry.editor.getModifiedEditor().changeViewZones((a) => a.removeZone(state.zoneId))
    // Shrink the section back: a cancelled input produces no setComments, so
    // this is the only chance to reclaim the space the zone took.
    resizeDiffEditor(entry.editor, entry.host.querySelector('.diff-body') || entry.host)
  }
}

// Open the single comment input zone. spec: {side, line, endLine, lineText,
// editingId?, initialText?}. Submitting posts to Swift and closes; Swift
// answers with setComments, which is what actually renders the comment.
function openInputZone(filePath, spec) {
  closeInputZone()
  const entry = sections.get(filePath)
  if (!entry || !entry.editor) return
  const modified = entry.editor.getModifiedEditor()

  const node = document.createElement('div')
  node.className = 'review-input'
  node.addEventListener('mousedown', (e) => e.stopPropagation())

  const field = document.createElement('input')
  field.type = 'text'
  field.placeholder = STR.addComment
  field.value = spec.initialText || ''
  node.appendChild(field)

  const confirm = document.createElement('button')
  confirm.type = 'button'
  confirm.className = 'review-btn'
  confirm.textContent = spec.editingId ? STR.commentSave : STR.commentAdd
  node.appendChild(confirm)

  const cancel = document.createElement('button')
  cancel.type = 'button'
  cancel.className = 'review-btn'
  cancel.textContent = STR.commentCancel
  cancel.addEventListener('click', closeInputZone)
  node.appendChild(cancel)

  const submit = () => {
    const text = field.value.trim()
    if (!text) { closeInputZone(); return }
    if (spec.editingId) {
      postToSwift({ type: 'commentEdited', id: spec.editingId, text })
    } else {
      const msg = {
        type: 'commentAdded',
        filePath,
        side: spec.side,
        line: spec.line,
        lineText: spec.lineText || '',
        text
      }
      if (spec.endLine) msg.endLine = spec.endLine
      postToSwift(msg)
    }
    closeInputZone()
    // Swift responds with setComments, which re-renders the zones.
  }
  confirm.addEventListener('click', submit)
  field.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') { e.preventDefault(); submit() }
    if (e.key === 'Escape') { e.preventDefault(); closeInputZone() }
  })

  // Mirrors renderComments' anchoring so the input opens exactly where the
  // comment it edits sits (an orphan is pinned above the first line).
  let afterLine
  if (spec.isOrphaned) {
    afterLine = 0
  } else if (spec.side === 'old') {
    afterLine = anchorForOldLine(entry.editor, spec.endLine ?? spec.line)
  } else {
    afterLine = spec.endLine ?? spec.line
  }

  modified.changeViewZones((accessor) => {
    const zoneId = accessor.addZone({ afterLineNumber: afterLine, heightInLines: 2, domNode: node, showInHiddenAreas: true })
    inputZoneState = { filePath, zoneId }
  })
  resizeDiffEditor(entry.editor, entry.host.querySelector('.diff-body') || entry.host)
  setTimeout(() => field.focus())
}

// Wire the gutter/deleted-block click targets for one mounted editor.
function attachCommentHandlers(filePath, diffEditor) {
  const modified = diffEditor.getModifiedEditor()
  const MT = monaco.editor.MouseTargetType

  // A selection that ends at column 1 stops *above* its last line — Monaco's
  // own line-number selection (selectOnLineNumbers) makes a single gutter click
  // Range(N,1,N+1,1), which is one line, not two. Normalize before any
  // multi-line test, at both the cache write and the gutter read: without it
  // every gutter click reads as a 2-line range, and a real range selection is
  // replaced by the click that was meant to comment on it.
  const normEnd = (s) => (s.endColumn === 1 ? s.endLineNumber - 1 : s.endLineNumber)

  // Remember the last multi-line selection rather than reading the selection
  // inside onMouseDown: Monaco runs its line-selection before emitting
  // onMouseDown, so by then the live selection is already the clicked line.
  let lastRange = null
  modified.onDidChangeCursorSelection((e) => {
    const s = e.selection
    if (!s) return
    const end = normEnd(s)
    if (end > s.startLineNumber) {
      lastRange = { startLineNumber: s.startLineNumber, endLineNumber: end }
      return
    }
    // The selection collapsed. Clearing unconditionally would kill the whole
    // gesture: the consuming click itself collapses the selection before
    // onMouseDown fires. A collapse landing *inside* the cached range is
    // indistinguishable from — and usually is — that click's own artifact, and
    // a deliberate later click inside a still-cached range is precisely the
    // range-comment gesture. A collapse outside it is a real new cursor
    // placement, so the cache is stale and goes.
    const inside = lastRange &&
      s.startLineNumber >= lastRange.startLineNumber &&
      s.startLineNumber <= lastRange.endLineNumber
    if (!inside) lastRange = null
  })

  modified.onMouseDown((e) => {
    const t = e.target
    if (t.type === MT.GUTTER_LINE_NUMBERS || t.type === MT.GUTTER_GLYPH_MARGIN) {
      // New-side comment. If the click lands inside a multi-line selection,
      // comment on the whole selected range (select-then-click = range comment).
      if (!t.position) return
      const line = t.position.lineNumber
      // Prefer a live multi-line selection; fall back to the cache, which is
      // what survives the consuming click's own collapse. Both are normalized.
      const live = modified.getSelection()
      const liveEnd = live ? normEnd(live) : 0
      const sel = (live && liveEnd > live.startLineNumber)
        ? { startLineNumber: live.startLineNumber, endLineNumber: liveEnd }
        : lastRange

      let start = line
      let end = null
      if (sel && line >= sel.startLineNumber && line <= sel.endLineNumber) {
        start = sel.startLineNumber
        end = sel.endLineNumber
        lastRange = null // the range is consumed; the next click is single-line
      }
      const lineText = modified.getModel().getLineContent(start).trim()
      openInputZone(filePath, { side: 'new', line: start, endLine: end, lineText })
    } else if (t.type === MT.GUTTER_VIEW_ZONE || t.type === MT.CONTENT_VIEW_ZONE) {
      // A deleted block rendered inline. Comment on the whole old-side block.
      const after = t.detail && typeof t.detail.afterLineNumber === 'number'
        ? t.detail.afterLineNumber
        : null
      if (after === null) return
      const changes = diffEditor.getLineChanges() || []
      const ch = changes.find(c => c.modifiedEndLineNumber === 0 && c.modifiedStartLineNumber === after)
      if (!ch) return // not a deletion zone (e.g. one of our own comment zones)
      const original = diffEditor.getOriginalEditor().getModel()
      const lineText = original.getLineContent(ch.originalStartLineNumber).trim()
      openInputZone(filePath, {
        side: 'old',
        line: ch.originalStartLineNumber,
        endLine: ch.originalEndLineNumber > ch.originalStartLineNumber ? ch.originalEndLineNumber : null,
        lineText
      })
    }
  })
}

window.diffAPI = {
  setFiles(files) {
    reported = false
    if (safetyTimer) { clearTimeout(safetyTimer); safetyTimer = null }
    clearDiffs()

    if (!files || files.length === 0) {
      emptyState.classList.add('visible')
      reportContentReady()
      return
    }
    emptyState.classList.remove('visible')

    // Count only the files that will actually compute a diff (normal files).
    pendingCount = files.filter(f => !f.binary && !f.deferred).length

    // Safety: report ready after 5s even if some onDidUpdateDiff never fires.
    safetyTimer = setTimeout(reportContentReady, 5000)

    for (const file of files) {
      const section = document.createElement('div')
      section.className = 'diff-section'
      section.appendChild(makeHeader(file))

      if (file.binary) {
        const note = document.createElement('div')
        note.className = 'placeholder placeholder-binary'
        note.textContent = STR.binary
        section.appendChild(note)
        container.appendChild(section)
        sections.set(file.filePath, { host: section, editor: null })
        continue
      }

      if (file.deferred) {
        const note = document.createElement('div')
        note.className = 'placeholder placeholder-large'
        note.textContent = STR.largeFile.replace('%d', file.changedLines ?? 0)
        note.setAttribute('role', 'button')
        note.tabIndex = 0
        const request = () => {
          if (note.dataset.loading === '1') return
          note.dataset.loading = '1'
          note.classList.add('loading')
          postToSwift({ type: 'loadFile', filePath: file.filePath })
        }
        note.addEventListener('click', request)
        note.addEventListener('keydown', (e) => {
          if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); request() }
        })
        section.appendChild(note)
        container.appendChild(section)
        sections.set(file.filePath, { host: section, editor: null })
        continue
      }

      const host = document.createElement('div')
      host.className = 'diff-body'
      // Initial estimate; refined to exact content height in onDidUpdateDiff.
      host.style.height = `${calculateEditorHeight(file.originalText, file.modifiedText)}px`
      section.appendChild(host)
      container.appendChild(section)

      const mounted = mountDiffEditor(host, file)
      mounted.host = section
      attachCommentHandlers(file.filePath, mounted.editor)
      // Registered before the diff callback so renderComments() can find it.
      sections.set(file.filePath, mounted)

      // Once the diff is computed (and unchanged regions folded), size the
      // container to the exact content height so no empty editor area remains.
      mounted.editor.onDidUpdateDiff(() => {
        resizeDiffEditor(mounted.editor, host)
        // Comments already pushed by Swift render here: setComments can land
        // before this editor has a computed diff to anchor against.
        renderComments(file.filePath)
        pendingCount--
        if (pendingCount <= 0) reportContentReady()
      })
    }

    // No normal editors to wait on (all binary/deferred/empty) — ready now.
    if (pendingCount <= 0) reportContentReady()
  },

  // Replace a deferred file's placeholder with a real diff editor in place.
  loadFileContent(file) {
    const entry = sections.get(file.filePath)
    if (!entry || !entry.host) return
    const section = entry.host

    // Remove the placeholder note (keep the header).
    const placeholder = section.querySelector('.placeholder')
    if (placeholder) placeholder.remove()

    const host = document.createElement('div')
    host.className = 'diff-body'
    host.style.height = `${calculateEditorHeight(file.originalText, file.modifiedText)}px`
    section.appendChild(host)

    const mounted = mountDiffEditor(host, file)
    mounted.host = section
    attachCommentHandlers(file.filePath, mounted.editor)
    // Registered before the diff callback so renderComments() can find it.
    sections.set(file.filePath, mounted)
    mounted.editor.onDidUpdateDiff(() => {
      resizeDiffEditor(mounted.editor, host)
      // A deferred file's comments were held in commentsByFile while it was a
      // placeholder; this is the first chance to render them.
      renderComments(file.filePath)
    })
  },

  // Replace the rendered comment set wholesale. Swift pushes this after every
  // store mutation and right after every setFiles; JS never edits the list.
  setComments(list) {
    commentsByFile = new Map()
    for (const c of (list || [])) {
      if (!commentsByFile.has(c.filePath)) commentsByFile.set(c.filePath, [])
      commentsByFile.get(c.filePath).push(c)
    }
    closeInputZone()
    // Only already-mounted sections render now; editors still mounting pick
    // their comments up in onDidUpdateDiff.
    for (const path of sections.keys()) renderComments(path)
  },

  setStrings(strings) {
    if (!strings || typeof strings !== 'object') return
    Object.assign(STR, strings)
    if (strings.noChanges) {
      const msg = emptyState && emptyState.querySelector('.message')
      if (msg) msg.textContent = strings.noChanges
    }
  },

  setTheme(isDark) {
    configService.updateValue('workbench.colorTheme', isDark ? 'Dark Modern' : 'Light Modern')
    document.documentElement.style.colorScheme = isDark ? 'dark' : 'light'
  },

  clear() {
    clearDiffs()
    emptyState.classList.add('visible')
    reportContentReady()
  },

  layout() {
    for (const entry of sections.values()) {
      if (entry.editor) entry.editor.layout()
    }
  },

  // Scroll the diff page so the given file's section is at the top of the
  // viewport. Works for normal, binary, and deferred (placeholder) files since
  // every file registers its section element in `sections` keyed by exact path.
  scrollToFile(path) {
    const entry = sections.get(path)
    if (!entry || !entry.host) return
    entry.host.scrollIntoView({ behavior: 'smooth', block: 'start' })
  }
}

// Signal readiness to Swift (diffAPI available, no content yet).
postToSwift({ type: 'ready' })

setTimeout(() => document.body.classList.remove('loading'))
