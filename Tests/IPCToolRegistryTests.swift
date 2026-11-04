// ABOUTME: Tests the one description of every IPC tool — its spec, its schema, and its argument decoding.
// ABOUTME: What used to be three hand-kept lists agreeing by convention is one list agreeing by construction.

@testable import Atelier
import XCTest

final class IPCToolRegistryTests: XCTestCase {
    // MARK: - The registry itself

    /// The advertised list decides order and nothing else, so the one thing it
    /// can get wrong is membership: a tool left out is a tool no agent can see,
    /// and a tool listed twice is two entries under one name.
    func test_everyTool_isAdvertisedExactlyOnce() {
        let advertised = IPC.ToolSpec.advertised.map(\.tool)
        XCTAssertEqual(
            Set(advertised), Set(IPC.Tool.allCases),
            "every IPC.Tool must appear in the advertised list, and nothing else may"
        )
        XCTAssertEqual(advertised.count, IPC.Tool.allCases.count, "a tool is advertised twice")
    }

    /// `Tool.spec` is an exhaustive switch, so this cannot fail by omission —
    /// it fails when a spec is filled in for the wrong case, which a copied
    /// block makes easy and which nothing else would catch.
    func test_eachSpec_describesTheToolItIsReachedThrough() {
        for tool in IPC.Tool.allCases {
            XCTAssertEqual(tool.spec.tool, tool, "\(tool.rawValue)'s spec names a different tool")
        }
    }

    func test_everyTool_hasADescriptionAnAgentCanRead() {
        for tool in IPC.Tool.allCases {
            XCTAssertGreaterThan(tool.spec.description.count, 40, "\(tool.rawValue) has no usable description")
        }
    }

    /// An argument name is a wire key on both sides — advertised by the helper,
    /// read by a handler — so a duplicate silently loses one of them in the
    /// schema's `properties` dictionary.
    func test_noTool_declaresOneArgumentTwice() {
        for tool in IPC.Tool.allCases {
            let names = tool.spec.arguments.map(\.name)
            XCTAssertEqual(Set(names).count, names.count, "\(tool.rawValue) declares a duplicate argument")
        }
    }

    /// The schema is generated from the arguments rather than written beside
    /// them, which is the whole point: an advertised argument no handler reads,
    /// and an argument a handler reads that was never advertised, both became
    /// impossible when the two stopped being separate lists.
    func test_inputSchema_isBuiltFromTheDeclaredArguments() {
        let spec = IPC.Tool.openEditor.spec
        let schema = spec.inputSchema
        XCTAssertEqual(schema["type"] as? String, "object")
        XCTAssertEqual(schema["required"] as? [String], ["path"])
        let properties = try? XCTUnwrap(schema["properties"] as? [String: [String: Any]])
        XCTAssertEqual(properties?.keys.sorted(), ["line", "path"])
        // Every argument crosses the wire as a string — `Request.arguments` is
        // `[String: String]` — so `kind` must never leak into the advertised
        // type, however the decoder reads it.
        for tool in IPC.Tool.allCases {
            for (name, property) in (tool.spec.inputSchema["properties"] as? [String: [String: Any]]) ?? [:] {
                XCTAssertEqual(
                    property["type"] as? String, "string",
                    "\(tool.rawValue).\(name) is advertised as something other than a string"
                )
            }
        }
    }

    /// The kind list an agent is shown and the table `open_tab` looks up must be
    /// the same set. They were two literals in two targets — the helper compiles
    /// none of the app's model files — so only a test could ever have caught
    /// them diverging. Now they are derived, and this pins the derivation.
    func test_theTabKindsAdvertised_areTheOnesOpenTabAccepts() {
        let advertised = IPC.Vocabulary.TabKind.allCases.map(\.rawValue)
        XCTAssertEqual(Set(advertised), Set(WorkspaceActions.openableTabs.keys))

        let description = try? XCTUnwrap(
            IPC.Tool.openTab.spec.arguments.first { $0.name == "kind" }?.description
        )
        for kind in advertised {
            XCTAssertEqual(description?.contains("\"\(kind)\""), true, "open_tab's schema does not offer \(kind)")
        }
    }

    /// `close_tab` closes **every** singleton, Execution included — it was
    /// refused only while stopping a run meant reaching view-local `@State`,
    /// and `ProcessCompose.RunSession` owns that now. So the advertised list
    /// must offer all three.
    ///
    /// This test pinned the opposite for a release: the code had accepted
    /// Execution since `RunSession` landed (`testExecutionClosesAndStopsTheRun`
    /// pins it) while the prose here, in the tool description and in the
    /// helper's own server instructions all still told an agent it was refused
    /// and that the tool could not stop a dev server. An agent acting on that
    /// would take down the user's dev stack believing the call was inert, which
    /// is why the safety half is asserted too rather than just the kind.
    func test_closeTab_advertisesEverySingletonIncludingExecution() {
        let description = IPC.Tool.closeTab.spec.arguments.first { $0.name == "kind" }?.description
        for kind in IPC.Vocabulary.TabKind.allCases {
            XCTAssertEqual(
                description?.contains("\"\(kind.rawValue)\""),
                true,
                "close_tab's schema does not offer \(kind.rawValue)"
            )
        }
    }

    /// And the tool's own description must say that closing Execution stops the
    /// dev stack. The kind being offered is not enough on its own: an agent
    /// closing a tab to tidy up needs to know this one has a side effect the
    /// others do not.
    func test_closeTab_warnsThatClosingExecutionStopsTheRun() {
        let description = IPC.Tool.closeTab.spec.description.lowercased()
        XCTAssertTrue(description.contains("execution"))
        XCTAssertTrue(
            description.contains("stops") && description.contains("dev stack"),
            "close_tab must tell an agent that closing execution stops the dev stack"
        )
    }

    // MARK: - Decoding

    /// A representative value for each kind, so the sweep below can build a
    /// complete call for any tool without 25 hand-written dictionaries.
    private func representative(_ argument: IPC.ArgumentSpec) -> String {
        switch argument.kind {
        case .string: "a value"
        case .integer: "12"
        case .boolean: "true"
        case .list: "one,two"
        case .uuid: UUID().uuidString
        }
    }

    private func representativeArguments(for tool: IPC.Tool) -> [String: String] {
        var result: [String: String] = [:]
        for argument in tool.spec.arguments {
            result[argument.name] = representative(argument)
        }
        return result
    }

    /// Every declared argument decodes as the kind it declares. Before this
    /// there was nothing to decode *against*: each handler read
    /// `request.arguments["line"]` by literal key and parsed it inline, so the
    /// schema and the read agreed only because one person wrote both.
    func test_everyDeclaredArgument_decodesAsItsDeclaredKind() throws {
        for tool in IPC.Tool.allCases {
            let arguments = IPC.ToolArguments(tool: tool, raw: representativeArguments(for: tool))
            for argument in tool.spec.arguments {
                switch argument.kind {
                case .string:
                    XCTAssertEqual(try arguments.required(argument.name), "a value", "\(tool.rawValue).\(argument.name)")
                case .integer:
                    XCTAssertEqual(try arguments.integer(argument.name), 12, "\(tool.rawValue).\(argument.name)")
                case .boolean:
                    XCTAssertTrue(try arguments.boolean(argument.name), "\(tool.rawValue).\(argument.name)")
                case .list:
                    XCTAssertEqual(arguments.list(argument.name), ["one", "two"], "\(tool.rawValue).\(argument.name)")
                case .uuid:
                    XCTAssertNoThrow(try arguments.uuid(argument.name), "\(tool.rawValue).\(argument.name)")
                }
            }
        }
    }

    /// The missing-key sweep: drop each required argument in turn from an
    /// otherwise complete call, and the refusal must name *that* argument.
    ///
    /// Reading `required` is what makes this total — it walks the same list the
    /// schema advertises, so an argument that becomes required tomorrow is
    /// covered the day it is declared rather than the day somebody remembers.
    func test_aMissingRequiredArgument_isRefusedByName() {
        for tool in IPC.Tool.allCases {
            for required in tool.spec.arguments.filter(\.isRequired) {
                var raw = representativeArguments(for: tool)
                raw.removeValue(forKey: required.name)
                let arguments = IPC.ToolArguments(tool: tool, raw: raw)

                XCTAssertThrowsError(try arguments.required(required.name)) { error in
                    XCTAssertEqual(
                        error as? IPC.ToolError, .missingArgument(required.name),
                        "\(tool.rawValue) did not name \(required.name) as the missing argument"
                    )
                }
            }
        }
    }

    /// Present-but-empty is refused the same way absent is. An argument that
    /// arrives as `""` is the common shape of a model filling in a field it had
    /// nothing for, and reading it as a value gets it all the way to a handler.
    func test_anEmptyRequiredArgument_isAsMissingAsAnAbsentOne() {
        let arguments = IPC.ToolArguments(tool: .openEditor, raw: ["path": ""])
        XCTAssertThrowsError(try arguments.required("path")) { error in
            XCTAssertEqual(error as? IPC.ToolError, .missingArgument("path"))
        }
    }

    /// The three tools that phrase this in their own words keep doing so — the
    /// sentence has been in front of agents for as long as the tools have.
    func test_nonEmpty_refusesInTheToolsOwnWords() {
        let arguments = IPC.ToolArguments(tool: .sendMessage, raw: [:])
        XCTAssertThrowsError(try arguments.nonEmpty("content")) { error in
            XCTAssertEqual(
                (error as? IPC.ToolError)?.errorDescription,
                "send_message needs non-empty `content`."
            )
        }
    }

    /// A present, unparseable value is a mistake worth reporting rather than a
    /// silent nil — `open_editor`'s `line` scrolling to the top of the file
    /// instead of saying so is the bug this closes.
    func test_anUnparseableInteger_isRefusedRatherThanIgnored() {
        let arguments = IPC.ToolArguments(tool: .openEditor, raw: ["line": "twelve"])
        XCTAssertThrowsError(try arguments.integer("line")) { error in
            XCTAssertEqual(
                error as? IPC.ToolError,
                .invalidArgument(name: "line", reason: "expected a whole number, got twelve.")
            )
        }
        XCTAssertNil(try? IPC.ToolArguments(tool: .openEditor, raw: [:]).integer("line"), "absent stays absent")
    }

    func test_absentBool_isFalse() throws {
        for raw in [[:], ["bypass_permissions": ""], ["bypass_permissions": "  "]] {
            let arguments = IPC.ToolArguments(tool: .createWorkstream, raw: raw)
            XCTAssertFalse(try arguments.boolean("bypass_permissions"))
        }
    }

    func test_boolParsesTrueAndFalse() throws {
        XCTAssertTrue(try IPC.ToolArguments(tool: .createWorkstream, raw: ["b": "true"]).boolean("b"))
        XCTAssertTrue(try IPC.ToolArguments(tool: .createWorkstream, raw: ["b": " true "]).boolean("b"))
        XCTAssertFalse(try IPC.ToolArguments(tool: .createWorkstream, raw: ["b": "false"]).boolean("b"))
    }

    /// The whole point: a value that quietly reads false because the agent sent
    /// "True" is a silent no-op reported as a success.
    func test_unrecognizedBool_isAnErrorRatherThanFalse() {
        for raw in ["True", "TRUE", "yes", "1", "on", "y"] {
            let arguments = IPC.ToolArguments(tool: .createWorkstream, raw: ["bypass_permissions": raw])
            XCTAssertThrowsError(try arguments.boolean("bypass_permissions")) { error in
                guard case let .invalidArgument(name, reason) = (error as? IPC.ToolError) else {
                    return XCTFail("expected an invalidArgument failure for \(raw)")
                }
                XCTAssertEqual(name, "bypass_permissions")
                XCTAssertTrue(reason.contains(raw), "the refusal must echo what arrived: \(reason)")
            }
        }
    }

    /// One list parser now, where there were three byte-identical copies.
    /// `VerificationSummary.checks(from:)` and `TaskSummary.tags(from:)` were
    /// the other two entry points; once they became one-line delegations with no
    /// production caller they were deleted, and their tests moved onto the
    /// reader their tools really use.
    func test_listParsingIsOneImplementation() {
        let arguments = IPC.ToolArguments(tool: .startVerification, raw: ["checks": #"["rspec", "rubocop", "rspec"]"#])
        XCTAssertEqual(arguments.list("checks"), ["rspec", "rubocop"])
        XCTAssertEqual(arguments.list("absent"), [])
    }

    // MARK: - The JSON boundary

    /// Decodes an arguments object the way the helper's `tools/call` arm does,
    /// so these assert against the exact Foundation types `JSONSerialization`
    /// produces rather than against Swift literals that merely look alike. The
    /// bug being pinned *is* a bridging fact — `__NSCFBoolean` renders as "1"
    /// through `String(describing:)` — and a hand-built `[String: Any]` of Swift
    /// values would not reproduce it.
    private func coerced(_ json: String) throws -> [String: String] {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        return IPC.ToolArguments.strings(fromJSON: object)
    }

    /// A real JSON boolean reached `boolean(_:)` as "1" and was refused,
    /// reporting the agent's own `true` back to it as `received "1"`.
    func test_aJSONBoolean_readsAsTheFlagTheAgentMeant() throws {
        let arguments = try coerced(#"{"bypass_permissions": true, "quiet": false}"#)
        XCTAssertEqual(arguments["bypass_permissions"], "true")
        XCTAssertEqual(arguments["quiet"], "false")

        let typed = IPC.ToolArguments(tool: .createWorkstream, raw: arguments)
        XCTAssertTrue(try typed.boolean("bypass_permissions"))
        XCTAssertFalse(try typed.boolean("quiet"))
    }

    /// `NSNumber`'s boolean-ness is a CoreFoundation type id, not `is Bool`,
    /// which answers true for `NSNumber(1)` as well — so the check that spells
    /// `true` must not also spell `tail: 1` as `"true"`.
    func test_aJSONNumber_isNotMistakenForAFlag() throws {
        let arguments = try coerced(#"{"tail": 1, "zero": 0, "fraction": 2.5}"#)
        XCTAssertEqual(arguments["tail"], "1")
        XCTAssertEqual(arguments["zero"], "0")
        XCTAssertEqual(arguments["fraction"], "2.5")
        XCTAssertEqual(try IPC.ToolArguments(tool: .readProcessLogs, raw: arguments).integer("tail"), 1)
    }

    /// `NSArray`'s description is `"(\n    rspec,\n    rubocop\n)"`, and
    /// `parseList` splits on `,[]"'` but not on parentheses — so a real JSON
    /// array reached the runner as `["(", "rspec", ")"]` and was refused for an
    /// undeclared check named `(`.
    func test_aJSONArray_readsAsTheListTheAgentMeant() throws {
        let arguments = try coerced(#"{"checks": ["rspec", "rubocop"]}"#)
        XCTAssertEqual(IPC.ToolArguments(tool: .startVerification, raw: arguments).list("checks"), ["rspec", "rubocop"])
        XCTAssertFalse(arguments["checks"]?.contains("(") ?? true, "the NSArray description leaked: \(arguments)")
    }

    /// Elements go through the same rules, so a mixed array does not reacquire
    /// the bug one level down.
    func test_arrayElements_areRenderedByTheSameRules() throws {
        let arguments = try coerced(#"{"tags": [1, true, "audit", null]}"#)
        XCTAssertEqual(IPC.ToolArguments(tool: .addTask, raw: arguments).list("tags"), ["1", "true", "audit"])
    }

    /// `null` became the literal "<null>", so `line: null` was refused as
    /// "expected a whole number, got <null>". A null argument means absent, and
    /// every optional read here already treats absent and empty alike.
    func test_aJSONNull_isDroppedRatherThanSpelled() throws {
        let arguments = try coerced(#"{"path": "a/b", "line": null}"#)
        XCTAssertNil(arguments["line"])
        XCTAssertEqual(arguments["path"], "a/b")
        XCTAssertNil(try IPC.ToolArguments(tool: .openEditor, raw: arguments).integer("line"))
    }

    /// Strings are untouched, which is the whole of what used to work.
    func test_aJSONString_isUnchanged() throws {
        XCTAssertEqual(try coerced(#"{"content": "hello, world"}"#)["content"], "hello, world")
    }

    // MARK: - Shared vocabulary

    /// The attention cooldown is quoted in the tool's own description and in the
    /// helper's server instructions, neither of which compiles the notifier that
    /// enforces it. One number, read by all three.
    func test_theAttentionCooldown_isTheNumberTheNotifierEnforces() {
        XCTAssertEqual(
            Workstream.AttentionNotifier.cooldown,
            TimeInterval(IPC.Vocabulary.attentionCooldownSeconds)
        )
        XCTAssertTrue(
            IPC.Tool.requestAttention.spec.description
                .contains("every \(IPC.Vocabulary.attentionCooldownSeconds) seconds"),
            "request_attention's description no longer quotes the cooldown it is gated on"
        )
    }

    /// The reserved senders are named in the helper's prose and used by the app
    /// to post. A notice arriving from a label the instructions do not mention
    /// is one an agent has been told nothing about.
    func test_theReservedSenders_areTheOnesTheAppPostsFrom() {
        XCTAssertEqual(IPC.VerificationSummary.sender, IPC.Vocabulary.verificationSender)
        XCTAssertEqual(IPC.TaskSummary.sender, IPC.Vocabulary.taskSender)
        XCTAssertTrue(
            IPC.Tool.startVerification.spec.description.contains(IPC.Vocabulary.verificationSender),
            "start_verification no longer names the sender its notices arrive from"
        )
    }

    // MARK: - The two tables the helper acts on

    /// Unchanged by this refactor, and the tests that pin them live in
    /// `IPCProtocolTests`. This one pins that they still come from the spec —
    /// the derivation is what makes them one fact rather than three.
    func test_theDeadlineAndReplayTables_readThroughTheSpec() {
        for tool in IPC.Tool.allCases {
            XCTAssertEqual(tool.replyDeadline, tool.spec.replyDeadline)
            XCTAssertEqual(tool.isSafeToReplay, tool.spec.isSafeToReplay)
            XCTAssertEqual(tool.surface, tool.spec.surface)
        }
    }

    /// The code the helper acts on, rather than the sentence it used to match a
    /// substring of. A `Response` carrying no code decodes exactly as one built
    /// before the field existed.
    func test_aResponseCode_survivesTheWire() throws {
        let refusal = IPC.Response.failure(id: "1", "That peer id belongs to another session.", code: .peerOwnedByAnotherSession)
        let decoded = try JSONDecoder().decode(IPC.Response.self, from: JSONEncoder().encode(refusal))
        XCTAssertEqual(decoded.code, .peerOwnedByAnotherSession)

        let plain = try JSONDecoder().decode(
            IPC.Response.self,
            from: Data(#"{"id":"1","error":"something else"}"#.utf8)
        )
        XCTAssertNil(plain.code, "a response with no code must still decode")
    }

    // MARK: - Advertising

    /// `advertised` is hand-written and decides order only — the one registry
    /// site that does NOT fail to compile when a tool is left out, so a tool can
    /// be dispatchable and undiscoverable.
    func test_advertised_includesEveryExecutionTool() {
        let advertised = Set(IPC.ToolSpec.advertised.map(\.tool))
        for tool in [
            IPC.Tool.listProcesses, .readProcessLogs, .startProcess, .stopProcess,
            .restartProcess, .startExecution, .stopExecution,
        ] {
            XCTAssertTrue(advertised.contains(tool), "\(tool.rawValue) is not advertised")
        }
    }

    /// The reads and the mutators land on the two surfaces that already mean
    /// "the caller's own workstream and no other". There is deliberately no
    /// fifth `Surface` case: one would need a trust argument distinct from the
    /// four that exist, and this has none.
    func test_executionTools_sitOnTheExistingWorkspaceSurfaces() {
        for tool in [IPC.Tool.listProcesses, .readProcessLogs] {
            XCTAssertEqual(tool.spec.surface, .workspaceRead, "\(tool.rawValue)")
        }
        for tool in [
            IPC.Tool.startProcess, .stopProcess, .restartProcess,
            .startExecution, .stopExecution,
        ] {
            XCTAssertEqual(tool.spec.surface, .workspaceAction, "\(tool.rawValue)")
        }
    }

    /// The write tools group with the read, so an agent that has found one has
    /// found all five. `whiteboard_add_layout` sits immediately after
    /// `whiteboard_add` rather than at the end of the group: an agent reading
    /// down the list meets the primitive it already knows, then the layout tool
    /// that saves it the arithmetic, which is the order it wants them in.
    func test_theWhiteboardWriteTools_areAdvertisedBesideTheRead() throws {
        let advertised = IPC.ToolSpec.advertised.map(\.tool)
        let read = try XCTUnwrap(advertised.firstIndex(of: .readWhiteboard))
        XCTAssertEqual(
            Array(advertised[read ... (read + 4)]),
            [
                .readWhiteboard, .whiteboardAdd, .whiteboardAddLayout,
                .whiteboardUpdate, .whiteboardDelete,
            ]
        )
    }

    /// A caller cannot tell a genuine failure from one its own retry caused, so
    /// the wording has to forbid a retry rather than invite one — the rule
    /// `create_workstream`'s timeout message states.
    func test_whiteboardAddsDescription_forbidsARetryRatherThanInvitingOne() {
        let description = IPC.Tool.whiteboardAdd.spec.description.lowercased()
        XCTAssertTrue(
            description.contains("do not retry") || description.contains("not replayed"),
            description
        )
    }

    /// The description is how an agent learns the kind exists at all, and the
    /// standalone rule is the one refusal it cannot infer from the shape.
    func test_whiteboardAddsDescription_namesMermaidAndItsStandaloneRule() {
        let spec = IPC.Tool.whiteboardAdd.spec
        let description = spec.description.lowercased()
        XCTAssertTrue(description.contains("mermaid"), description)
        XCTAssertTrue(description.contains("on its own") || description.contains("only entry"), description)
        let elements = spec.arguments.first { $0.name == "elements" }?.description.lowercased() ?? ""
        XCTAssertTrue(elements.contains("mermaid"), elements)
    }
}
