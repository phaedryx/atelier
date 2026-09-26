# The whiteboard

The Excalidraw-backed board: the read path's budget, the three write tools, image
transcription, and the capture button.

### The digest's budget, and what truncation drops

`read_whiteboard` answers with a text digest under a byte cap
(`Whiteboard.Digest.maxBytes`). The cap and the cut are both decisions, and both
are argued at length in `Sources/Models/WhiteboardDigest.swift`; what belongs
here is the part another change can break.

**The cap is 32,000 and the old 8,000 rested on a claim that is false at scale.**
The argument for 8KB was that the agent is asked to open `board.png` in the same
breath, so the picture carries whatever the text does not. It does not: the
render is capped at `MAX_RENDER_EDGE` (1600, `editor/src/whiteboard.jsx`), which
is below the size a board has reached by the time the digest starts cutting, so
the picture is downscaled and its label text stops being legible. (Boards are
*reported* at 2000–2900px on the long edge. That range is second-hand; the
structural point does not rest on it.) Both halves of the read path therefore
degraded
**together**, and exactly as a board got large enough to be worth checking — a
board of 83 elements reported 21 of them not listed. If the render cap ever
moves, this number's argument moves with it.

The 32,000 is measured and the table is in the source: a board of the shape this
feature produces costs a flat ~89 bytes an entry, so the cap lists ~355 elements
whole, or ~260 of a busier board's — past anything this feature has produced.
**It is a ceiling and not a target**, which is the measurement the choice rests
on: a 30-element board answers with 2,813 bytes, and every board that fitted
inside the old 8,000 returns byte-identical output. A 4x raise therefore costs
nothing on the hot path (`read_whiteboard` is called to draw, again to read the
extent back, again to verify) and the whole of the cost falls on the boards that
were previously being lied to. 16,000 was tried and rejected for that reason:
the ceiling had already answered the cost question, so halving bought nothing
where anyone was worried and cost completeness on boards of 180–355 elements.
A load-bearing cut makes being truncated survivable, not free — it is not a
reason to arrange to be truncated more often.

**Truncation is a choice about value, not a leftover of position**, and the
reason is the same one the unbind-on-delete rule exists for. Walking the scene in
file order and keeping whatever fits can list an arrow whose endpoint it dropped:
the digest prints `n1 → n2` with no `n2` anywhere in it — an id that appears
nowhere else, which is the digest lying. So elements are admitted in tier order
(words, then bare arrows, then shapes and uncaptioned images, then freehand) and
**an arrow is admitted together with the endpoints it names or not at all**. The
bundle is **transitive**, because Excalidraw lets an arrow bind to an arrow:
pulling `x2` in for `x1` and stopping there charges nothing for `x2`'s own
endpoints and leaves `x2` printing the dangling id the bundle exists to prevent,
one hop further out.

**So the read path can now say something it could not before: if an arrow is
listed, every endpoint it names that is on the board is listed too — an agent
can trust `n1 → n2` to resolve within the digest it is holding.** That is the
durable result of this section and the thing to preserve; the overflow note
states the same guarantee, scoped to exactly what the admission enforces ("No
arrow listed above names an element the cut left out"). It deliberately does not
promise that *every* id on the board resolves, because a binding to an element
that was never in the scene is not a cut's to fix — that is
`whiteboard_delete`'s unbinding rule, above. Widening the sentence past what is
enforced would be this feature's own failure mode wearing the fix's clothes.

Two of those placements are load-bearing rather than aesthetic: freehand is last
because the overflow note sends the reader to `board.png`, and for a stroke that
is already the only answer there was; an **uncaptioned image is not** down there
with it, because its id is the entry point for `whiteboard_update(caption:)` and
an image the digest leaves out is one that can never be captioned — on exactly
the boards that arm is for.

**The header carries the board's element count and extent whether or not the list
is complete**, and the overflow note names what it left out by kind. The buckets
are the closed `Element.Kind` set with one `other` bucket, and that is what keeps
the reserve honest: the note's worst case is charged to the budget before a
single entry is assembled, so a bucket named by an element's raw type would let a
board of distinct unknown types write a note longer than the whole budget.

**It is deliberately not paginated.** That is a change to the *tool* rather than
to the digest — `read_whiteboard` takes no arguments, so an offset means a new
argument, a cursor whose meaning survives an edit between two calls, and a second
round trip an agent has to know to make. `Digest.text` already takes `budget:`,
so an `offset:` beside it later is additive rather than a redesign.

### The whiteboard write tools

Three tools give an agent the board's write half, as `read_whiteboard` gave it the read half:
`whiteboard_add`, `whiteboard_update`, `whiteboard_delete`. They sit immediately after
`read_whiteboard` in `advertisedOrder`, so an agent that has found one has found all four.

**`.workspaceAction`, 15s, and no new `Surface` case.** They act on the caller's own workstream,
which that surface's charter already covers; a fifth case needs a trust argument distinct from the
four that exist, and this has none. There is no approval gate either, and here the question the
other configs answer does not even arise: a board is Atelier's own cache directory, not a file a
repository can ship.

**Swift validates and normalizes; the page expands.** `Whiteboard.Write`
(`Sources/Models/WhiteboardWrite.swift`) turns `{kind, text, at, from, to, color, ref}` into an
Excalidraw *skeleton* and refuses everything outside the vocabulary; `convertToExcalidrawElements`
in `editor/src/whiteboard.jsx` turns a skeleton into a real element. The split falls there because
this half is where the mistakes live — an unknown kind, an arrow pointing at nothing, a colour that
is not a colour — and none of them need a webview to pin, while the expansion needs Excalidraw's
own `seed`, `versionNonce`, `groupIds` and `boundElements` and must never be hand-written.
It lives in `Sources/Models/` and **not** `Sources/Models/IPC/`: `project.yml` compiles
`IPCProtocol.swift` and `IPCToolRegistry.swift` out of that directory into the `AtelierMCP` helper,
which cannot see `Whiteboard` and would stop compiling.

**Swift mints the ids and Excalidraw keeps them**, because the page converts with
`regenerateIds: false` — measured against 0.18.1, a supplied id survives byte-identical. So
`whiteboard_add` answers with ids that *are* the real element ids, the same ones the digest reports
and `whiteboard_update` takes: no mapping table, and no display-id vocabulary for the two ends to
drift apart on.

**A minted id is a UUID, so `ref` is what lets an arrow name a box created beside it** — which is
why `add` takes a **list** at all: a whole diagram is one call rather than fourteen at the 15s tier.
This is the one claim in this file that was asserted and never pinned, and it was false for as long
as it stood: `addPlan` minted every id itself and read none off the entry, so the id of a box
created in the same call could not be known until the call returned, and an arrow naming it was
refused with `unknownElement` — which refuses the whole call and draws nothing. It was invisible
because every arrow test injected a minter handing out `id-1`, `id-2`, `id-3`, pinning a batch no
agent could compose. `Tests/WhiteboardWriteTests.swift` now carries one arrow test that runs
**without** the injected minter, and that is the test the claim needed.

`ref` is an optional name of the caller's own on any entry, which an arrow later in the same batch
may use for `from` or `to`. Three things about it:

- **It is parse-time only and never leaves `WhiteboardWrite.swift`.** Not on `Skeleton`, not on the
  op, no spelling in the page or the digest. So the paragraph above still holds — there is one id
  vocabulary, and `ref` is not in it; the table that resolves it lives for the length of one call.
- **A `ref` that is also an id already on the board is refused, not resolved.** It could be resolved
  either way round, and that is the problem: an arrow naming it means two things, and a rule
  silently picking one draws the arrow to the wrong end of the board — which reads perfectly well in
  the digest. Two entries declaring the same `ref` are refused for the same reason. Both are checked
  **up front**, before any entry is drawn, so the refusal does not depend on where in the batch the
  offending entry sits; one consequence is that it beats `unknownKind` and `malformedEntry` for a
  batch carrying both, which is pinned rather than left to be rediscovered.
- **A `ref` on a `mermaid` entry is refused**, the same refused-not-ignored rule `color`, `from` and
  `to` already follow there: a mermaid entry stands alone in its call, so nothing can ever name it.

A *forward* reference is still refused rather than resolved — for a `ref` exactly as for a minted id
— because resolving it would make a batch's meaning depend on a reading order nothing states. A
`ref` is registered only once its element is made, so an entry naming its own `ref` falls out of
that rule rather than needing one of its own.

**What is on the board is read from the page, never from `board.excalidraw`.** The file lags by the
800ms save debounce, so an agent that adds a box and then updates it would be refused for naming an
id that is plainly there. `Host.liveState` reads `window.__whiteboardState()`, which also carries
the board's extent — Swift cannot compute that, and both are answers to the same instant. Passing
it in as a parameter is what keeps the validator pure and testable with no board on disk.

**`callAsyncJavaScript`, never `evaluateJavaScript`.** The latter does not await a returned promise;
it hands back the promise object, so an async page function reports success the instant it is
called, before anything has been applied. With the tab closed nothing would notice. Everything
crosses as a JSON string in both directions, which keeps the boundary `Sendable` and keeps the
reply out of `NSNumber`-versus-`Double` guesswork — a real hazard here, because every coordinate an
agent sends may be integral, the same trap `SceneLoad.number` documents on the read side.

**`whiteboard_add` is not replayable**, with `add_task` and `create_workstream`: it is a create, the
helper mints a fresh request id on every replay, and a replayed create draws the diagram twice. A
refusal whose **outcome is unknown** therefore forbids a retry rather than inviting one, because a
caller cannot tell a genuine failure from one its own retry caused. **Which refusals those are is
decided by whether the op was posted, not by how the failure looked**, and
`Whiteboard.Host.WriteFailure` is where the line is drawn: `.outcomeUnknown` for a `__whiteboardApply`
that was called and never answered for, `.notReady` — a readiness timeout, a page that would not
report its state, a state that would not decode — for every failure *before* that call, all of which
say they are safe to retry. The readiness timeout used to be on the forbidding side of that line, and
it is the one an agent meets most: a cold board has to mount before the session's first write, so the
first call of a session was the one most likely to be told, wrongly, that it might already have drawn
something. `update` and `delete` are
replayable, and `delete` is replayable *because* an id already gone is success; the answer reports
what was really removed rather than echoing back what it was asked for.

**Two Excalidraw behaviours this had to be built around.** Both were measured against the real
built bundle in an occluded offscreen window, and both *succeed* while leaving the board's picture
and its digest disagreeing — which is the worst state a board can be in, since the two halves of
the read path exist to corroborate each other:

- **An arrow does not bind to an endpoint outside its own batch.** `convertToExcalidrawElements`
  binds only within the array it is handed, so "connect the two boxes you can see" produced
  `startBinding` and `endBinding` both null. The referenced elements are therefore carried *into*
  that array and Excalidraw computes the binding itself. A carried element's `boundElements` is
  **unioned, never assigned**: a box already carries an entry for its own text label, and
  overwriting the list leaves that caption on the canvas attached to nothing.
- **Binding does not move an arrow to its endpoints.** One handed `(0,0)` with both bindings
  resolved stays at `(0,0)` with a stub 100px segment. So `edgePoints` computes the geometry in the
  page, and that is not a split of convenience: an arrow may name an endpoint already on the board,
  whose position Swift has no way to know.

**`update` and `delete` maintain the same binding invariants `add` does**, and neither did at
first — both were caught by the same harness, and both are the same silent shape as the two
Excalidraw behaviours above:

- **Moving a bound element drags its arrows.** Excalidraw binds but never moves, so a moved box
  left its arrow where it was — still bound, so the digest went on reporting `n1 → n2` quite
  correctly, while the picture showed an arrow pointing at empty space. `reflowArrowsTouching`
  re-runs `edgePoints` for every arrow attached to what moved.
- **Deleting an element unbinds the arrows that named it.** Otherwise an arrow survives holding
  `startBinding.elementId` for something that no longer exists, and the digest prints an endpoint
  id that appears nowhere else on the board — the digest lying, which is the one thing this feature
  is organized around not doing. Clearing the binding is Excalidraw's own semantics (the arrow
  survives, unattached) and needs no digest change: an unbound arrow already renders as its
  position rather than as an endpoint pair.

**The host is created eagerly by `WorkspaceActions`, not by a view.** The Whiteboard tab renders
only while the user is looking at that workstream, so relying on `ensureSingleton` to make a view
build the host would mean an agent's write silently doing nothing whenever the user is elsewhere —
most of the time, and the case the offscreen design exists for. `ensureSingleton` and never
`activateSingleton`, and every answer says the tab was opened **without taking the selection** and
names `request_attention`, the rule `open_tab` states.

**Building the host and opening the tab are two acts, and the order between them is
load-bearing.** The host is built before the write, because the offscreen page is what applies it;
the tab is opened only once `Host.apply` has returned. They were one act, in `whiteboardTarget`,
and a refused write therefore put a pane in the user's workspace for a change that never
happened — a typo'd `kind`, an id that is not on the board — while the refusal it answered with
said nothing about the pane and every success said "The Whiteboard tab is open". `openBoardTab` is
the call, and it is after `apply` in all three writes, `whiteboard_delete` included: a delete that
matched nothing still ran, so the tab still opens and that note stays true. `Tests/WhiteboardWriteTabTests.swift`
pins both directions, and it is the one XCTest file that drives a real `Whiteboard.Host` — which
works because `TEST_HOST` is `Atelier.app`, so `Bundle.main` resolves the built bundle. That does
not widen what belongs in XCTest: a claim about what the *page* does with what it is handed is
still the harness's, per `Tests/Harnesses/README.md`.

**The `note` kind is a rectangle**, since Excalidraw has none: a distinct background plus
`Whiteboard.Element.kindKey` (`"atelierKind"`) in `customData`, declared beside `authorKey` and
`captionKey` in `WhiteboardScene.swift`. **Both halves or neither** — the digest is taught to report
it as `note`, and without that a note round-trips as a box and the vocabulary silently has three
kinds instead of four. An annotation and a diagram node are different things, and reporting them
differently is what lets an agent re-read its own board and tell its commentary apart from the
structure it drew. Only a *rectangle* is promoted: the marker says how a rectangle was authored, not
a way to relabel any element.

**An unplaced element clears what its own batch placed.** `at` is optional and anything unplaced is
stacked in a column, whose floor is the lower of the board's own extent and the bottom of anything
this batch places by hand — scanned up front, so the answer does not depend on batch order. Without
it an agent that placed two boxes and added an unplaced note got the note dropped on top of them:
invisible in the digest, since the coordinates read exactly as asked, and wrong only in the picture.

**A `box` and a `note` are sized to their labels, and `boxSize` is what is left of the constant that
used to decide it.** A fixed `220×90` wrapped any label longer than three or four words and spilled
it out of the box, and a caller could not know how wide anything was — so it had to hold a column
pitch in its head, and got it wrong in every run of a real evaluation, at 300px putting an arrow's
own label in the 80px gap on top of both boxes. `boxSize` survives as the **minimum**, so a short
label draws at exactly the size it always did and only the boards that were already wrong move;
`maxBoxWidth` (400) is where a label stops widening and starts wrapping.

**Swift cannot measure text, so the page measures it — and the page does not measure it either, the
converter does.** `convertToExcalidrawElements` creates a labelled container with `width ===
undefined` at 0×0 and runs Excalidraw's own `redrawTextBoundingBox` over it, which sees a negative
available width, so `wrapText` returns the label unwrapped, measures it, and grows the container to
`ceil(metrics.width) + 10` by `ceil(metrics.height) + 10` (measured against 0.18.1 —
`data/transform.ts`, `element/textElement.ts`). A natural size is therefore what Excalidraw gives for
free when the two fields are simply left off, and `maxBoxWidth` is applied by converting a second
time at exactly that width. **Do not replace this with `canvas.measureText`.** A hand-rolled
measurement has to reproduce Excalidraw's font string, line height, `normalizeText`, tokenizer and
padding, and every one of those it got wrong is a box whose size disagrees with the text drawn in
it — which reads perfectly well in the digest and is wrong only in the picture. Measuring *through*
the converter inherits all of it by construction, including what it does with a newline.

### The page measures and reports; Swift places

**This is the rule for the whole write path, not one PR's choice, and it is written here because
people keep reaching for the mermaid precedent for things mermaid's precedent does not cover.** It
has been reached for twice in two days: once for auto-sizing, once for resolving a layout's `anchor`
offsets against a target's rectangle. Both belong on this side of the line.

A fact only the page can know — a label's extent, the board's bounds, an element's rectangle —
crosses into Swift as **data**, through `Live` or through a measurement call. The *decision* made
from it stays in Swift. Two reasons, and only the first is obvious:

1. **Coverage.** `Tests/Harnesses/README.md` is explicit that the harnesses are run by hand and are
   not part of `./scripts/dev.sh test`. An invariant implemented in the page is pinned only in a
   suite nobody is required to run before claiming done. The column floor, and a layout's "a note
   never lands on its target", are exactly the invariants that must not quietly break — so they
   belong in the unit suite, which means they belong in Swift.
2. **The `await` window.** A page-side placement computes across the same gap the mermaid arm
   already documents as its one real hazard: `__whiteboardApply` snapshots the scene at the top, and
   the mermaid arm's `await` lets a user stroke, a capture or another agent's write land in between
   and be replaced wholesale by that stale snapshot. Swift placing from a `Live` snapshot taken at
   write time has no such window.

**Mermaid is the exception, and it is narrow.** Placement lives in the page there because Swift
cannot even *validate* a mermaid definition — only `parseMermaidToExcalidraw` can say whether it
parses, so there is no Swift-side decision to keep. Everywhere else Swift can do the whole job once
it is told the numbers. "The page already knows it" is not on its own a reason to move a decision
there.

**`window.__whiteboardMeasure` is a third round trip, and placement deliberately did NOT move to the
page with it** — that is this rule's first application. The measurement is passed *in*, which is the
same move `Live`/`Layout` already make for the board's extent.

**`Live` carries per-element rectangles for the same reason, and they are validation INPUT rather
than an answer.** The geometry a write *returns* describes what that write just did; a caller placing
something relative to an element already on the board needs that element's rectangle *before* it can
decide anything, so the answer arrives a whole call too late. They are deliberately **not** on
`decodeLiveState`'s guard chain: the four fields that are there are what no write can be planned
without, so a page missing one is a page that does not exist, while a missing rectangle is a refusal
for one arm to make by naming the element.

**A supplied size is honoured exactly, and this is a hard invariant with a test rather than a
comment.** `width` and `height` are optional on an entry; auto-sizing applies only where neither was
given. A supplied width is never grown to fit a label and never floored at `boxSize` — a caller
asking for 200 gets 200, not 220 — and the same holds for height in both directions. The two axes are
independent, so a width alone clamps the wrap and lets the height be measured around it, which is
what a layout with a width budget and no opinion about height wants. The reason is not tidiness: a
layout that derives column arithmetic and a width budget from the widths it supplies cannot enforce
either if those widths are elastic, and it would be wrong in the picture while its digest read
exactly as asked. One consequence worth stating: the label is measured wrapped at the **supplied**
width, not at `maxBoxWidth`, or the height that comes back is the height of a box nobody drew.

That split is why `addPlan` is now two functions. `entries` makes every refusal — a bad kind, a
colour that is not a colour, an arrow naming nothing, a malformed `at` — and mints the ids, because
an arrow may name a box created earlier in the same call and that set has to grow as the batch is
*validated*. `skeletons` places, cannot throw, and is the only part that needs a measurement.

**Auto-sizing did not weaken the column scan; it is what finally makes it exact.** The scan needs
each placed element's bottom, which it used to guess as `boxSize.height` for a box or a note and as
**zero** for everything else — so a hand-placed `text` element contributed nothing and an unplaced
element stacked under a paragraph landed inside it. Now every element contributes what it will really
be drawn at. Three consequences to keep: the scan still runs **up front over the whole batch**, so
order-independence is unchanged; the column's pitch is the element's own height plus `layoutGap`
rather than a flat `rowStep`, because a column of auto-sized boxes is a column of different heights;
and `rowStep` survives as the **minimum** pitch, which is load-bearing rather than nostalgia — a
measurement that did not come back reads as zero height, and a zero step stacks two elements at the
same `y`, reintroducing the exact collision the scan exists to prevent through its own fallback. An
**arrow takes no slot at all**: `edgePoints` recomputes its position in the page, so a slot was a
120px hole for something not drawn in it.

**Every write answers with geometry, and auto-sizing is why it has to.** Auto-sizing *alone* is
strictly worse than the fixed size it replaced: a caller that no longer knows how wide a box is has
traded a known-bad constant for an unknown one, and manual placement gets harder. So `Host.Applied`
carries `rects` — keyed **by id**, not a second array beside `ids`, for the reason `Write.Add`
already states about two copies of one list — plus the board's own `extent` and `nextY`. All of it is
read back off the scene **after** the write, never assembled from the plan: that is the rule the ids
already follow, and here it earns more than tidiness, because a measurement that turned out wrong
shows up as the grown rect in the answer instead of as a box that silently does not match what the
agent was told. `extent` also retires a round trip the mermaid arm forced — a caller had to
`read_whiteboard` purely to learn how big its diagram came out.

The two arms are **worded** differently and that is the whole reason `Whiteboard.Added` carries which
one ran. An `elements` caller named each element and holds each id, so a line each is proportionate.
A `mermaid` caller named a *diagram*; twenty lines for twenty nodes it did not choose would spend the
whole answer describing something nobody asked about and bury the one number it wanted.

**`whiteboard_update` regrows a container it retexts, or this feature is a promise the neighbouring
tool quietly breaks.** A box sized to one word and then retexted to a sentence kept the size the old
word earned and spilled its text — the exact failure auto-sizing exists to fix, reached through the
other call. `redrawTextBoundingBox` is not exported, so the same conversion the add arm runs computes
the answer and the result is transplanted, container and label together. It is **grow-only**, and
that is Excalidraw's own semantics rather than a policy invented here: passing the container's
*current* width and height means a dimension is mutated only when the text exceeds it, so a box the
user deliberately drew large keeps its size. A bare `text` element gets the mirror of it — its own
`width`/`height` went stale, which is what `getCommonBounds` reads, so the board's extent was
measured against words that are no longer there. And a **resize reflows arrows** exactly as a move
does: `edgePoints` joins two shapes' faces, so growing a box moves the face while the arrow stays
put — still bound, so the digest goes on reporting the connection while the picture shows an arrow
stopping short.

**The board's extent is `getCommonBounds`, Excalidraw's own maths, not a min/max over `x` and
`y + height`.** The two disagree for exactly the elements whose drawn extent is not their frame: an
arrow's real span comes from its `points`, a rotated element's from its angle. The naive version
reported a board *shorter* than what is drawn on it, and the number it feeds is `nextY` — where
reading short means dropping the next element on top of something already there.

**`mermaid` is the fifth kind, and it inverts the split above: Swift routes, the page validates.**
`Whiteboard.Write.plan` is the entry `WorkspaceActions.whiteboardAdd` calls, and it answers one of
two shapes — `.elements`, the batch `addPlan` has fully validated, or `.mermaid`, a definition Swift
cannot read. Only `parseMermaidToExcalidraw` can say whether a definition parses and only the page
learns how big the result is, so the page owns the parse, the placement (it translates the whole
diagram so its top-left lands on the origin Swift chose) and the refusal, which carries mermaid's own
message with the scene untouched. It is the same converter and the same three calls Excalidraw runs
when mermaid text is pasted onto the canvas, and the library is already in the bundle for that path;
`package.json` pins `@excalidraw/mermaid-to-excalidraw` at the version Excalidraw itself depends on
so the import shares the chunk rather than adding one. Four consequences, each pinned:

- **A mermaid entry stands alone in its call** (`Failure.mermaidStandsAlone`). Its height is not known
  until it is drawn, so the column layout for anything after it would be a guess, and a guess drops
  the next element on top of the diagram — invisible in the digest. `addPlan` refuses a mermaid entry
  on its own account too, so a direct caller cannot draw one as a box. `color`, `from`, `to` and
  `ref` are **refused, not ignored** (`mermaidFieldRefused`): an agent whose red diagram came out
  black has been taught the field does nothing, and a `ref` on an entry that must stand alone could
  never be named by anything.

  **That refusal used to give advice that was false for half the diagram**, and the correction is
  the interesting part. It said "colour and connections belong in the definition itself". For a
  **node** that holds — measured against `@excalidraw/mermaid-to-excalidraw` 2.2.2, `classDef`,
  `style` and `class` survive the converter in full, `fill` becoming `backgroundColor`, `stroke`
  becoming `strokeColor`, `stroke-width:6px` becoming `strokeWidth` 6, and a node's bound label
  inheriting the node's `strokeColor`. For an **edge** it is false: `linkStyle` is dropped in every
  form tested, indexed and `default` alike, so every arrow the converter draws is `#1e1e1e`
  unconditionally, and only the *syntax* survives — `-.->` dashed, `==>` thick. So an agent that
  wanted a red arrow was sent by the refusal to `linkStyle`, got a black one, and had no recourse
  inside mermaid at all: a silent success reached by following a refusal, which is the exact shape
  this subsystem is organized against. The refusal now names the split and points at
  `whiteboard_update` on the id the call answers with, which is the one thing that does work. The
  measurement is `feat-whiteboard-layout-tool`'s and is recorded in `Tests/Harnesses/README.md`;
  the *string* is pinned in `Tests/WhiteboardWriteTests.swift`, because the behaviour is the
  converter's and a version bump may change it while the advice must not silently re-broaden.
- **Ids are regenerated for this arm, the opposite of `add`'s `regenerateIds: false`.** Mermaid names
  its nodes `A` and `B`, and a second diagram keeping those ids would collide with the first; the
  converter remaps bindings and container ids along with them. So Swift mints nothing here, and the ids
  an agent gets back are whatever the page reports really landed — the return path `Host.apply`
  already had.
- **The author marker travels on the op**, the way `captionKey` does, because the page stamps every
  node and edge the diagram expands to and cannot spell a `customData` key. Spread onto each skeleton,
  never assigned. A bound label carries nothing, the same as on the `add` arm — the converter creates
  it fresh from `label`, and the digest folds it into its container rather than reporting it.
- **A diagram type the converter cannot express lands as one image** — flowcharts, sequence, class, ER
  and state diagrams become elements; everything else is an SVG mermaid rendered itself, returned as
  an image plus a file. That file is posted to `assets/` by the same `save()` loop a pasted image goes
  through, which is why the SVG extension fix (`image/svg+xml` must land as `.svg`) is load-bearing
  here and not a nicety. The image carries no words on the canvas, so its **caption is the
  definition**: the digest is not blind to it, and a later agent can re-read what was drawn.
  Two things about that arm are **not** what they look like. First, **a type from the supported list
  can land as an image too**: `parseMermaid` wraps each per-type parser in a `try`/`catch` and falls
  back to `convertSvgToGraphImage` on a throw (measured, 2.2.2), logging to the page's console and
  telling its caller nothing — so a flowchart whose parser trips becomes a flat picture while the
  tool promises editable boxes. The page detects that (one image skeleton for a definition whose
  declared keyword is one the converter expands) and returns a `note` beside `ids`, which reaches
  the agent in `whiteboard_add`'s own answer, ahead of the tab note — the board did change, so this
  is not a refusal, but "Added 1 element" would describe a picture as though it were the boxes this
  tool promises. **The note rides on the result and there is no variant of the call that drops it.**
  Do not turn it into a second accessor the caller fetches separately: a caller forgetting that
  accessor is the exact bug this closed, where the note reached Swift and died there.
  Second, that image's file keeps the **converter's nanoid**, not the lowercase-hex SHA-1 the capture
  button uses — so the same diagram drawn twice writes two identical assets. Deliberate: Excalidraw's
  own `generateIdFromFile` falls back to a random id where SHA-1 is unavailable, so content-naming
  was never the invariant. The invariant is the **join** — a file's stem in `assets/` *is* the
  `fileId` on its image element — and a nanoid keeps it.

`Tests/WhiteboardWriteTests.swift` pins the Swift half; section 10 of the harness pins what the page
does with it, from disk — including that the same diagram added twice yields disjoint ids and that a
definition that does not parse leaves `board.excalidraw` byte-identical.

### Image transcription, and the capture button

Two arms were added last, and both are **mutations of the board**, so both answer the standing pair
below.

**A caption is an argument on `whiteboard_update`, not a fifth tool.** It writes
`customData[Element.captionKey]`, which the digest has rendered since it was written — the write half
was the only part missing, and `update` was already `.workspaceAction` / 15s / replayable, which is
what a caption write is. The agent is the OCR: it opens the `board.png` that `read_whiteboard` names,
reads the screenshot, and stores what it says.

**Refused for anything that is not an image, and the refusal names `text`.** A caption is a
transcription of pixels nothing else can read; on a box it would be a second, invisible text
channel — present in the digest and absent from the picture, which is the disagreement the read
path's two halves exist to make impossible. `Whiteboard.Write.Live` carries `imageIDs` so Swift can
answer that at all, since it never reads the scene and the page is the only thing that knows. An
**absent** `imageIDs` fails *open* to the page rather than reading as "no images", which would refuse
every legitimate caption while naming the wrong cause.

**And the mirror of that refusal was the point of adding it.** `text` on an **image** is refused
too. An image carries no words on the canvas, so the page's `textTargetFor` found nothing to change
and the call still answered "Updated i1." — a silent success teaching an agent that its
transcription had landed. Reaching for `text` to describe a screenshot is the obvious first move,
which is exactly why it is the one that had to be answered; the refusal names `caption`. The two
refusals are symmetric and each names the other's field.

**It is deliberately not materialized as a real text element.** That would make ⌘F find it, at the
cost of a block of text under every screenshot on a board the user is sketching on. Canvas search
over screenshots is the accepted gap, stated in the design.

**The page spells no `customData` key: the key travels with the value.** `updatePlan` puts
`Element.captionKey` on the op and the page writes `data[op.captionKey]`. This is the first write of
one of these keys from the JavaScript side, which cannot import `Element` — so a literal there would
be a second spelling that nothing keeps in step, and a rename in Swift would leave the page writing
the old key: the caption would reach the board and vanish from the digest, written and invisible.
Same reasoning as `IPC.Vocabulary`, for a boundary that cannot import Swift.

**The page SPREADS `customData` rather than assigning it**, and this is the one line in the arm that
matters. A note carries `atelierKind` and an agent-drawn element carries `atelierAuthor` in that same
dictionary, so a fresh object would demote a note to a box in the digest and disown an agent's own
element — the shape of the `boundElements` overwrite above, invisible in the same way. Clearing
**removes the key** rather than storing `""`, which would leave a blank caption line under the image
forever.

**The capture button runs `screencapture -i`** and is the third `ProcessRunner` exemption — see
**Child processes**, which carries the argument. Its file is named by the **lowercase hex SHA-1 of
its bytes**, which is Excalidraw's own `fileId` convention: the stem of a file in `assets/` *is* the
`fileId` on its image element, and a captured image and a pasted one have to be named by one rule or
that join quietly has two. `Store.writeAsset` refuses a name it would have had to rewrite, and a
SHA-1 hex string can never be one. Capturing the same region twice writes one file.

It goes through the same `__whiteboardApply` and therefore the same `saveNow()` — one save path, one
render site. The file reaches Excalidraw as an **asset-scheme URL and never as bytes**, so
`board.excalidraw` stays free of image data, and `save()`'s `saveAsset` loop skips it for free
(`indexOf(',')` is -1 on such a URL). It is **placed below the board's own extent**, from the same
`Layout` an unpositioned agent element uses; a fixed origin would drop it on the user's diagram,
which reads perfectly well in the digest and ruins the picture. It carries no `atelierAuthor`,
because the user pressed the button. It is scaled to a long edge of `maxOnBoardEdge` on **placement
only** — the file keeps every captured pixel, so the image stays sharp zoomed in and the agent reads
the full-resolution original.

**Both arms, against the standing pair.** *Does it keep arrows attached to what moved?* A caption
moves nothing on its own, and a caption sent **together with `at`** still goes through the existing
move branch and its `reflowArrowsTouching`; a capture places a new element and moves nothing. *Does
it leave anything bound to what it removed?* Neither removes anything. Both are checked by the
harness rather than asserted — see `Tests/Harnesses/README.md`.

**Known limitation, measured and left alone: an arrow cannot bind to an image.**
`convertToExcalidrawElements` throws `TypeError: undefined is not an object (evaluating 't.id')` for
one, against 0.18.1. It predates these arms — a board has held pasted images since the tab shipped —
and the behaviour is honest: the op is refused whole and the board is untouched. The harness pins
that it stays a **refusal**, because what would be dangerous is it becoming a partial apply, which
would put an arrow on the board bound to nothing while the digest reported an endpoint.
