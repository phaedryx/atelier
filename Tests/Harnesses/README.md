# Harnesses

**These are run by hand. They are not part of `./scripts/dev.sh test`.**

```bash
./scripts/build-editor.sh                        # required first — see below
swift Tests/Harnesses/whiteboard-harness.swift
```

Exit 0 and a `PASS` line means every check passed; a non-zero exit names each
check that failed.

## Why they are not XCTest

They need two things this project's XCTest host cannot give them:

- **The real built bundle.** These exercise Excalidraw's own behaviour —
  `convertToExcalidrawElements`, `restore`, `exportToBlob` — at the version the
  app actually ships. A mock of any of it would be a mock of the thing under
  test, and every bug found here has been a surprise about what Excalidraw
  really does.
- **A live `WKWebView` in a real window.** The whole whiteboard design rests on
  a webview parked in an occluded offscreen `NSWindow`, which is a genuinely
  odd environment: `requestAnimationFrame` never fires there, while
  `setTimeout`, `canvas.toBlob` and `createImageBitmap` all keep working. That
  asymmetry is the load-bearing assumption of the feature, and it can only be
  observed by putting a real page in a real offscreen window.

So the split is: anything pure — digest rendering, vocabulary validation,
scheme-handler containment, caption validation — is XCTest and belongs there.
Anything that is a claim about the *page* is here.

## Why they are committed

Three throwaway versions of this harness found **nine** silent bugs across PRs
1–3, and each one of those bugs *succeeded*: the call returned fine, the write
really happened, and the board's picture and its digest disagreed afterwards —
which is the worst state this feature reaches, because the two halves of the
read path exist to corroborate each other, so an agent checking one against the
other is reassured by the lie.

PR 3's harness died with its session before it could be committed. This one is
committed so that does not happen again.

### The rule these follow

**Every assertion reads an artifact on disk** — `board.excalidraw`, `assets/`,
`board.png` — and never the value a JavaScript call handed back. Two of the nine
bugs were found only because something looked at the file instead of the reply.

### What a clean run does *not* prove

**These harnesses play both ends**, so they cannot prove the two ends agree on a
name. The harness sends the ops Swift would send and then reads the scene with
its own expectations, and both halves are written here — so anything that is a
*shared vocabulary* between Swift and the page is spelled twice in this file and
matches itself by construction.

That is not hypothetical. The caption arm shipped into review writing
`atelierCaption` as a bare literal in `whiteboard.jsx`, breaking the rule that
`customData` keys live only in `Whiteboard.Element`. Renaming the Swift constant
would have left the page writing the old key — the caption reaching the board
and vanishing from the digest — and this harness would have reported **35/35**
throughout, because it hardcodes the same literal on the read side. The fix was
to stop the page spelling the key at all (Swift sends it with the value), and to
pin the agreement in `WhiteboardWriteTests`, which is where an assertion about
*Swift's* constant belongs.

So: a shared name goes in XCTest. This file is for what the page *does* with
what it is handed.

### It has been caught lying once

The reflow check in section 5 once reported PASS for an arrow that was not on the
board at all: `number(nil)` is `NaN`, and `NaN != NaN` is **true**, so a
"something changed" comparison succeeded against an element that did not exist.
It asserts presence first now. Recorded rather than quietly fixed, because a
harness whose failure modes are known is worth more than one reporting a clean
number nobody has examined — and because the next comparison written in here can
make the same mistake.

## `whiteboard-harness.swift`

Builds the same offscreen host `Whiteboard.Host` builds — a `.borderless`
`NSWindow` parked far off every screen and never ordered front — loads the real
whiteboard bundle into it, drives `window.__whiteboardApply`, and checks what
lands on disk.

It carries its own minimal copies of the two `WKURLSchemeHandler`s and of
`Whiteboard.Store`'s file writing, because a script cannot link the Atelier
target. Those copies are not what is under test: scheme-handler containment is
pinned by `WhiteboardAssetSchemeHandlerTests`, where it belongs.

### What it checks

**0. The harness can see the real page.** Check zero, and everything else is
abandoned if it fails — a harness that reports clean because it silently failed
to load the bundle is worse than no harness.

**1. PR 3's binding invariants.** All four were shipped bugs, and all four are
already fixed, so all four must PASS. They are here as the harness's own
negative control: if one of them fails on an untouched tree, the harness is
wrong and not the code.

- an arrow naming a box *already on the board* binds to it
- that arrow's geometry reaches its endpoints, rather than sitting at (0,0) with
  a stub segment — correctly bound and visibly pointing nowhere
- moving a bound box drags its arrows with it
- deleting a box leaves no arrow bound to the dead id

**2. `customData` survives a reload.** The gate for image captions. Every mount
runs `restore(JSON.parse(...))` over the saved scene, and PR 3 only ever
established that `customData` round-trips at *creation* time. If `restore`
normalized unknown keys away, a caption would be written, render in the digest
at once, and be gone after a relaunch. The check writes all three keys
(`atelierAuthor`, `atelierKind`, `atelierCaption`), tears the page down, builds
a **fresh** host from the scene on disk, saves again, and re-reads the file.

**3. The board still renders offscreen.** `exportToBlob` completing in an
occluded window is the assumption the entire agent-read path rests on, and it
has failed outright before — invisibly, because on disk a render that failed and
one that never arrived look identical.

**4. The caption arm.** Captions merge into `customData` rather than replacing
it, a caption write leaves every other element's bindings alone, and a caption
sent together with a move still reflows the arrows bound to what moved.

**5. The capture arm.** A placed image keeps its bytes out of
`board.excalidraw`, its `assets/` filename is its `fileId`, it does not land on
top of what is already on the board, and — the part that cannot be inherited
from PR 2 — the PNG export still succeeds afterwards. A captured image is an
asset-scheme URL from the moment it lands, unlike a pasted one, so it exercises
the export-canvas taint path in its own session rather than after a relaunch.

**6. The one known limitation, pinned so it cannot go quiet.** An arrow cannot
bind to an image — `convertToExcalidrawElements` throws for one, measured
against 0.18.1 — and what is checked is that it stays a **refusal** with the
board untouched, rather than becoming a partial apply.

**7. The update arm.** A moved labelled box drags its label with it, at the same
offset; a move and a retext in one call land both; and `text` on an element the
user drew without a label is refused with the board untouched, rather than
answering `ok` having changed nothing.

The label check asserts the **offset**, not the position, and that is the point
of it rather than a convenience. Excalidraw positions a bound label when it
creates it and never again — measured, moving four labelled containers left all
four labels at their original absolute coordinates — so the fix shifts the label
by the move's delta. It deliberately does *not* recompute the label's place from
the container, because that place is Excalidraw's own per-shape maths and is not
plain centring: an ellipse insets its label (offset 90.218 where centring gives
90.0) and a diamond constrains the label's wrap width instead (99.4px of a 240px
diamond against 229px of a 240px rectangle). Asserting the offset is what makes
the check fail if anyone ever swaps the delta for a recomputation.

`text`'s refusal lives in the page rather than in `Whiteboard.Write` because
whether an element carries a bound label is a fact about the live scene, which
only the page holds — so unlike the `text`-on-an-image and `caption`-on-a-non-
image refusals, this one cannot be pinned in XCTest. That is the shape this file
exists for.

### If you change the page

`./scripts/build-editor.sh` first. The harness runs the **built** bundle in
`Resources/MonacoEditor/`, not `editor/src/`, so an unbuilt edit is invisible to
it — and it will pass, which is the one failure mode to watch for.

### Checking that the harness still has teeth

Break something on purpose, rebuild, and confirm the matching check fails.
Three that have been run:

- Removing the `reflowArrowsTouching` call from `whiteboard.jsx`'s update arm
  reintroduces PR 3's third bug and should fail exactly two checks and no others.
- Forcing the update arm's `label` to `null` reintroduces the left-behind label
  and fails exactly two: the offset check and the move-with-retext one.
- Skipping the update arm's missing-label refusal reintroduces the silent
  success and fails exactly two: the refusal itself and the whole-op one. The
  other two checks in that group — that no label is created and that
  `boundElements` is untouched — **still pass**, correctly: the old behaviour
  also created nothing. They pin that the refusal does not half-apply, which is
  a different claim from the refusal happening at all.
