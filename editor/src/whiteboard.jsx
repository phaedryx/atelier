// ABOUTME: The whiteboard tab's web app — mounts Excalidraw and owns the scene.
// ABOUTME: Sole writer of board.excalidraw; Swift persists what this hands over.
import React from 'react'
import { createRoot } from 'react-dom/client'
import { Excalidraw, restore, serializeAsJSON } from '@excalidraw/excalidraw'
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

let api = null
let saveTimer = null

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

const save = () => {
  if (!api) return
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
    scene: serializeAsJSON(api.getSceneElements(), api.getAppState(), {}, 'local'),
  })
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
