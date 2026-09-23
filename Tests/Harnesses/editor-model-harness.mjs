// ABOUTME: Exercises editor/src/main.js's multi-model bookkeeping — which tab
// ABOUTME: points at which Monaco model, and when a model may be disposed.
//
//   node Tests/Harnesses/editor-model-harness.mjs editor/src/main.js
//
// Exit 0 and a PASS line means every check passed.
//
// It loads the REAL source (rewriting only its one import) and runs it against
// a fake Monaco. That inverts this directory's usual rule, and deliberately:
// the whiteboard harness exists because the claims under test are claims about
// Excalidraw's own behaviour, where a mock would be a mock of the thing under
// test. Here the thing under test is this file's own bookkeeping — the
// `models` and `fileModels` maps, when `setValue` is the right answer and when
// it is not, and who may dispose a shared model. The Monaco surface that
// touches is six methods wide and none of the assertions are about what Monaco
// does with them. Run against 74cb17ab it fails six checks, one of which is
// "a later tab opening foo.swift sees foo — bar contents".
import { readFileSync } from 'node:fs'

const src = readFileSync(process.argv[2], 'utf8')
  .replace(/^import .*\n/, 'const { monaco, configService, postToSwift, DARK_THEME, LIGHT_THEME } = globalThis.__deps\n')

let seq = 0
const live = new Set()
function makeModel(text, languageId, uri) {
  const m = {
    id: ++seq, value: text, languageId, uri: uri ?? { toString: () => `inmemory://model/${seq}` },
    version: 1, disposed: false, listeners: [],
    getValue() { return this.value },
    setValue(v) { this.value = v; this.version++; this.listeners.forEach(f => f()) },
    getAlternativeVersionId() { return this.version },
    getLineCount() { return this.value.split('\n').length },
    onDidChangeContent(f) { this.listeners.push(f); return { dispose: () => { this.listeners = this.listeners.filter(g => g !== f) } } },
    dispose() { this.disposed = true; live.delete(this) },
    edit(v) { this.value = v; this.version++; this.listeners.forEach(f => f()) },
  }
  live.add(m)
  return m
}

const posts = []
const editorState = { model: null }
globalThis.__deps = {
  monaco: {
    Uri: { file: (p) => ({ toString: () => `file://${p}` }) },
    editor: {
      create: () => ({
        addCommand() {}, addAction() {}, focus() {}, layout() {},
        revealLineInCenter() {}, setPosition() {},
        setModel(m) { editorState.model = m },
      }),
      createModel: makeModel,
      setModelLanguage: (m, l) => { m.languageId = l },
    },
    KeyMod: { CtrlCmd: 1, Shift: 2 }, KeyCode: { KeyP: 3, F1: 4 },
  },
  configService: { updateValue() {} },
  postToSwift: (p) => posts.push(p),
  DARK_THEME: 'd', LIGHT_THEME: 'l',
}
globalThis.window = {}
globalThis.document = { getElementById: () => ({}), body: { classList: { remove() {} } } }

const mod = new Function(src.replace(/^const \{ monaco.*$/m, 'const { monaco, configService, postToSwift, DARK_THEME, LIGHT_THEME } = globalThis.__deps;'))
mod()
const api = globalThis.window.editorAPI

let failures = 0
function check(name, cond, detail) {
  if (cond) { console.log(`  ok   ${name}`) } else { failures++; console.log(`  FAIL ${name}${detail ? ' — ' + detail : ''}`) }
}

// --- B2: navigating a tab must not alias one model across two files ---
console.log('B2: tab navigation')
api.openFile('A', 'foo contents', 'swift', '/w/foo.swift', null)
const fooModel = editorState.model
api.openFile('A', 'bar contents', 'swift', '/w/bar.swift', null)
const barModel = editorState.model
check('navigating creates a different model', fooModel !== barModel)
check('new model holds the new file', barModel.getValue() === 'bar contents', barModel.getValue())
check("new model's uri names the new file", barModel.uri.toString() === 'file:///w/bar.swift', barModel.uri.toString())
check('sole holder of the old model disposes it', fooModel.disposed)

// a later tab opening foo.swift must get foo's contents, not bar's
api.openFile('B', 'foo contents', 'swift', '/w/foo.swift', null)
check('a later tab opening foo.swift sees foo', editorState.model.getValue() === 'foo contents', editorState.model.getValue())
check('...and not a disposed model', !editorState.model.disposed)

// --- B2b: a model another tab still holds must survive a navigation ---
console.log('B2b: shared model survives one holder navigating away')
api.openFile('C', 'shared contents', 'swift', '/w/shared.swift', null)
const shared = editorState.model
api.openFile('D', 'shared contents', 'swift', '/w/shared.swift', null)
check('second tab adopts the same model', editorState.model === shared)
api.openFile('D', 'other contents', 'swift', '/w/other.swift', null)
check('shared model is NOT disposed while C holds it', !shared.disposed)

// --- B1: adopting a dirty buffer must not mark it clean ---
console.log('B1: adopting a dirty buffer')
api.openFile('E', 'v1', 'swift', '/w/dirty.swift', null)
const dirtyModel = editorState.model
dirtyModel.edit('v2 unsaved')           // user types in tab E
const cleanBefore = dirtyModel._cleanVersionId
posts.length = 0
api.openFile('F', 'v1', 'swift', '/w/dirty.swift', null)   // agent open_editor -> new tab F
check('adopted model is the same buffer', editorState.model === dirtyModel)
check("unsaved edits survive adoption", dirtyModel.getValue() === 'v2 unsaved', dirtyModel.getValue())
check('clean baseline is NOT restamped', dirtyModel._cleanVersionId === cleanBefore)
check('adopting tab is told it is dirty',
  posts.some(p => p.type === 'contentChanged' && p.modelId === 'F' && p.dirty === true),
  JSON.stringify(posts))

// --- regression: reopening the same file in the same tab still reloads ---
console.log('same-file reopen still reloads from disk')
api.openFile('G', 'old', 'swift', '/w/g.swift', null)
const gModel = editorState.model
api.openFile('G', 'new from disk', 'swift', '/w/g.swift', null)
check('same tab + same path reuses the model', editorState.model === gModel)
check('...and takes the fresh disk text', gModel.getValue() === 'new from disk', gModel.getValue())
check('...and is stamped clean', gModel._cleanVersionId === gModel.getAlternativeVersionId())

// --- regression: closeModel still frees only unreferenced models ---
console.log('closeModel')
api.openFile('H', 'h', 'swift', '/w/h.swift', null)
const hModel = editorState.model
api.openFile('I', 'h', 'swift', '/w/h.swift', null)
api.closeModel('H')
check('model kept while another tab holds it', !hModel.disposed)
api.closeModel('I')
check('model disposed once the last tab closes', hModel.disposed)
api.openFile('J', 'h again', 'swift', '/w/h.swift', null)
check('reopening after full close creates a fresh model', !editorState.model.disposed && editorState.model.getValue() === 'h again')

console.log(failures === 0 ? '\nPASS' : `\nFAIL (${failures})`)
process.exit(failures === 0 ? 0 : 1)
