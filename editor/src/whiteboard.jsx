// ABOUTME: The whiteboard tab's web app — mounts Excalidraw and owns the scene.
// ABOUTME: Sole writer of board.excalidraw; Swift persists what this hands over.
import React from 'react'
import { createRoot } from 'react-dom/client'
import { Excalidraw, serializeAsJSON } from '@excalidraw/excalidraw'
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

  post({
    action: 'save',
    scene: serializeAsJSON(api.getSceneElements(), api.getAppState(), files, 'local'),
  })
}

function Board() {
  return React.createElement(Excalidraw, {
    excalidrawAPI: (instance) => {
      api = instance
      restoreSavedScene()
      window.whiteboardReady = true
    },
    onChange: scheduleSave,
  })
}

// The saved scene is injected by Whiteboard.Host as a document-start user
// script. A scene that will not parse must not stop the board mounting: an
// empty canvas the user can draw on beats a blank pane with nothing on it.
function restoreSavedScene() {
  if (!window.__whiteboardInitialScene) return
  try {
    const scene = JSON.parse(window.__whiteboardInitialScene)
    api.updateScene({ elements: scene.elements || [] })
    if (scene.files) api.addFiles(Object.values(scene.files))
  } catch (e) {
    console.error('whiteboard: unreadable saved scene', e)
  }
}

createRoot(document.getElementById('board')).render(React.createElement(Board))
