// ABOUTME: The whiteboard tab's web app — mounts Excalidraw and owns the scene.
// ABOUTME: Sole writer of board.excalidraw; Swift persists what this hands over.
import React from 'react'
import { createRoot } from 'react-dom/client'
import {
  Excalidraw,
  restore,
  serializeAsJSON,
  exportToBlob,
  convertToExcalidrawElements,
} from '@excalidraw/excalidraw'
import '@excalidraw/excalidraw/index.css'

// Excalidraw fetches its fonts at runtime by URL, resolved against this. They
// are not part of the module graph, so the bundler never sees them — which is
// why vite.config.js copies them explicitly. Left unset, Excalidraw falls back
// to a CDN, and NSAllowsArbitraryLoads means that does not even fail loudly: it
// just hangs offline and renders Helvetica where Excalifont belongs.
//
// './' is the page's own directory, which is the bundle root served over
// atelier-resource://monaco/ — the same place the font copy emits into.
window.EXCALIDRAW_ASSET_PATH = './'

const post = (body) => window.webkit?.messageHandlers?.atelierWhiteboard?.postMessage(body)

// The long edge of the render. It is what a model looks at, and an unbounded
// export hands it a 4000px image for no gain.
const MAX_RENDER_EDGE = 1600
// A bound on the export, not a latency budget. See renderPng.
const RENDER_TIMEOUT_MS = 15000

let api = null
let saveTimer = null
// Which save a render belongs to. Exports are not ordered against each other, so
// a slow one can finish after a newer save; without this it would be stamped as
// matching a scene it was never rendered from.
let revision = 0

// setTimeout, deliberately, and NOT requestAnimationFrame.
//
// The webview spends most of its life parked in an offscreen window, which is
// NSWindowOcclusionState-occluded — and rAF is the one thing an occluded window
// loses. Measured: setTimeout, MessageChannel, document.fonts.ready,
// canvas.toBlob and OffscreenCanvas all keep firing there; rAF does not. A
// rAF-driven debounce would stop saving the moment the tab is closed, with no
// error and no timeout — a promise that simply never settles. See
// Whiteboard.Host.
const scheduleSave = () => {
  if (saveTimer) clearTimeout(saveTimer)
  saveTimer = setTimeout(save, 800)
}

// FileReader, not a String.fromCharCode loop over the bytes: a pasted screenshot
// is megabytes and the loop is quadratic in practice. Both work occluded; this
// one is also what the asset path already uses to get its base64.
const toDataURL = (blob) =>
  new Promise((resolve, reject) => {
    const reader = new FileReader()
    reader.onload = () => resolve(reader.result)
    reader.onerror = () => reject(reader.error)
    reader.readAsDataURL(blob)
  })

// Reads each asset back and re-inlines it as a real data URL, FOR THE EXPORT
// CALL ONLY.
//
// An asset-scheme image taints the export canvas: Excalidraw constructs its
// `Image` with no `crossOrigin`, so exportToBlob fails outright with
// SecurityError — the whole render, not just the image. Measured against 0.18.1.
// The nasty part is that it is invisible in the session the image is pasted in,
// because a fresh paste is already a data: URL; it appears only after a relaunch,
// when the board rebuilds its files map from assets/.
//
// Needs Access-Control-Allow-Origin on Whiteboard.AssetSchemeHandler's response
// or the fetch fails first. Neither half works alone.
//
// The bytes reach a canvas and nowhere else. board.excalidraw still gets {}.
const inlineFiles = async (files) => {
  const out = {}
  for (const [id, file] of Object.entries(files || {})) {
    if (typeof file.dataURL === 'string' && file.dataURL.startsWith('data:')) {
      out[id] = file
      continue
    }
    // Per file, so one unreadable asset costs its own image and not the whole
    // render. Without this a single failed fetch throws out of the export, and
    // because every later save re-fetches the same file the board would report
    // "stale" for the rest of the session with nothing naming the cause.
    try {
      const blob = await (await fetch(file.dataURL)).blob()
      out[id] = { ...file, dataURL: await toDataURL(blob) }
    } catch (e) {
      console.error('whiteboard: could not inline asset', id, String(e))
    }
  }
  return out
}

// Renders the board and hands it to Swift under the revision it came from.
//
// Three things here are load-bearing:
//
// 1. NO requestAnimationFrame anywhere on this path. The webview spends most of
//    its life parked in an occluded offscreen window, where rAF never fires —
//    and exportToBlob does not await one, which is the only reason a board with
//    no tab open can be rendered at all. See Whiteboard.Host.
// 2. The timeout is a Promise.race on setTimeout, which does fire occluded. It
//    exists for exactly the failure mode above: a promise that never settles has
//    no error and no timeout of its own, so without this a wedged export would
//    leave the render permanently stale with nothing said anywhere.
// 3. The revision guard, checked here and again on the Swift side.
const renderPng = async (rev) => {
  // An empty board has no picture worth keeping, and the digest says "empty"
  // rather than pointing at one.
  if (!api || api.getSceneElements().length === 0) return
  try {
    const files = await inlineFiles(api.getFiles())
    const blob = await Promise.race([
      exportToBlob({
        elements: api.getSceneElements(),
        appState: { ...api.getAppState(), exportBackground: true },
        files,
        maxWidthOrHeight: MAX_RENDER_EDGE,
        mimeType: 'image/png',
      }),
      new Promise((_, reject) =>
        setTimeout(
          () => reject(new Error(`export did not finish within ${RENDER_TIMEOUT_MS}ms`)),
          RENDER_TIMEOUT_MS
        )
      ),
    ])
    if (rev !== revision) return
    const bitmap = await createImageBitmap(blob)
    const dataURL = await toDataURL(blob)
    post({
      action: 'render',
      rev: String(rev),
      ok: 'true',
      width: String(bitmap.width),
      height: String(bitmap.height),
      data: dataURL.slice(dataURL.indexOf(',') + 1),
    })
  } catch (e) {
    console.error('whiteboard: png export failed', e)
    post({ action: 'render', rev: String(rev), ok: 'false', reason: String(e) })
  }
}

// File ids whose bytes have already been posted to Swift this session.
//
// Without it, save()'s loop re-posted the base64 of EVERY image pasted this
// session on EVERY 800ms save, and Bridge rewrote each to disk — so a board
// with several screenshots paid megabytes of bridge traffic per edit, forever.
//
// Safe as a plain Set because a fileId is a SHA-1 of the bytes — Excalidraw's
// own convention, and the one Whiteboard.Capture.fileID follows deliberately so
// a pasted and a captured image are named by one rule. The name is therefore
// content-addressed: "already written" cannot go stale for the same id, because
// the same id can never mean different bytes.
//
// Correctness does NOT rest on the write having succeeded, which is the thing
// to check before touching this. The page never reads back from assets/ in the
// session it pasted in: Excalidraw keeps the image in its own files map as the
// data: URL it already has, the export path re-inlines from that same map
// (inlineFiles skips anything already `data:`), and assets/ is only read on the
// NEXT mount, by savedFiles(). So a skipped re-post costs nothing this session
// even if the write failed, and a genuinely lost asset is a board relaunched
// after a failed disk write — which is what that failure means either way.
//
// What it does give up, stated rather than hidden: a failed write is no longer
// retried by the next save. That retry was an accident of the loop rather than
// a policy, and nothing recoverable is lost by it — Store.writeAsset fails
// either with unsafeName, which is deterministic and would fail identically
// every 800ms forever, or because the disk write failed, which re-posting
// megabytes on a timer does not fix. Both are logged.
const writtenAssets = new Set()

const save = () => {
  if (!api) return
  const rev = ++revision
  const files = api.getFiles() || {}

  // Image bytes are written to assets/ and kept out of the scene file — the
  // same separation Excalidraw's own `files` map makes. Inlining them would put
  // base64 image data in the file PR 2's digest is generated from.
  for (const [id, file] of Object.entries(files)) {
    if (writtenAssets.has(id)) continue
    // No comma means an asset-scheme URL rather than bytes: a file already in
    // assets/, rebuilt by savedFiles() on reload or placed by the capture arm.
    // There is nothing to write, and this predates the skip above — do not fold
    // the two together, they refuse for different reasons.
    const comma = file.dataURL.indexOf(',')
    if (comma < 0) continue
    const ext = (file.mimeType || 'image/png').split('/')[1] || 'png'
    post({ action: 'saveAsset', id, ext, data: file.dataURL.slice(comma + 1) })
    writtenAssets.add(id)
  }

  // An EMPTY files map, deliberately. serializeAsJSON inlines every file an
  // image element references as a base64 data URL, so passing `files` here puts
  // the bytes straight into board.excalidraw — which is the thing assets/ exists
  // to prevent, and what would later blow an agent's context when the digest is
  // generated from this file. The bytes were just written to assets/ above, and
  // Whiteboard.Host hands them back as asset-scheme URLs on the next load.
  post({
    action: 'save',
    rev: String(rev),
    scene: serializeAsJSON(api.getSceneElements(), api.getAppState(), {}, 'local'),
  })

  // Deliberately not awaited, and deliberately after the scene post rather than
  // folded into it.
  //
  // Coupling the scene write to the export would put the board's only
  // persistence guarantee behind a promise that has a documented way of never
  // settling. Kept apart, the worst an export can do is leave the render stale —
  // which is a state the digest already reports in words.
  renderPng(rev)
}

// The saved scene reaches Excalidraw as `initialData`, which is the prop it is
// for — NOT as an updateScene call from the excalidrawAPI callback.
//
// That callback fires while the component is still mounting, and a scene pushed
// in from there is discarded by Excalidraw's own initialization a moment later:
// the board comes up empty, with no error anywhere. Verified against 0.18.1.
//
// `restore` normalizes what was parsed — filling defaults and migrating older
// shapes — so a board saved by one Excalidraw version still opens under the
// next. A scene that will not parse must not stop the board mounting: an empty
// canvas the user can draw on beats a blank pane.
function savedScene() {
  if (!window.__whiteboardInitialScene) return null
  try {
    return restore(JSON.parse(window.__whiteboardInitialScene), null, null)
  } catch (e) {
    console.error('whiteboard: unreadable saved scene', e)
    return null
  }
}

// Rebuilds the files map from what Whiteboard.Host found in assets/.
//
// Excalidraw takes each file's bytes through `dataURL`, but it uses the value
// as an image source — so an asset-scheme URL serves the same purpose without
// any of the bytes travelling through JavaScript. That is what keeps a board
// with a dozen screenshots from injecting tens of megabytes of base64 at
// document start.
const assetMimeTypes = {
  jpg: 'image/jpeg',
  jpeg: 'image/jpeg',
  svg: 'image/svg+xml',
}

function savedFiles() {
  const base = window.__whiteboardAssetBase
  const names = window.__whiteboardAssets || []
  if (!base || !names.length) return {}
  const files = {}
  for (const name of names) {
    const dot = name.lastIndexOf('.')
    if (dot <= 0) continue
    const id = name.slice(0, dot)
    const ext = name.slice(dot + 1).toLowerCase()
    files[id] = {
      id,
      // `image/svg` is not a media type and Excalidraw does not accept one:
      // an SVG asset has to come back as `image/svg+xml` or the image is lost
      // on reload. jpg/jpeg is the same class of mapping, already here.
      mimeType: assetMimeTypes[ext] || `image/${ext}`,
      dataURL: base + name,
      created: Date.now(),
    }
  }
  return files
}

const restored = savedScene()
const initialData = restored
  ? { ...restored, files: { ...savedFiles(), ...(restored.files || {}) } }
  : null

function Board() {
  return React.createElement(Excalidraw, {
    initialData,
    excalidrawAPI: (instance) => {
      api = instance
      window.whiteboardReady = true
    },
    onChange: scheduleSave,
  })
}

createRoot(document.getElementById('board')).render(React.createElement(Board))

// ---------------------------------------------------------------------------
// The agent write path.
//
// Swift validates and normalizes the vocabulary (box / note / text / arrow,
// positions, colours, ids); this half EXPANDS, by calling Excalidraw's own
// `convertToExcalidrawElements`. Nothing here hand-writes `seed`,
// `versionNonce`, `groupIds` or `boundElements` — that is the whole reason the
// split falls here.
//
// Reached with `callAsyncJavaScript`, NOT `evaluateJavaScript`: the latter does
// not await a returned promise, it hands back the promise object itself, which
// reads as success the instant it is called. Arguments arrive as real JS values
// through that call's own marshalling, so there is no interpolation and no
// base64 — the quoting problem `Whiteboard.Host.initialSceneScript` solves for a
// document-start script does not arise here.

// The live element ids, and where the next unpositioned element should go.
//
// Read from the PAGE and never from board.excalidraw, because the file lags the
// page by the 800ms save debounce: an agent that adds a box and then updates it
// would otherwise be refused for naming an id that is plainly on the board.
//
// The layout travels with the ids because Swift cannot compute it — a board's
// extent is live state — and because both are answers to the same instant.
// imageIDs rides along because a CAPTION belongs on an image and nowhere else,
// and Swift cannot tell one element from another — it never reads the scene. It
// is a subset of ids, not a replacement for it: Whiteboard.Write still checks
// membership of ids first, so an id that is on neither list is reported as
// unknown rather than as the wrong kind.
window.__whiteboardState = () => {
  if (!api) return null
  const els = api.getSceneElements()
  if (!els.length) return { ids: [], imageIDs: [], originX: 100, nextY: 100 }
  return {
    ids: els.map((el) => el.id),
    imageIDs: els.filter((el) => el.type === 'image').map((el) => el.id),
    originX: Math.min(...els.map((el) => el.x)),
    nextY: Math.max(...els.map((el) => el.y + (el.height || 0))) + 60,
  }
}

// Excalidraw stores a container's label as a SEPARATE text element carrying
// `containerId`, not as a field on the shape — the same join
// Whiteboard.SceneLoad.labels makes when reading. So updating a box's text
// means finding that child, and updating a bare text element means changing the
// element itself.
const nonce = () => Math.floor(Math.random() * 2 ** 31)

// Where an arrow between two shapes actually starts and ends.
//
// Excalidraw binds an arrow to its endpoints but DOES NOT move it to them.
// MEASURED against 0.18.1: an arrow handed (0,0) with both bindings resolved
// stays at (0,0) with a stub 100px segment — correctly bound in the data model
// and visibly pointing nowhere near the two shapes it claims to connect. The
// digest would report `n1 -> n2` and the picture would disagree, which is the
// worst shape a board can be in, since the two halves of the read path are
// supposed to corroborate each other.
//
// So geometry is computed here rather than in Swift, and that is not a split of
// convenience: an arrow may name an endpoint already on the board, whose
// position Swift has no way to know. The page does.
const edgePoints = (a, b) => {
  const ca = { x: a.x + (a.width || 0) / 2, y: a.y + (a.height || 0) / 2 }
  const cb = { x: b.x + (b.width || 0) / 2, y: b.y + (b.height || 0) / 2 }
  const dx = cb.x - ca.x
  const dy = cb.y - ca.y
  // The dominant axis decides which pair of faces to join, which is what makes
  // a left-to-right row of boxes join side-to-side rather than corner-to-corner.
  if (Math.abs(dx) >= Math.abs(dy)) {
    const sx = dx >= 0 ? a.x + (a.width || 0) : a.x
    const ex = dx >= 0 ? b.x : b.x + (b.width || 0)
    return { start: { x: sx, y: ca.y }, end: { x: ex, y: cb.y } }
  }
  const sy = dy >= 0 ? a.y + (a.height || 0) : a.y
  const ey = dy >= 0 ? b.y : b.y + (b.height || 0)
  return { start: { x: ca.x, y: sy }, end: { x: cb.x, y: ey } }
}

// Re-runs edgePoints for every arrow attached to something that just moved.
//
// Excalidraw binds an arrow but never MOVES it — the same measured behaviour
// the add path works around. So moving a bound box leaves its arrow where it
// was: still bound in the data model, so the digest goes on reporting
// `n1 -> n2` quite correctly, while the picture shows an arrow pointing at
// empty space. The two halves of the read path are supposed to corroborate
// each other, so this is worse than either being wrong alone.
const reflowArrowsTouching = (elements, movedIDs) => {
  const byID = new Map(elements.map((el) => [el.id, el]))
  return elements.map((el) => {
    if (el.type !== 'arrow') return el
    const from = el.startBinding?.elementId
    const to = el.endBinding?.elementId
    if (!from || !to) return el
    if (!movedIDs.has(from) && !movedIDs.has(to)) return el
    const a = byID.get(from)
    const b = byID.get(to)
    if (!a || !b) return el
    const { start, end } = edgePoints(a, b)
    return {
      ...el,
      x: start.x,
      y: start.y,
      points: [
        [0, 0],
        [end.x - start.x, end.y - start.y],
      ],
      version: (el.version || 1) + 1,
      versionNonce: nonce(),
    }
  })
}

// Clears bindings that name an element being removed.
//
// Deleting a box leaves any arrow attached to it holding
// startBinding.elementId for an element that no longer exists. The reader
// takes that straight into the digest, which then prints an arrow whose
// endpoint id appears nowhere else on the board — the digest lying, which is
// the one thing this feature is organized around not doing. Clearing the
// binding is also Excalidraw's own semantics: the arrow survives, unattached.
// The digest then renders it as an unbound arrow, which is true.
const unbindFrom = (elements, goneIDs) =>
  elements.map((el) => {
    if (el.type !== 'arrow') return el
    const lostStart = goneIDs.has(el.startBinding?.elementId)
    const lostEnd = goneIDs.has(el.endBinding?.elementId)
    if (!lostStart && !lostEnd) return el
    return {
      ...el,
      startBinding: lostStart ? null : el.startBinding,
      endBinding: lostEnd ? null : el.endBinding,
      version: (el.version || 1) + 1,
      versionNonce: nonce(),
    }
  })

// The text element BOUND to a container, or null.
//
// Deliberately not the element itself when that element is a bare `text`: a
// bare text element IS its own words, so it has nothing hanging off it to drag
// when it moves. textTargetFor below is the other question — "what does `text`
// write to" — and the two only coincide for a labelled shape.
const boundLabelOf = (elements, element) => {
  const boundID = (element.boundElements || []).find((b) => b.type === 'text')?.id
  return (boundID && elements.find((el) => el.id === boundID)) || null
}

const textTargetFor = (elements, element) =>
  element.type === 'text' ? element : boundLabelOf(elements, element)

// Shifts a container's bound label by the same delta the container just moved.
//
// Excalidraw positions a label when it CREATES it and never again — measured
// against 0.18.1: moving four labelled containers by (+1000,+1000) through
// updateScene left all four labels at their original absolute coordinates. That
// is exactly the "binds but never moves" behaviour reflowArrowsTouching already
// works around, applied to labels: the label keeps its containerId, so the
// digest goes on reporting the box as carrying its words quite correctly, while
// the picture shows the text floating where the box used to be. Worse than
// either half being wrong alone, because the two halves of the read path exist
// to corroborate each other.
//
// SHIFTED BY THE DELTA, never recomputed from the container. Recomputing means
// reimplementing Excalidraw's own per-shape inscribed-rect maths, which it does
// not export — and measured, that maths is not plain centring: an ellipse insets
// its label (offset 90.218 where centring gives 90.0), and a diamond constrains
// the label's WRAP WIDTH instead (99.4px of a 240px diamond against 229px of a
// 240px rectangle). A delta needs to know none of it, and so stays right for
// every shape, every wrap and every verticalAlign. The same rule the add arm
// states for bindings: nothing here hand-writes geometry Excalidraw owns.
const shiftLabel = (element, dx, dy) => ({
  ...element,
  x: (element.x || 0) + dx,
  y: (element.y || 0) + dy,
  version: (element.version || 1) + 1,
  versionNonce: nonce(),
})

// A write has landed, so save NOW rather than waiting for onChange.
//
// `onChange` is Excalidraw's, and whether it fires for a programmatic
// `updateScene` in an OCCLUDED window is not a promise this feature may rest
// on — an occluded window loses requestAnimationFrame, and a save that silently
// stops happening whenever the tab is closed is precisely the failure this whole
// design is built around. Calling save() directly depends on nothing.
//
// The setTimeout(0) hop is for the other half of the same worry: `updateScene`
// is not documented to commit its scene store synchronously, and a save() called
// in the same tick could serialize the scene as it was BEFORE the write —
// answering the agent with real ids that never reach disk. setTimeout fires
// occluded (measured); rAF does not, and must never appear on this path.
//
// The pending debounced save is cleared first, so one write costs one save and
// one export rather than a second redundant render 800ms later.
const saveNow = () =>
  new Promise((resolve) => {
    if (saveTimer) clearTimeout(saveTimer)
    setTimeout(() => {
      save()
      resolve()
    }, 0)
  })

window.__whiteboardApply = async (op) => {
  if (!api) return { ok: false, reason: 'the whiteboard page has not finished mounting' }
  try {
    const existing = api.getSceneElements()

    if (op.kind === 'add') {
      const byID = new Map(existing.map((el) => [el.id, el]))
      const batchIDs = new Set(op.elements.map((el) => el.id))

      // An arrow may name an endpoint that is ALREADY on the board rather than
      // one created beside it — "connect the two boxes you can see" is the
      // obvious agent move. convertToExcalidrawElements binds only within the
      // array it is handed, so such an arrow arrives with startBinding and
      // endBinding both null: drawn, floating, and attached to nothing.
      // MEASURED against 0.18.1, and silent — the call succeeds and the arrow
      // is really on the board, just not connected to anything.
      //
      // So the referenced elements are carried INTO the array, and Excalidraw
      // computes the binding itself. Nothing here hand-writes a binding.
      const carried = []
      for (const el of op.elements) {
        for (const ref of [el.start?.id, el.end?.id]) {
          if (ref && !batchIDs.has(ref) && byID.has(ref) && !carried.some((c) => c.id === ref)) {
            carried.push(byID.get(ref))
          }
        }
      }

      // Arrow geometry, resolved against whatever the endpoints really are —
      // in this batch or already on the board. See edgePoints.
      const positioned = op.elements.map((el) => {
        if (el.type !== 'arrow' || !el.start?.id || !el.end?.id) return el
        const resolve = (id) =>
          byID.get(id) || op.elements.find((c) => c.id === id) || null
        const a = resolve(el.start.id)
        const b = resolve(el.end.id)
        if (!a || !b) return el
        const { start, end } = edgePoints(a, b)
        return {
          ...el,
          x: start.x,
          y: start.y,
          points: [
            [0, 0],
            [end.x - start.x, end.y - start.y],
          ],
        }
      })

      const converted = convertToExcalidrawElements([...carried, ...positioned], {
        regenerateIds: false,
      })
      const convertedByID = new Map(converted.map((el) => [el.id, el]))
      // Only the batch's own elements are new. A carried element is already on
      // the board and must not be added a second time.
      const fresh = converted.filter(
        (el) => batchIDs.has(el.id) || (el.containerId && batchIDs.has(el.containerId))
      )
      // A carried element keeps its own identity and geometry and takes only
      // the binding metadata the conversion computed for it. UNIONED, never
      // assigned: a carried box already carries a boundElements entry for its
      // own text label, and overwriting the list would unbind the label —
      // leaving its caption on the canvas attached to nothing.
      const merged = existing.map((el) => {
        const c = convertedByID.get(el.id)
        if (!c || batchIDs.has(el.id)) return el
        const seen = new Set()
        const bound = [...(el.boundElements || []), ...(c.boundElements || [])].filter((b) => {
          if (!b || seen.has(b.id)) return false
          seen.add(b.id)
          return true
        })
        return { ...el, boundElements: bound, version: (el.version || 1) + 1, versionNonce: nonce() }
      })

      api.updateScene({ elements: [...merged, ...fresh] })
      await saveNow()
      // The ids actually stored, not the ids asked for. If Excalidraw ever
      // stops honouring a supplied id, the answer names what really landed
      // rather than handing back ids that point at nothing.
      return { ok: true, ids: fresh.filter((el) => !el.containerId).map((el) => el.id) }
    }

    if (op.kind === 'update') {
      const target = existing.find((el) => el.id === op.id)
      if (!target) return { ok: false, unknown: [op.id] }

      // Resolved BEFORE anything is written, and a miss refuses the WHOLE op.
      //
      // textTargetFor returns null for any box, ellipse, diamond or arrow the
      // user drew without a label, and this arm used to answer `ok` having
      // changed nothing — the same silent success that `text` on an image had,
      // and which Whiteboard.Write now refuses in Swift. Swift cannot refuse
      // this one: whether an element carries a label is a fact about the live
      // scene, which only this page holds.
      //
      // Refused whole rather than partially applied, the rule the
      // arrow-cannot-bind-to-an-image case already states: an `at` + `text`
      // call that moved the element and silently dropped the words would leave
      // the board in a state the answer does not describe. Nothing below this
      // line runs, so updateScene and saveNow are never reached.
      let textEl = null
      if (op.text !== undefined) {
        textEl = textTargetFor(existing, target)
        if (!textEl) {
          // Names what can actually be done, and deliberately does NOT say
          // "add a label with whiteboard_add": that tool always mints a NEW
          // element and cannot attach words to one already on the board, so
          // advice to reach for it there is advice an agent follows into a
          // second box sitting on top of the first. The two honest paths are
          // both stated instead.
          return {
            ok: false,
            reason:
              `"${op.id}" was drawn without a label, so it carries no words on the ` +
              'canvas and there is nothing for `text` to change. Nothing can attach ' +
              'words to an element that is already on the board. Either draw a ' +
              'replacement — whiteboard_add with `text` and the same `at`, then ' +
              'whiteboard_delete this one — or add a separate text element beside it. ' +
              'read_whiteboard reports the words each element already has.',
          }
        }
      }

      // Per axis, and against the position the element is being moved FROM.
      // updatePlan always sends both, but the page has always guarded them
      // separately and a half-move must shift the label by half.
      const dx = op.x !== undefined ? op.x - (target.x || 0) : 0
      const dy = op.y !== undefined ? op.y - (target.y || 0) : 0
      const label = dx || dy ? boundLabelOf(existing, target) : null

      const next = existing.map((el) => {
        let out = el
        if (label && el.id === label.id) {
          return shiftLabel(el, dx, dy)
        }
        if (el.id === op.id) {
          out = { ...out }
          if (op.x !== undefined) out.x = op.x
          if (op.y !== undefined) out.y = op.y
          if (op.strokeColor !== undefined) out.strokeColor = op.strokeColor
          if (op.backgroundColor !== undefined) out.backgroundColor = op.backgroundColor
          if (op.caption !== undefined && op.captionKey) {
            // SPREAD, never assign. This same dictionary carries atelierKind
            // for a note and atelierAuthor for anything an agent drew, so a
            // fresh object would silently demote a note to a box in the digest
            // and disown an agent's own element — the shape of PR 3's
            // boundElements overwrite, and invisible in exactly the same way.
            const data = { ...(out.customData || {}) }
            // The KEY is not spelled here. customData keys live in exactly one
            // place, Whiteboard.Element, and this page cannot import it — so
            // Swift sends the key with the value rather than both ends carrying
            // a literal that nothing keeps in step. A rename on that side would
            // otherwise leave this writing the old key, and the caption would
            // reach the board while vanishing from the digest.
            //
            // Cleared by REMOVING the key rather than storing "": the digest
            // renders a caption line for any caption it finds, so an empty
            // string would leave a blank one under the image forever.
            if (op.caption === '') delete data[op.captionKey]
            else data[op.captionKey] = op.caption
            out.customData = data
          }
          out.version = (out.version || 1) + 1
          out.versionNonce = nonce()
        }
        return out
      })
      if (textEl) {
        // By id, not by the object resolved above: a label that also MOVED has
        // already been replaced in `next`, and writing the pre-move object back
        // would silently undo the shift.
        const i = next.findIndex((el) => el.id === textEl.id)
        // Both fields: `originalText` is the source the editor reopens with,
        // `text` is what is drawn. Setting only one leaves the board showing
        // a different string from the one the digest reports.
        next[i] = {
          ...next[i],
          text: op.text,
          originalText: op.text,
          version: (next[i].version || 1) + 1,
          versionNonce: nonce(),
        }
      }
      // A move drags every arrow attached to this element with it. The label
      // has already been dragged, above, and does not join this set: the set
      // names ids an arrow may be BOUND to, and nothing binds to a container's
      // own label, so adding it would be a no-op rather than a second reflow.
      const moved = op.x !== undefined || op.y !== undefined
      api.updateScene({
        elements: moved ? reflowArrowsTouching(next, new Set([op.id])) : next,
      })
      await saveNow()
      return { ok: true, ids: [op.id] }
    }

    // A captured screen region. Not part of the agent vocabulary — an agent
    // cannot produce image bytes — but it goes through this same function, and
    // therefore the same saveNow(), rather than growing a second write path.
    if (op.kind === 'image') {
      // The file reaches Excalidraw as an ASSET-SCHEME URL, never as bytes —
      // the same rule savedFiles() follows on reload. That is what keeps
      // board.excalidraw free of image data: save()'s saveAsset loop skips
      // anything whose dataURL has no comma in it, so these bytes are never
      // posted back, and serializeAsJSON is handed an empty files map anyway.
      api.addFiles([
        {
          id: op.fileId,
          mimeType: op.mimeType,
          dataURL: window.__whiteboardAssetBase + op.name,
          created: Date.now(),
        },
      ])
      const converted = convertToExcalidrawElements(
        [
          {
            type: 'image',
            id: op.id,
            fileId: op.fileId,
            x: op.x,
            y: op.y,
            width: op.width,
            height: op.height,
          },
        ],
        { regenerateIds: false }
      )
      api.updateScene({ elements: [...existing, ...converted] })
      await saveNow()
      // Deliberately unmarked by atelierAuthor: the user pressed the button, so
      // the digest must not report this as something an agent put there.
      return { ok: true, ids: converted.map((el) => el.id) }
    }

    if (op.kind === 'delete') {
      const present = new Set(existing.map((el) => el.id))
      // An id that is already gone is SUCCESS, not a refusal — that is what
      // makes whiteboard_delete safe to replay after a lost connection.
      const removed = op.ids.filter((id) => present.has(id))
      const doomed = new Set(removed)
      // A container's bound label is a separate element; leaving it behind
      // would strand a text element with a containerId pointing at nothing.
      for (const el of existing) {
        if (el.containerId && doomed.has(el.containerId)) doomed.add(el.id)
      }
      if (removed.length) {
        const survivors = existing.filter((el) => !doomed.has(el.id))
        api.updateScene({ elements: unbindFrom(survivors, doomed) })
        await saveNow()
      }
      return { ok: true, ids: removed }
    }

    return { ok: false, reason: `unknown operation ${op.kind}` }
  } catch (e) {
    console.error('whiteboard: apply failed', e)
    return { ok: false, reason: String(e) }
  }
}
