# Harnesses

**These are run by hand. They are not part of `./scripts/dev.sh test`.**

```bash
./scripts/build-editor.sh                        # required first — see below
swift Tests/Harnesses/whiteboard-harness.swift
node Tests/Harnesses/editor-model-harness.mjs editor/src/main.js
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

## The editor model harness is the exception, and it says so

`editor-model-harness.mjs` runs under `node` against a *fake* Monaco, which is
the opposite of the rule above. The distinction is what is being claimed. The
whiteboard harness asserts things about Excalidraw's behaviour, so mocking
Excalidraw would mock the thing under test. This asserts things about
`main.js`'s own bookkeeping — which tab points at which model, when `setValue`
is the right answer, who may dispose a shared model — and the Monaco surface
that rests on is six methods wide, none of which any assertion is about. It
loads the real source rather than a copy, so it cannot drift from what ships.

If an assertion here ever needs to be about what *Monaco* does, it belongs in a
`WKWebView` harness beside the whiteboard one instead.

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

**4. The capture arm.** A placed image keeps its bytes out of
`board.excalidraw`, its `assets/` filename is its `fileId`, it does not land on
top of what is already on the board, and — the part that cannot be inherited
from PR 2 — the PNG export still succeeds afterwards. A captured image is an
asset-scheme URL from the moment it lands, unlike a pasted one, so it exercises
the export-canvas taint path in its own session rather than after a relaunch.

**5. The caption arm.** Captions merge into `customData` rather than replacing
it, a caption write leaves every other element's bindings alone, and a caption
sent together with a move still reflows the arrows bound to what moved.

**6. The one known limitation, pinned so it cannot go quiet.** An arrow cannot
bind to an image — `convertToExcalidrawElements` throws for one, measured
against 0.18.1 — and what is checked is that it stays a **refusal** with the
board untouched, rather than becoming a partial apply.

**7. The update arm.** A moved labelled box drags its label with it, at the same
offset; a move and a retext in one call land both; `text` on a standalone text
element rewrites that element; and `text` on an element the user drew without a
label is refused with the board untouched, rather than answering `ok` having
changed nothing.

The standalone-text check is here because it is `textTargetFor`'s other branch
and nothing else in the file exercises it — `box()` always attaches a label, and
sections 4 and 5 work on images. Without it, a refusal widened to catch bare
`text` elements too would pass every other check in this file.

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

**8. A pasted image's bytes are posted once.** Three saves over a board holding
an image whose `dataURL` is still inline, and the bytes reach `assets/` on the
first and are not posted again.

Two things about it are worth knowing before changing it. **Its instrument is a
post count, not a file** — the only check in this file of which that is true,
and the rule above survives it because what that rule forbids is trusting a
*JavaScript return value*, while this is the Swift end counting what the page
really sent it. It has to be: the re-posted bytes are identical, since the name
is a SHA-1 of them, so `assets/` is byte-for-byte correct after every redundant
post and **no assertion about a file can see this bug at all**. The on-disk half
is checked either side of it.

And it **compares against a baseline it takes for itself** rather than an
absolute count, because `assetWrites` is cumulative across every host this file
builds. A section added above this one would otherwise fail *this* check and
report the re-upload bug as back.

The fixture is a scene file carrying its image bytes inline, which is what
`api.getFiles()` holds for an image pasted this session. It is the only way a
harness can reach that state — a paste needs a real paste event, and both other
routes hand Excalidraw an asset-scheme URL — and it is faithful, because the
loop under test discriminates on exactly one thing: whether the `dataURL` has a
comma in it.

**9. A pasted SVG lands under an extension Swift will write.** `image/svg+xml`
reached `assets/` as the extension `svg+xml`, because `save()` derived one by
taking the half of the MIME type after the slash — a name
`Whiteboard.Store.isSafeComponent` refuses, so the write threw and only logged
while the page's `writtenAssets` set had already ruled out a retry. The board
showed the image for the session and dropped it on relaunch.

It checks the *write* half only, and that is the deliberate part: `savedFiles()`
splits on the last dot, so a file misnamed `<sha1>.svg+xml` reads back as the
same id with the same mimeType — the read side cannot tell the two apart, and
this file's own `AssetScheme` copy serves everything but PNG as JPEG, so it could
not be trusted to either. The name on disk is the whole of the bug.

**10. The mermaid arm.** A mermaid definition is the one thing Swift hands the
page *without* having validated it — only `parseMermaidToExcalidraw` can say
whether a definition parses, and only the page learns how big the result is — so
the parse, the placement and the refusal are all the page's, and every claim
about them belongs here.

Four things it pins, each for its own reason:

- **A flowchart lands as its nodes, their labels and the edge between them**,
  the edge bound at both ends to elements the same call drew, with the diagram's
  top-left where it was asked to go. The converter has its own origin, so a
  diagram left where it emerges lands on top of whatever is already at (0,0) —
  which reads perfectly well in the digest.
- **Ids are regenerated on this arm, the opposite of the `add` arm's
  `regenerateIds: false`.** Mermaid names its nodes `A` and `B`, so the same
  diagram added twice would collide on those ids and Excalidraw dedupes by id.
  The check adds one flowchart twice and asserts the two sets are disjoint.
- **A definition that does not parse is refused and the scene is byte-identical
  afterwards.** A partial apply is the failure mode that matters here, the same
  one section 6 pins for an arrow bound to an image.
- **A diagram type the converter cannot express lands as one image**, its SVG in
  `assets/` under the image's own `fileId`, and **captioned with the
  definition** — the image carries no words on the canvas, so without the
  caption the digest would be blind to it and a later agent could not re-read
  what was drawn.

Every node and edge carries `atelierAuthor`; bound labels carry nothing, on this
arm as on `add`, because the converter creates them fresh from `label` and the
digest folds a label into its container rather than reporting it on its own.

**Measured, not pinned: mermaid styling survives for nodes and not for edges.**
Against `@excalidraw/mermaid-to-excalidraw` 2.2.2, by
`feat-whiteboard-layout-tool`. A node's `classDef`, `style` and `class` pass
through in full — `fill` becomes `backgroundColor`, `stroke` becomes
`strokeColor`, `stroke-width:6px` becomes `strokeWidth` 6 — and a node's bound
label inherits the node's `strokeColor`. `linkStyle` is **dropped**, in every
form tested, indexed and `default` alike, so every arrow the converter draws is
`#1e1e1e` unconditionally; for an edge only the syntax survives, `-.->` dashed
and `==>` at `strokeWidth` 4.

It is recorded here rather than added as a check because it is not an invariant
this codebase keeps — it is the converter's behaviour, and a later version may
well change it. What it changed on our side is
`Whiteboard.Write.Failure.mermaidFieldRefused`, which used to tell an agent that
"colour and connections belong in the definition itself" and so sent one that
wanted a red arrow to `linkStyle`, a black arrow and no recourse — a silent
success reached by following a refusal. The refusal now names the split and
points at `whiteboard_update` for an edge, and
`Tests/WhiteboardWriteTests.swift` pins the *string* so it cannot be
re-broadened back to the claim that was wrong. If a converter bump makes
`linkStyle` survive, this note and that string are what has to be revisited
together.

### If you change the page

`./scripts/build-editor.sh` first. The harness runs the **built** bundle in
`Resources/MonacoEditor/`, not `editor/src/`, so an unbuilt edit is invisible to
it — and it will pass, which is the one failure mode to watch for.

### Checking that the harness still has teeth

Break something on purpose, rebuild, and confirm the matching check fails.
Three that have been run:

- Removing the `reflowArrowsTouching` call from `whiteboard.jsx`'s update arm
  reintroduces PR 3's third bug and should fail exactly **three** checks and no
  others — section 1's two arrow checks and section 5's caption-sent-with-a-move
  reflow. It said two until this was re-run: the caption check was added after
  that recipe was written and nobody re-measured it, which is the failure mode
  this whole file exists to catch, in the file itself. Measured both ways — on
  the tree that corrected it, and on the tree before it (35 checks, giving
  32/35), so the stale number was the sentence's and not a consequence of the
  change that found it.
- Forcing the update arm's `label` to `null` reintroduces the left-behind label
  and fails exactly two: the offset check and the move-with-retext one.
- Skipping the update arm's missing-label refusal reintroduces the silent
  success and fails exactly two: the refusal itself and the whole-op one. The
  other two checks in that group — that no label is created and that
  `boundElements` is untouched — **still pass**, correctly: the old behaviour
  also created nothing. They pin that the refusal does not half-apply, which is
  a different claim from the refusal happening at all.

All three recipes were measured before section 10 existed, so the totals they
quote are a count of the file as it was then. The *number of checks each recipe
predicts* is still right — none of them touches the mermaid arm — but the
denominator is not, and this file has already been caught once quoting a count
nobody re-measured. Re-measure before quoting one.

## A known flake, so it is not rediscovered as a regression

**Section 11's `a pan reaches the gate at all` is nondeterministic.** Observed
2026-09-26, on `feat-whiteboard-autosize`: it passed on one run and failed on
the two that followed, against code that differed only in
`__whiteboardState`'s empty-board guard and the update arm's arrow exclusion —
neither of which touches `onChange`, `scheduleSave`, `saveSignature`, the gate
counters or the `Board` component. The check asserts that Excalidraw fires
`onChange` for an **appState-only** change (a pan) in an occluded window, and
that appears not to be reliable; its failure message is `calls 1 → 1; onChange
did not fire for an appState change`.

It is recorded rather than fixed or deleted because the check is still worth
having: when it does fire, it is the only thing keeping the check below it —
"and the gate declines it rather than arming a save" — from being vacuous. **Re-run
before concluding it is a regression.** An unrecorded flake gets blamed on
whichever PR happens to be the one that moved.
