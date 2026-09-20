// ABOUTME: The whiteboard tab's web app — mounts Excalidraw and owns the scene.
// ABOUTME: Sole writer of board.excalidraw; Swift persists what this hands over.
import React from 'react'
import { createRoot } from 'react-dom/client'
import { Excalidraw, restore, serializeAsJSON, exportToBlob } from '@excalidraw/excalidraw'
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

const save = () => {
  if (!api) return
  const rev = ++revision
  const files = api.getFiles() || {}

  // Image bytes are written to assets/ and kept out of the scene file — the
  // same separation Excalidraw's own `files` map makes. Inlining them would put
  // base64 image data in the file PR 2's digest is generated from.
  for (const [id, file] of Object.entries(files)) {
    const comma = file.dataURL.indexOf(',')
    if (comma < 0) continue
    const ext = (file.mimeType || 'image/png').split('/')[1] || 'png'
    post({ action: 'saveAsset', id, ext, data: file.dataURL.slice(comma + 1) })
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
      mimeType: ext === 'jpg' || ext === 'jpeg' ? 'image/jpeg' : `image/${ext}`,
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
