// Shared VS Code service initialization for both the editor (main.js) and the
// diff view (diff.js). Extracts the duplicated setup: extension resource URL
// capture, worker config, service init, theme setup, and the JS ↔ Swift bridge.
//
// Importing this module runs the full initialization (top-level await) and
// exports the live `monaco` namespace, the `configService`, and `postToSwift`.

import { initialize, getService } from '@codingame/monaco-vscode-api'
import { IExtensionResourceLoaderService } from '@codingame/monaco-vscode-api/vscode/vs/platform/extensionResourceLoader/common/extensionResourceLoader.service'
import { IConfigurationService } from '@codingame/monaco-vscode-api/vscode/vs/platform/configuration/common/configuration.service'
import { FileAccess } from '@codingame/monaco-vscode-api/vscode/vs/base/common/network'
import getTextmateServiceOverride from '@codingame/monaco-vscode-textmate-service-override'
import getThemeServiceOverride from '@codingame/monaco-vscode-theme-service-override'
import getLanguagesServiceOverride from '@codingame/monaco-vscode-languages-service-override'
import { MenuRegistry, MenuId } from '@codingame/monaco-vscode-api/vscode/vs/platform/actions/common/actions'
// `?url` (not a bare JSON import) so Vite emits the theme as an asset file the
// extension can be pointed at, instead of inlining it as a module.
import palenightThemeUrl from './themes/palenight.json?url'

// The two themes the app switches between. Palenight is dark-only, so light
// appearance keeps VS Code's own Light Modern. Both `main.js` and `diff.js`
// import these — a literal in either would drift from the other.
export const DARK_THEME = 'Palenight Theme'
export const LIGHT_THEME = 'Light Modern'

// --- Capture extension resource URL mappings ---
// FileAccess.uriToBrowserUri() uses a ResourceMap internally, but the URI lookup
// can fail when the theme service constructs a new URI object (different reference).
// We capture the mappings ourselves in a simple string-keyed Map.
// This MUST run before the extension imports so the map is populated.
const extensionResourceUrls = new Map()
const origRegister = FileAccess.registerStaticBrowserUri.bind(FileAccess)
FileAccess.registerStaticBrowserUri = function (uri, browserUri) {
  extensionResourceUrls.set(uri.toString(), browserUri.toString(true))
  return origRegister(uri, browserUri)
}

// Dynamic imports so they run AFTER the monkey-patch above.
// Static imports would evaluate before the module body.
await import('@codingame/monaco-vscode-all-language-default-extensions')
await import('@codingame/monaco-vscode-theme-defaults-default-extension')

// --- Palenight color theme ---
// Registered exactly the way the codingame default-extension packages register
// theirs: a manifest contributing a theme, plus a browser URL for the theme
// JSON. Vendored under src/themes/ from whizkydee/vscode-palenight-theme at
// commit 6291efa (v2.0.4, MIT — see src/themes/palenight-LICENSE.md); the
// marketplace extension is not published to npm.
//
// Must come after the registerStaticBrowserUri patch above so the theme's URL
// lands in `extensionResourceUrls` — ExtensionResourceLoader below reads it
// from there. `system: true` skips the extension-enablement machinery, which
// has no store in standalone mode.
const { registerExtension } = await import('@codingame/monaco-vscode-api/extensions')
const palenightExtension = registerExtension({
  name: 'palenight-theme',
  publisher: 'whizkydee',
  version: '2.0.4',
  license: 'MIT',
  engines: { vscode: '*' },
  categories: ['Themes'],
  contributes: {
    themes: [{
      // The theme has no `id` in its own manifest, so this label IS the
      // identifier `workbench.colorTheme` is matched against.
      label: DARK_THEME,
      uiTheme: 'vs-dark',
      path: './themes/palenight.json'
    }]
  }
}, undefined, { system: true })
palenightExtension.registerFileUrl('themes/palenight.json', palenightThemeUrl, 'application/json')

// --- JS ↔ Swift bridge ---
export function postToSwift(msg) {
  window.webkit?.messageHandlers?.editor?.postMessage(msg)
}

// Forward uncaught errors to Swift for debugging
window.onerror = (msg, src, line, col) => {
  postToSwift({ type: 'error', message: `${msg} (${src}:${line}:${col})` })
}
window.onunhandledrejection = (e) => {
  postToSwift({ type: 'error', message: `Unhandled rejection: ${e.reason}` })
}

// --- Worker setup ---
// Each language feature runs its own Web Worker for IntelliSense.
// TextMate runs grammar tokenization in a separate worker using oniguruma WASM.
// The editor worker handles diff computation, word completion, etc.
window.MonacoEnvironment = {
  getWorker(_, label) {
    if (label === 'TextMateWorker') {
      return new Worker(
        new URL('@codingame/monaco-vscode-textmate-service-override/worker', import.meta.url),
        { type: 'module' }
      )
    }
    if (label === 'typescript' || label === 'javascript') {
      return new Worker(
        new URL('@codingame/monaco-vscode-standalone-typescript-language-features/worker', import.meta.url),
        { type: 'module' }
      )
    }
    if (label === 'css' || label === 'scss' || label === 'less') {
      return new Worker(
        new URL('@codingame/monaco-vscode-standalone-css-language-features/worker', import.meta.url),
        { type: 'module' }
      )
    }
    if (label === 'html' || label === 'handlebars' || label === 'razor') {
      return new Worker(
        new URL('@codingame/monaco-vscode-standalone-html-language-features/worker', import.meta.url),
        { type: 'module' }
      )
    }
    if (label === 'json') {
      return new Worker(
        new URL('@codingame/monaco-vscode-standalone-json-language-features/worker', import.meta.url),
        { type: 'module' }
      )
    }
    return new Worker(
      new URL('monaco-editor/esm/vs/editor/editor.worker.js', import.meta.url),
      { type: 'module' }
    )
  }
}

// --- Extension resource loader for WKWebView ---
// The default readExtensionResource is "unsupported". We provide a simple
// implementation that resolves extension-file:// URIs to atelier-resource:// URLs
// using our captured mapping, then fetches via the WKURLSchemeHandler.
class ExtensionResourceLoader {
  _serviceBrand = undefined
  supportsExtensionGalleryResources = false

  async readExtensionResource(uri) {
    const uriStr = uri.toString()
    const mappedUrl = extensionResourceUrls.get(uriStr)
    if (!mappedUrl) {
      throw new Error(`No resource mapping for ${uriStr}`)
    }
    const response = await fetch(mappedUrl)
    if (!response.ok) {
      throw new Error(`Failed to load ${uriStr}: ${response.status}`)
    }
    return response.text()
  }

  async getExtensionGalleryResourceURL() {
    return undefined
  }

  getExtensionGalleryRequestHeaders() {
    return {}
  }

  async isExtensionGalleryResource() {
    return false
  }
}

// --- Initialize VS Code services ---
// MUST be called once, BEFORE creating any editor instance.
// Uses full VS Code service overrides for TextMate grammars and themes.
// Resources are served via WKURLSchemeHandler (atelier-resource://) so fetch() works.
await initialize({
  ...getTextmateServiceOverride(),
  ...getThemeServiceOverride(),
  ...getLanguagesServiceOverride(),
  [IExtensionResourceLoaderService.toString()]: new ExtensionResourceLoader()
}, undefined, {
  // initialColorTheme sets the dark appearance immediately at construction time.
  // configurationDefaults is NOT wired into the config system in standalone mode,
  // so we also force the theme via configurationService after init.
  initialColorTheme: { themeType: 'dark' }
})

// Force the dark theme via the configuration service.
// configurationDefaults doesn't work in @codingame/monaco-vscode-api standalone mode
// because DefaultConfiguration.getConfigurationDefaultOverrides() is never overridden.
const configService = await getService(IConfigurationService)
// The theme service matches by label, so the contribution has to be live before
// the value is set — otherwise nothing matches and the theme silently stays put.
// `whenReady()` waits on services, so it can only be awaited after initialize().
await palenightExtension.whenReady()
await configService.updateValue('workbench.colorTheme', DARK_THEME)

// Import monaco AFTER initialize()
const monaco = await import('monaco-editor')

// Block Monarch tokenizer registration from standalone language features.
// Their setupMode() is lazy (called via onLanguage when the first model for
// that language is created) and registers a Monarch tokenizer via
// setTokensProvider. This conflicts with the TextMate tokenizer: the
// registration fires handleChange → todo_resetTokenization before the
// TextMate grammar is loaded, crashing _toBinaryTokens. Since TextMate
// handles all syntax highlighting, we no-op setTokensProvider entirely.
// The TextMate service uses setEncodedTokensProvider (different API).
monaco.languages.setTokensProvider = () => ({ dispose() {} })

// Standalone language features — must be imported AFTER initialize() so the
// VS Code service overrides (TextMate, themes, languages) are in place.
// These restore IntelliSense (completions, hover, diagnostics) without
// needing the full extension host.
await import('@codingame/monaco-vscode-standalone-typescript-language-features')
await import('@codingame/monaco-vscode-standalone-json-language-features')
await import('@codingame/monaco-vscode-standalone-css-language-features')
await import('@codingame/monaco-vscode-standalone-html-language-features')

// Remove "Command Palette..." from the right-click context menu.
// Shared because neither the editor nor the diff view supports the command palette.
const origGetMenuItems = MenuRegistry.getMenuItems
MenuRegistry.getMenuItems = function (id) {
  const items = origGetMenuItems.call(this, id)
  if (id === MenuId.EditorContext) {
    return items.filter(item => !item.command || item.command.id !== 'workbench.action.showCommands')
  }
  return items
}

export { monaco, configService }
