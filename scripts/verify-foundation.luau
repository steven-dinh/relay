local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local Verification = require("./Verification")

local ROOT = process.cwd

local TESTS = {
	{ label = "verification workflow", path = "tests/verification-workflow.luau" },
	{ label = "offline schema checks", path = "tests/schema-check.luau" },
	{ label = "offline schema compatibility", path = "tests/schema-compatibility.luau" },
	{ label = "offline schema budget analyzer", path = "tests/schema-budget.luau" },
	{ label = "optional roblox-ts declarations", path = "tests/roblox-ts.luau" },
	{ label = "consumer integration testing kit", path = "tests/consumer-testing.luau" },
	{ label = "interest management companion", path = "tests/interest-management.luau" },
	{ label = "bounded application session drain", path = "tests/session-drain.luau" },
	{ label = "operation-ID RPC example", path = "tests/operation-id-example.luau" },
	{ label = "entity state companion", path = "tests/entity-state.luau" },
	{ label = "optional Studio inspector", path = "tests/studio-inspector.luau" },
	{ label = "shared broadcast example", path = "tests/shared-broadcast-example.luau" },
	{ label = "module contract", path = "tests/runner.luau" },
	{ label = "public type consumer", path = "tests/public-types.luau" },
	{ label = "reliable event definition core", path = "tests/definition.luau" },
	{ label = "reliable event frame core", path = "tests/frame.luau" },
	{ label = "protocol compatibility goldens", path = "tests/compatibility.luau" },
	{ label = "unreliable payload size bounds", path = "tests/unreliable-size.luau" },
	{ label = "per-endpoint inbound rate limits", path = "tests/endpoint-rate.luau" },
	{ label = "bounded peer admission fairness", path = "tests/admission-fairness.luau" },
	{ label = "inbound byte budgets", path = "tests/inbound-bytes.luau" },
	{ label = "bounded Color3 values", path = "tests/color3.luau" },
	{ label = "RGB8 Color3 values", path = "tests/rgb8-color3.luau" },
	{ label = "bounded tagged unions", path = "tests/tagged-union.luau" },
	{ label = "bounded maps", path = "tests/maps.luau" },
	{ label = "bounded native schemas", path = "tests/native-schema.luau" },
	{ label = "bounded native codec", path = "tests/native-codec.luau" },
	{ label = "native runtime guards", path = "tests/native-runtime.luau" },
	{ label = "bounded Instance schemas", path = "tests/instance-schema.luau" },
	{ label = "bounded Instance codec", path = "tests/instance-codec.luau" },
	{ label = "Instance runtime guards", path = "tests/instance-runtime.luau" },
	{ label = "Instance event and queue routes", path = "tests/instance-routes.luau" },
	{ label = "bounded scalar quantization schemas", path = "tests/quantized-schema.luau" },
	{ label = "bounded numeric formats and count ranges", path = "tests/bounded-formats.luau" },
	{ label = "bounded scalar quantization codec", path = "tests/quantized-codec.luau" },
	{ label = "scalar quantization runtime guards", path = "tests/quantized-runtime.luau" },
	{ label = "compact native value codec", path = "tests/compact-values.luau" },
	{ label = "compact native value definitions", path = "tests/compact-definition.luau" },
	{ label = "compact native runtime guards", path = "tests/compact-runtime.luau" },
	{ label = "packed boolean optional and enum fields", path = "tests/bit-packing.luau" },
	{ label = "outbound application byte budgets", path = "tests/outbound-bytes.luau" },
	{ label = "bounded buffer schema and codec", path = "tests/buffers.luau" },
	{ label = "bounded buffer runtime guards", path = "tests/buffer-runtime.luau" },
	{ label = "automatic State outbound budget service", path = "tests/state-deferral.luau" },
	{ label = "paced client batch splitting", path = "tests/paced-batcher.luau" },
	{ label = "bounded client send timestamps", path = "tests/timestamps.luau" },
	{ label = "ordered unreliable events", path = "tests/ordered-unreliable.luau" },
	{ label = "scheduled ordered streams", path = "tests/streams.luau" },
	{ label = "composable schema codec", path = "tests/composable-codec.luau" },
	{ label = "bounded RPC envelope", path = "tests/rpc-frame.luau" },
	{ label = "bounded RPC definition", path = "tests/rpc-definition.luau" },
	{ label = "bounded RPC sessions", path = "tests/rpc-session.luau" },
	{ label = "queued event definition", path = "tests/queued-definition.luau" },
	{ label = "bounded readiness framing", path = "tests/readiness-frame.luau" },
	{ label = "bounded readiness sessions", path = "tests/readiness-session.luau" },
	{ label = "isolated transport namespaces", path = "tests/transport-namespaces.luau" },
	{ label = "bounded batch framing", path = "tests/batch-frame.luau" },
	{ label = "bounded outbound FIFO batch", path = "tests/batch-queue.luau" },
	{ label = "bounded batch sessions", path = "tests/batch-session.luau" },
	{ label = "bounded outbound state", path = "tests/state-queue.luau" },
	{ label = "bounded state sessions", path = "tests/state-session.luau" },
	{ label = "bounded session diagnostics", path = "tests/diagnostics.luau" },
	{ label = "opt-in traffic and refusal diagnostics", path = "tests/traffic-diagnostics.luau" },
	{ label = "modular schema composition", path = "tests/schema-compose.luau" },
	{ label = "schema authoring compatibility", path = "tests/schema-authoring.luau" },
	{ label = "reliable event token bucket", path = "tests/token-bucket.luau" },
	{ label = "reliable server session", path = "tests/server-session.luau" },
	{ label = "reliable client session", path = "tests/client-session.luau" },
	{ label = "benchmark event contract", path = "benchmarks/tests/event-v1.luau" },
	{ label = "benchmark event fixtures", path = "benchmarks/tests/fixtures-event-v1.luau" },
	{ label = "benchmark payload comparator", path = "benchmarks/tests/payload-comparator.luau" },
	{ label = "benchmark delivery ledger", path = "benchmarks/tests/delivery-ledger.luau" },
	{ label = "benchmark result contract", path = "benchmarks/tests/result-v1.luau" },
	{ label = "benchmark persistent contracts", path = "benchmarks/tests/persistent-contracts.luau" },
	{ label = "benchmark repetition fragment contract", path = "benchmarks/tests/repetition-fragment-v1.luau" },
	{ label = "benchmark result reporter", path = "benchmarks/tests/result-reporter.luau" },
	{ label = "benchmark persistent reporter", path = "benchmarks/tests/persistent-reporter.luau" },
	{ label = "benchmark adapter contract", path = "benchmarks/tests/adapter-contract.luau" },
	{ label = "benchmark external libraries", path = "benchmarks/tests/benchmark-libraries.luau" },
	{ label = "benchmark external adapter catalog", path = "benchmarks/tests/external-adapter-catalog.luau" },
	{ label = "benchmark external adapter lifecycle", path = "benchmarks/tests/external-adapter-lifecycle.luau" },
	{ label = "benchmark native reliable adapter", path = "benchmarks/tests/native-reliable-adapter.luau" },
	{ label = "benchmark Relay reliable adapter", path = "benchmarks/tests/relay-reliable-adapter.luau" },
	{ label = "benchmark delivery router", path = "benchmarks/tests/delivery-router.luau" },
	{ label = "benchmark persistent transport", path = "benchmarks/tests/persistent-transport.luau" },
	{ label = "benchmark session owner", path = "benchmarks/tests/session-owner.luau" },
	{ label = "benchmark timing recorder", path = "benchmarks/tests/timing-recorder.luau" },
	{ label = "benchmark runner state", path = "benchmarks/tests/runner-state.luau" },
	{ label = "benchmark runner activation", path = "benchmarks/tests/generation-activation.luau" },
	{ label = "benchmark result draft assembler", path = "benchmarks/tests/result-draft-assembler.luau" },
	{ label = "benchmark case runner", path = "benchmarks/tests/case-runner.luau" },
	{ label = "benchmark control protocol", path = "benchmarks/tests/control-protocol.luau" },
	{ label = "benchmark Studio runner", path = "benchmarks/tests/studio-runner.luau" },
	{ label = "benchmark persistent runner", path = "benchmarks/tests/persistent-runner.luau" },
	{ label = "benchmark host runtime", path = "benchmarks/tests/host-runtime.luau" },
	{ label = "benchmark persistent host", path = "benchmarks/tests/persistent-host.luau" },
	{ label = "benchmark reuse pilot observer", path = "benchmarks/tests/session-reuse-observer.luau" },
	{ label = "benchmark reuse pilot host", path = "benchmarks/tests/session-reuse-host.luau" },
	{ label = "quick Studio benchmark", path = "benchmarks/tests/quick-benchmark.luau" },
	{ label = "quick core payload adapters", path = "benchmarks/tests/quick-core-adapters.luau" },
	{ label = "quick receive profiling", path = "benchmarks/tests/quick-receive-profile.luau" },
	{ label = "LibMP CPU profiling", path = "benchmarks/tests/libmp-cpu-profile.luau" },
	{ label = "broadcast study orchestration", path = "benchmarks/tests/broadcast-study.luau" },
	{ label = "broadcast study input manifest", path = "benchmarks/tests/study-input-manifest.luau" },
	{ label = "broadcast source copy", path = "benchmarks/tests/study-source-copy.luau" },
	{ label = "broadcast recovery audit", path = "benchmarks/tests/broadcast-recovery-audit.luau" },
	{ label = "broadcast study evidence report", path = "benchmarks/tests/broadcast-study-report.luau" },
	{ label = "benchmark evidence review guard", path = "benchmarks/tests/benchmark-review.luau" },
	{ label = "serializer measurement gate", path = "benchmarks/tests/serializer-gate.luau" },
	{ label = "serializer evidence accounting", path = "benchmarks/tests/serializer-evidence.luau" },
	{ label = "benchmark host manifest contract", path = "benchmarks/tests/host-manifest-v1.luau" },
	{ label = "benchmark harness termination contract", path = "benchmarks/tests/harness-termination-v1.luau" },
	{ label = "benchmark fake adapter", path = "benchmarks/tests/fake-adapter.luau" },
}

local EXPECTED_FILES = {
	"scripts/Verification.luau",
	"scripts/check-schema.luau",
	"scripts/check-schema.md",
	"scripts/schema-compatibility.luau",
	"scripts/schema-compatibility.md",
	"scripts/analyze-schema-budget.luau",
	"scripts/analyze-schema-budget-core.luau",
	"scripts/analyze-schema-budget.md",
	"scripts/analyze-schema-budget-example-spec.luau",
	"scripts/analyze-schema-budget-example-workload.luau",
	"scripts/roblox-ts/.gitignore",
	"scripts/roblox-ts/Generator.luau",
	"scripts/roblox-ts/generate.luau",
	"scripts/roblox-ts/README.md",
	"scripts/roblox-ts/package.json",
	"scripts/roblox-ts/package-lock.json",
	"scripts/roblox-ts/check.mjs",
	"scripts/roblox-ts/tsconfig.json",
	"scripts/roblox-ts/consumer/default.project.json",
	"scripts/roblox-ts/consumer/src/Spec.luau",
	"scripts/roblox-ts/consumer/src/Network.luau",
	"scripts/roblox-ts/consumer/src/server.server.ts",
	"scripts/roblox-ts/consumer/src/client.client.ts",
	"scripts/roblox-ts/consumer/src/contracts.ts",
	"tests/roblox-ts/negative.ts",
	"scripts/consumer-testing/Kit.luau",
	"scripts/consumer-testing/run.luau",
	"scripts/consumer-testing/README.md",
	"scripts/studio-inspector/Snapshot.luau",
	"scripts/studio-inspector/Attachment.luau",
	"scripts/studio-inspector/Plugin.server.luau",
	"scripts/studio-inspector/plugin.project.json",
	"scripts/studio-inspector/demo.project.json",
	"scripts/studio-inspector/Demo.server.luau",
	"scripts/studio-inspector/README.md",
	".gitattributes",
    ".github/workflows/ci.yml",
    ".gitignore",
	"AGENTS.md",
    "LICENSE",
    "README.md",
    "SECURITY.md",
	"docs/.nojekyll",
	"docs/index.html",
	"docs/reference.md",
	"docs/styles.css",
	"benchmarks/README.md",
	"benchmarks/serializer-gate.md",
	"benchmarks/host/SerializerGate.luau",
	"benchmarks/host/SerializerEvidence.luau",
	"benchmarks/host/run-serializer-gate.luau",
	"benchmarks/adapters/AdapterContract.luau",
	"benchmarks/adapters/ExternalAdapter.luau",
	"benchmarks/adapters/README.md",
	"benchmarks/adapters/blink/init.luau",
	"benchmarks/adapters/blink/event-v1.blink",
	"benchmarks/adapters/blinkblox/init.luau",
	"benchmarks/adapters/blinkblox/event-v1.blink",
	"benchmarks/adapters/blinkblox/rpc.blink",
	"benchmarks/adapters/bytenet/init.luau",
	"benchmarks/adapters/netray-compile/init.luau",
	"benchmarks/adapters/netray-compile/event-v1.idl",
	"benchmarks/adapters/quicknet/init.luau",
	"benchmarks/adapters/satset/init.luau",
	"benchmarks/adapters/suphi-packet/init.luau",
	"benchmarks/adapters/warp/init.luau",
	"benchmarks/adapters/warp/Endpoint.luau",
	"benchmarks/adapters/zap/init.luau",
	"benchmarks/adapters/zap/event-v1.zap",
	"benchmarks/adapters/native-reliable/init.luau",
	"benchmarks/adapters/relay-reliable/init.luau",
	"benchmarks/event-v1.project.json",
	"benchmarks/external-runtime-libraries.project.json",
	"benchmarks/libraries.lock.json",
	"benchmarks/contracts/event-v1.luau",
	"benchmarks/contracts/internal/AdapterIdentity.luau",
	"benchmarks/contracts/internal/HarnessTerminationV1.luau",
	"benchmarks/contracts/internal/HostManifestV1.luau",
	"benchmarks/contracts/internal/HostManifestV2.luau",
	"benchmarks/contracts/internal/HostManifestSchema.luau",
	"benchmarks/contracts/internal/PersistentSessionProfile.luau",
	"benchmarks/contracts/internal/RepetitionFragmentV1.luau",
	"benchmarks/contracts/internal/ResultSchema.luau",
	"benchmarks/contracts/result-v1.luau",
	"benchmarks/contracts/result-v2.luau",
	"benchmarks/correctness/DeliveryLedger.luau",
    "benchmarks/correctness/PayloadComparator.luau",
    "benchmarks/fixtures/event-v1.luau",
	"benchmarks/generated/.gitignore",
	"benchmarks/host/HostRuntime.luau",
	"benchmarks/host/MeasurementFingerprint.luau",
	"benchmarks/host/GeneratedAdapters.luau",
	"benchmarks/host/ExternalAdapterCatalog.luau",
	"benchmarks/host/run-event-v1.luau",
	"benchmarks/host/BroadcastStudy.luau",
	"benchmarks/host/StudyInputManifest.luau",
	"benchmarks/host/StudySourceCopy.luau",
	"benchmarks/host/StudyExecutionReceipt.luau",
	"benchmarks/host/BroadcastRecoveryAudit.luau",
	"benchmarks/host/audit-broadcast-recovery.luau",
	"benchmarks/host/run-broadcast-study.luau",
	"benchmarks/licenses/LicenseRef-Suphi-Packet-Grant.txt",
	"benchmarks/pilot/Bootstrap.luau",
	"benchmarks/pilot/Client.client.luau",
	"benchmarks/pilot/DeliveryObserver.luau",
	"benchmarks/pilot/PersistentSession.luau",
	"benchmarks/pilot/Server.server.luau",
	"benchmarks/pilot/run-session-reuse.luau",
	"benchmarks/profiling/html/README.md",
	"benchmarks/profiling/html/bounded-process.py",
	"benchmarks/profiling/html/extract-network.mjs",
	"benchmarks/profiling/html/normalize-network.js",
	"benchmarks/profiling/html/runtime.mjs",
	"benchmarks/profiling/html/verify-bounded-process.py",
	"benchmarks/profiling/html/verify-dump-output.py",
	"benchmarks/profiling/html/verify-extractor.mjs",
	"benchmarks/profiling/html/verify-normalizer.mjs",
	"benchmarks/quick/README.md",
	"benchmarks/quick/Config.luau",
	"benchmarks/quick/Model.luau",
	"benchmarks/quick/CoreAdapters.luau",
	"benchmarks/quick/SchemaFixtures.luau",
	"benchmarks/quick/SchemaRelay.luau",
	"benchmarks/quick/CallbackTiming.luau",
	"benchmarks/quick/CpuProfile.luau",
	"benchmarks/quick/ReceiveInstrumentation.luau",
	"benchmarks/quick/Session.luau",
	"benchmarks/quick/Server.server.luau",
	"benchmarks/quick/Client.client.luau",
	"benchmarks/quick/build.luau",
	"benchmarks/quick/quick.project.json",
	"benchmarks/reporting/ResultReporter.luau",
	"benchmarks/reporting/BroadcastStudyReport.luau",
	"benchmarks/reporting/BenchmarkReview.luau",
	"benchmarks/reporting/report-broadcast-study.luau",
	"benchmarks/reporting/compare-results.luau",
	"benchmarks/results/local/.gitignore",
	"benchmarks/runner/AdapterAllowlist.luau",
	"benchmarks/runner/DeliveryRouter.luau",
	"benchmarks/runner/ExternalReadiness.luau",
	"benchmarks/runner/BenchmarkClock.luau",
	"benchmarks/runner/TimingRecorder.luau",
	"benchmarks/runner/RunState.luau",
	"benchmarks/runner/RunnerKernel.luau",
	"benchmarks/runner/GenerationActivation.luau",
	"benchmarks/runner/ResultDraftAssembler.luau",
	"benchmarks/runner/CaseRunner.luau",
	"benchmarks/runner/KernelFanout.luau",
	"benchmarks/runner/ControlProtocol.luau",
	"benchmarks/runner/Coordinator.server.luau",
	"benchmarks/runner/Participant.client.luau",
	"benchmarks/runner/PersistentTransport.luau",
	"benchmarks/runner/SessionOwner.luau",
	"benchmarks/runner/StudioBenchmarkClock.luau",
	"benchmarks/tests/support/HostRuntimeFixtures.luau",
	"benchmarks/tests/support/StudioProofReports.luau",
	"benchmarks/tests/support/FakeAdapter.luau",
	"benchmarks/tests/external-library-payloads.luau",
	"benchmarks/tests/external-session-reuse.luau",
	"benchmarks/tests/support/ExternalLibraryWorld.luau",
	"benchmarks/vendor/.gitignore",
	"default.project.json",
	"examples/README.md",
	"examples/reliable-events/Definition.luau",
	"examples/reliable-events/Server.server.luau",
	"examples/reliable-events/Client.client.luau",
	"examples/reliable-events/ordered.luau",
	"examples/reliable-events/default.project.json",
	"examples/combat-inventory/Combat.luau",
	"examples/combat-inventory/Inventory.luau",
	"examples/combat-inventory/Definition.luau",
	"examples/combat-inventory/Server.server.luau",
	"examples/combat-inventory/Client.client.luau",
	"examples/combat-inventory/default.project.json",
	"examples/state-snapshots/Definition.luau",
	"examples/state-snapshots/Server.server.luau",
	"examples/state-snapshots/Client.client.luau",
	"examples/state-snapshots/default.project.json",
	"examples/testing/Definition.luau",
	"examples/testing/Server.server.luau",
	"examples/testing/Client.client.luau",
	"examples/testing/default.project.json",
	"examples/interest-management/Groups.luau",
	"examples/interest-management/Definition.luau",
	"examples/interest-management/Server.server.luau",
	"examples/interest-management/Client.client.luau",
	"examples/interest-management/default.project.json",
	"examples/interest-management/README.md",
	"examples/shared-broadcast/Definition.luau",
	"examples/shared-broadcast/Server.server.luau",
	"examples/shared-broadcast/Client.client.luau",
	"examples/shared-broadcast/default.project.json",
	"examples/session-drain/Drain.luau",
	"examples/session-drain/Definition.luau",
	"examples/session-drain/Server.server.luau",
	"examples/session-drain/default.project.json",
	"examples/session-drain/README.md",
	"examples/operation-id-rpc/Rewards.luau",
	"examples/operation-id-rpc/Definition.luau",
	"examples/operation-id-rpc/Server.server.luau",
	"examples/operation-id-rpc/Client.client.luau",
	"examples/operation-id-rpc/default.project.json",
	"examples/operation-id-rpc/README.md",
	"examples/entity-state/Types.luau",
	"examples/entity-state/Server.luau",
	"examples/entity-state/Client.luau",
	"examples/entity-state/Definition.luau",
	"examples/entity-state/Server.server.luau",
	"examples/entity-state/Client.client.luau",
	"examples/entity-state/default.project.json",
	"examples/entity-state/README.md",
	"tests/studio/entity-state/default.project.json",
	"tests/studio/entity-state/Server.server.luau",
	"tests/studio/entity-state/Client.client.luau",
	"tests/studio/entity-state/README.md",
	"context.md",
    "rokit.toml",
    "scripts/acquire-benchmark-libraries.luau",
	"scripts/generate-benchmark-adapters.luau",
    "scripts/verify-foundation.luau",
	"src/Definition.luau",
	"src/Schema.luau",
	"src/ServerSession.luau",
	"src/ClientSession.luau",
	"src/internal/Frame.luau",
	"src/internal/NumericFormats.luau",
	"src/internal/LengthBounds.luau",
	"src/internal/CompositeCodec.luau",
	"src/internal/NativeSchema.luau",
	"src/internal/NativeCodec.luau",
	"src/internal/InstanceRefs.luau",
	"src/internal/Quantized.luau",
	"src/internal/CompactValues.luau",
	"src/internal/BitPacking.luau",
	"src/internal/RpcFrame.luau",
	"src/internal/PendingRequests.luau",
	"src/internal/ReadinessFrame.luau",
	"src/internal/BatchFrame.luau",
	"src/internal/Batch.luau",
	"src/internal/StateQueue.luau",
	"src/internal/Streams.luau",
	"src/internal/PacedBatcher.luau",
	"src/internal/Timestamps.luau",
	"src/internal/Diagnostics.luau",
	"src/internal/ByteUnits.luau",
	"src/internal/OrderedFrame.luau",
	"src/internal/TokenBucket.luau",
    "src/init.luau",
	"tests/support/ServerRuntime.luau",
	"tests/support/ClientRuntime.luau",
	"tests/support/NativeCodec.luau",
	"tests/types/positive.luau",
	"tests/types/negative.luau",
	"tests/types/ordered-schema.luau",
	"tests/types/ordered-invalid-options.luau",
	"tests/types/ordered-invalid-schemas.luau",
	"tests/types/composable-positive.luau",
	"tests/types/composable-invalid.luau",
	"tests/types/schema-helpers-positive.luau",
	"tests/types/schema-helpers-invalid.luau",
	"tests/types/schema-helpers-shapes.luau",
	"tests/types/schema-authoring-positive.luau",
	"tests/types/schema-authoring-negative.luau",
	"tests/types/schema-authoring-shapes.luau",
	"tests/types/schema-compose-positive.luau",
	"tests/types/endpoint-limit-events.luau",
	"tests/types/endpoint-rate-positive.luau",
	"tests/types/endpoint-rate-invalid.luau",
	"tests/admission-fairness.luau",
	"tests/types/admission-fairness-positive.luau",
	"tests/types/admission-fairness-invalid.luau",
	"tests/types/inbound-bytes-positive.luau",
	"tests/types/inbound-bytes-invalid.luau",
	"tests/types/color3-positive.luau",
	"tests/types/color3-invalid.luau",
	"tests/types/rgb8-positive.luau",
	"tests/types/rgb8-invalid.luau",
	"tests/types/tagged-union-positive.luau",
	"tests/types/tagged-union-invalid.luau",
	"tests/types/map-positive.luau",
	"tests/types/map-invalid.luau",
	"tests/types/native-values-positive.luau",
	"tests/types/native-values-invalid.luau",
	"tests/types/instance-positive.luau",
	"tests/types/instance-invalid.luau",
	"tests/types/quantized-positive.luau",
	"tests/types/quantized-invalid.luau",
	"tests/types/compact-values-positive.luau",
	"tests/types/compact-values-invalid.luau",
	"tests/types/outbound-packing-positive.luau",
	"tests/types/outbound-packing-invalid.luau",
	"tests/types/buffers-positive.luau",
	"tests/types/rpc-bounded-positive.luau",
	"tests/types/rpc-bounded-invalid.luau",
	"tests/types/buffers-invalid.luau",
	"tests/types/state-deferral-positive.luau",
	"tests/types/state-deferral-invalid.luau",
	"tests/types/streams-positive.luau",
	"tests/types/streams-invalid.luau",
	"tests/types/competitive-positive.luau",
	"tests/types/competitive-invalid.luau",
	"tests/types/ordered-unreliable-positive.luau",
	"tests/types/ordered-unreliable-invalid.luau",
	"tests/types/schema-compose-invalid.luau",
	"tests/types/schema-compose-combat.luau",
	"tests/types/schema-compose-inventory.luau",
	"tests/types/rpc-methods.luau",
	"tests/types/rpc-positive.luau",
	"tests/types/rpc-invalid.luau",
	"tests/types/rpc-invalid-schemas.luau",
	"tests/types/queued-positive.luau",
	"tests/types/queued-invalid.luau",
	"tests/types/readiness-positive.luau",
	"tests/types/readiness-invalid.luau",
	"tests/types/transport-namespaces-positive.luau",
	"tests/types/transport-namespaces-invalid.luau",
	"tests/studio/reliable-events.project.json",
	"tests/studio/Definition.luau",
	"tests/studio/Coordinator.server.luau",
	"tests/studio/Participant.client.luau",
	"tests/studio/StatePut.luau",
	"tests/studio/NativeValues.luau",
	"tests/studio/Competitive.luau",
	"tests/studio/TransportNamespaces.luau",
	"tests/studio/InstanceValues.luau",
	"tests/studio/QuantizedValues.luau",
	"tests/studio/CompactTransport.luau",
	"tests/studio/BufferDeferral.luau",
	"tests/studio/RpcBoundedRoutes.luau",
	"tests/studio/BroadcastBatching.luau",
	"tests/host/run-reliable-events.luau",
	"tests/studio-reliable-events.luau",
    "wally.toml",
}

for _, test in ipairs(TESTS) do
	table.insert(EXPECTED_FILES, test.path)
end

local EXPECTED_PACKAGE_FILES = {
    "default.project.json",
    "LICENSE",
    "README.md",
    "SECURITY.md",
    "src",
	"src/Definition.luau",
	"src/Schema.luau",
	"src/ServerSession.luau",
	"src/ClientSession.luau",
	"src/internal",
	"src/internal/Frame.luau",
	"src/internal/NumericFormats.luau",
	"src/internal/LengthBounds.luau",
	"src/internal/CompositeCodec.luau",
	"src/internal/NativeSchema.luau",
	"src/internal/NativeCodec.luau",
	"src/internal/InstanceRefs.luau",
	"src/internal/Quantized.luau",
	"src/internal/CompactValues.luau",
	"src/internal/BitPacking.luau",
	"src/internal/RpcFrame.luau",
	"src/internal/PendingRequests.luau",
	"src/internal/ReadinessFrame.luau",
	"src/internal/BatchFrame.luau",
	"src/internal/Batch.luau",
	"src/internal/StateQueue.luau",
	"src/internal/Streams.luau",
	"src/internal/PacedBatcher.luau",
	"src/internal/Timestamps.luau",
	"src/internal/Diagnostics.luau",
	"src/internal/ByteUnits.luau",
	"src/internal/OrderedFrame.luau",
	"src/internal/TokenBucket.luau",
    "src/init.luau",
    "wally.toml",
}

local IGNORE_PROBES = {
    ".tmp/probe",
    ".agents/skills/local-probe/SKILL.md",
    "Packages/probe",
    "ServerPackages/probe",
    "DevPackages/probe",
	"docs/specs/probe.md",
	"docs/plans/probe.md",
	"docs/forge/probe.md",
    "docs/reports/probe.md",
    ".idea/workspace.xml",
    ".vscode/settings.json",
    ".DS_Store",
    "Thumbs.db",
    "Desktop.ini",
    "benchmarks/vendor/probe",
    "benchmarks/generated/probe",
    "benchmarks/results/local/probe",
    "sourcemap.json",
	"artifacts/probe.rbxl",
	"artifacts/probe.rbxlx",
	"artifacts/probe.rbxm",
	"artifacts/probe.rbxmx",
}

local EXPECTED_EXCLUDES = {
	".agents",
	".agents/**",
    ".github",
    ".github/**",
    "AGENTS.md",
    "context.md",
    "docs",
    "docs/**",
    "tests",
    "tests/**",
    "scripts",
    "scripts/**",
    "examples",
    "examples/**",
    "benchmarks",
    "benchmarks/**",
    "sourcemap.json",
    "rokit.toml",
}

local function run(program, arguments)
    local result = process.exec(program, arguments, {
        cwd = ROOT,
        stdio = "default",
    })

    assert(
        result.ok,
        `{program} failed with exit code {result.code}\n{result.stdout}\n{result.stderr}`
    )

    return result
end

local function normalizedLines(value)
    local lines = {}

    for line in string.gmatch(value, "[^\r\n]+") do
        local normalized = string.gsub(line, "^%.[/\\]", "")
        normalized = string.gsub(normalized, "\\", "/")
        table.insert(lines, normalized)
    end
    return lines
end

local function normalizedNewlines(value)
	local normalized = string.gsub(value, "\r\n", "\n")
	return string.gsub(normalized, "\r", "\n")
end

local function keyCount(value)
	local count = 0

	for _ in pairs(value) do
		count += 1
	end

	return count
end

local function assertExactList(actual, expected, label)
    table.sort(actual)
    table.sort(expected)
    assert(#actual == #expected, `{label} count mismatch: expected {#expected}, got {#actual}`)

    for index, expectedValue in ipairs(expected) do
        assert(actual[index] == expectedValue, `{label} mismatch at {index}: expected {expectedValue}, got {tostring(actual[index])}`)
    end
end

local first, dryRun = false, false
for _, argument in process.args do
	if argument == "--first" then first = true
	elseif argument == "--dry-run" then dryRun = true
	else error(`unknown argument: {argument}; use --first and/or --dry-run`, 0) end
end
local selection = if first then Verification.plan(TESTS, Verification.changes())
	else { full = true, tests = TESTS, reasons = { "default: required full verification" } }
local source = Verification.sourceIdentity()
print(`SOURCE {source.revision} dirty={source.dirty} {source.fingerprint}`)
for _, reason in selection.reasons do print(`PLAN {reason}`) end
local stages = {}
local selectedPaths = {}
for _, test in selection.tests do
	selectedPaths[test.path] = true
	table.insert(stages, { label = test.label, path = test.path, status = "blocked" })
end
for _, test in TESTS do
	if not selectedPaths[test.path] then table.insert(stages, { label = test.label, path = test.path, status = "skipped" }) end
end
local gates = { "repository structure", "ignore boundary", "Wally contract", "Rojo package build",
	"Rojo example place build", "Rojo benchmark place build", "Rojo quick benchmark place build", "CI workflow contract" }
for _, label in gates do
	table.insert(stages, { label = label, status = if selection.full then "blocked" else "skipped" })
end
for index, stage in stages do print(`PLAN [{index}/{#stages}] {stage.label} {stage.path or ""} {stage.status}`) end
if not selection.full then print("ADVISORY first checks only; required final: lune run scripts/verify-foundation.luau") end
if dryRun then print("DRY RUN: no checks executed, no outputs created"); return end
local output = Verification.workspace("foundation")
print(`EVIDENCE {output.root}/report.json`)
local cursor = 0
local function begin(label)
	cursor += 1
	assert(stages[cursor].label == label, "verification stage order changed")
	stages[cursor].status = "running"
	print(`RUN [{cursor}/{#stages}] {label}`)
end
local function finish(label)
	assert(stages[cursor].label == label, "verification stage label changed")
	stages[cursor].status = "passed"
	print(`PASS [{cursor}/{#stages}] {label}`)
end
local function verify()
for _, test in selection.tests do
	begin(test.label)
	run("lune", { "run", test.path })
	finish(test.label)
end
if not selection.full then return end

begin("repository structure")
local publicFiles = normalizedLines(run("git", {
    "ls-files",
    "--cached",
}).stdout)
assertExactList(publicFiles, table.clone(EXPECTED_FILES), "tracked release file set")
assert(
	fs.readFile(".gitattributes") == "* text=auto eol=lf\n",
	"repository LF policy changed"
)

for _, path in ipairs(EXPECTED_FILES) do
    assert(fs.isFile(path), `missing scaffold file: {path}`)

    local contents = fs.readFile(path)
	assert(string.sub(contents, -1) == "\n", `missing final newline: {path}`)
	assert(string.find(contents, "[ \t]+\r?\n") == nil, `trailing whitespace: {path}`)
end

for _, path in ipairs({
    ".github/workflows",
    "benchmarks/adapters",
    "benchmarks/adapters/native-reliable",
    "benchmarks/contracts",
    "benchmarks/contracts/internal",
    "benchmarks/correctness",
    "benchmarks/fixtures",
    "benchmarks/generated",
	"benchmarks/licenses",
	"benchmarks/reporting",
    "benchmarks/results/local",
	"benchmarks/runner",
    "benchmarks/tests",
    "benchmarks/tests/support",
    "benchmarks/vendor",
	"examples",
    "scripts",
    "src",
	"src/internal",
    "tests",
	"tests/types",
}) do
    assert(fs.isDir(path), `missing scaffold directory: {path}`)
end

local keepFileContract = "*\n!.gitignore\n"
assert(normalizedNewlines(fs.readFile("benchmarks/vendor/.gitignore")) == keepFileContract, "benchmark vendor ignore contract changed")
assert(normalizedNewlines(fs.readFile("benchmarks/generated/.gitignore")) == keepFileContract, "benchmark generated ignore contract changed")
assert(normalizedNewlines(fs.readFile("benchmarks/results/local/.gitignore")) == keepFileContract, "benchmark results ignore contract changed")
finish("repository structure")

begin("ignore boundary")
local function assertIgnored(path)
	run("git", { "check-ignore", "--no-index", "--quiet", path })
end

for _, probe in ipairs(IGNORE_PROBES) do
	assertIgnored(probe)
end

local gitStatus = run("git", { "status", "--short" }).stdout
for _, forbidden in ipairs({ ".tmp/", "Packages/", "ServerPackages/", "DevPackages/", "benchmarks/vendor/probe", "benchmarks/generated/probe", "benchmarks/results/local/probe", "sourcemap.json" }) do
    assert(not string.find(gitStatus, forbidden, 1, true), `ignored output entered Git status: {forbidden}`)
end
finish("ignore boundary")

begin("Wally contract")
local manifestResult = run("wally", { "manifest-to-json", "--project-path", "." })
local manifest = serde.decode("json", manifestResult.stdout)
local package = manifest.package

assert(package.name == "steven-dinh/relay", "unexpected Wally package name")
assert(package.description == "Standalone Roblox typed events, requests, and bounded state queues.", "unexpected Wally description")
assert(package.version == "0.3.0", "unexpected Wally version")
assert(package.license == "MIT", "unexpected Wally license")
assert(package.realm == "shared", "unexpected Wally realm")
assert(package.registry == "https://github.com/UpliftGames/wally-index", "unexpected Wally registry")
assert(package.private == true, "Wally publication guard must remain enabled")
assert(#package.authors == 1 and package.authors[1] == "Steven Dinh", "unexpected Wally authors")
assert(#package.include == 0, "Wally include must remain empty")
assertExactList(table.clone(package.exclude), table.clone(EXPECTED_EXCLUDES), "Wally excludes")
assert(next(manifest.dependencies) == nil, "runtime dependencies must remain empty")
assert(next(manifest["server-dependencies"]) == nil, "server dependencies must remain empty")
assert(next(manifest["dev-dependencies"]) == nil, "development dependencies must remain empty")

local packageFiles = normalizedLines(run("wally", { "package", "--list", "--project-path", "." }).stdout)
assertExactList(packageFiles, table.clone(EXPECTED_PACKAGE_FILES), "Wally package file set")

local packagePath = output.artifacts .. "/relay-package.zip"
run("wally", { "package", "--project-path", ".", "--output", packagePath })
assert(fs.isFile(packagePath), "Wally package archive was not created")
assert(#fs.readFile(packagePath) > 0, "Wally package archive is empty")
assertIgnored(packagePath)
finish("Wally contract")

begin("Rojo package build")
local modelPath = output.artifacts .. "/Relay.rbxm"
run("rojo", { "build", "default.project.json", "--output", modelPath })
assert(fs.isFile(modelPath), "Rojo package build was not created")
assert(#fs.readFile(modelPath) > 0, "Rojo package build is empty")
assertIgnored(modelPath)
finish("Rojo package build")

begin("Rojo example place build")
local examplePath = output.artifacts .. "/relay-example.rbxlx"
local combatPath = output.artifacts .. "/relay-combat-inventory-example.rbxlx"
local statePath = output.artifacts .. "/relay-state-snapshots-example.rbxlx"
local testingPath = output.artifacts .. "/relay-testing-example.rbxlx"
local broadcastPath = output.artifacts .. "/relay-shared-broadcast-example.rbxlx"
local drainPath = output.artifacts .. "/relay-session-drain-example.rbxlx"
run("rojo", { "build", "examples/reliable-events/default.project.json", "--output", examplePath })
run("rojo", { "build", "examples/combat-inventory/default.project.json", "--output", combatPath })
assert(fs.isFile(combatPath)
    and #fs.readFile(combatPath) > 0,
    "Rojo combat/inventory example place build was not created")
assertIgnored(combatPath)
run("rojo", { "build", "examples/state-snapshots/default.project.json", "--output", statePath })
assert(fs.isFile(statePath)
    and #fs.readFile(statePath) > 0,
    "Rojo state snapshot example place build was not created")
assertIgnored(statePath)
run("rojo", { "build", "examples/testing/default.project.json", "--output", testingPath })
assert(fs.isFile(testingPath) and #fs.readFile(testingPath) > 0,
    "Rojo consumer testing example place build was not created")
assertIgnored(testingPath)
local interestPath = output.artifacts .. "/relay-interest-management-example.rbxlx"
run("rojo", { "build", "examples/interest-management/default.project.json", "--output", interestPath })
assert(fs.isFile(interestPath) and #fs.readFile(interestPath) > 0,
    "Rojo interest management example place build was not created")
assertIgnored(interestPath)
run("rojo", { "build", "examples/shared-broadcast/default.project.json", "--output", broadcastPath })
assert(fs.isFile(broadcastPath) and #fs.readFile(broadcastPath) > 0,
    "Rojo shared broadcast example place build was not created")
assertIgnored(broadcastPath)
run("rojo", { "build", "examples/session-drain/default.project.json", "--output", drainPath })
assert(fs.isFile(drainPath) and #fs.readFile(drainPath) > 0,
	"Rojo session drain example place build was not created")
assertIgnored(drainPath)
local operationPath = output.artifacts .. "/relay-operation-id-rpc-example.rbxlx"
run("rojo", { "build", "examples/operation-id-rpc/default.project.json", "--output", operationPath })
assert(fs.isFile(operationPath) and #fs.readFile(operationPath) > 0,
    "Rojo operation-ID example place build was not created")
assertIgnored(operationPath)
local entityPath = output.artifacts .. "/relay-entity-state-example.rbxlx"
run("rojo", { "build", "examples/entity-state/default.project.json", "--output", entityPath })
assert(fs.isFile(entityPath) and #fs.readFile(entityPath) > 0,
    "Rojo entity state example place build was not created")
assertIgnored(entityPath)
local entityProofPath = output.artifacts .. "/relay-entity-state-proof.rbxlx"
run("rojo", { "build", "tests/studio/entity-state/default.project.json", "--output", entityProofPath })
assert(fs.isFile(entityProofPath) and #fs.readFile(entityProofPath) > 0,
    "Rojo entity state native fixture build was not created")
assertIgnored(entityProofPath)
assert(fs.isFile(examplePath) and #fs.readFile(examplePath) > 0,
	"Rojo example place build was not created")
assertIgnored(examplePath)
finish("Rojo example place build")

begin("Rojo benchmark place build")
local benchmarkPath = output.artifacts .. "/event-v1.rbxlx"
run("rojo", { "build", "benchmarks/event-v1.project.json", "--output", benchmarkPath })
assert(fs.isFile(benchmarkPath), "Rojo benchmark place build was not created")
assert(#fs.readFile(benchmarkPath) > 0, "Rojo benchmark place build is empty")
assertIgnored(benchmarkPath)
finish("Rojo benchmark place build")

begin("Rojo quick benchmark place build")
local quickPath = output.artifacts .. "/relay-quick-proof.rbxlx"
run("rojo", { "build", "benchmarks/quick/quick.project.json", "--output", quickPath })
assert(fs.isFile(quickPath) and #fs.readFile(quickPath) > 0,
	"Rojo quick benchmark place build was not created")
finish("Rojo quick benchmark place build")

begin("CI workflow contract")
local workflowSource = normalizedNewlines(fs.readFile(".github/workflows/ci.yml"))
local workflow = serde.decode("yaml", workflowSource)
assert(keyCount(workflow) == 4, "CI workflow root shape changed")
assert(workflow.name == "CI", "CI workflow name changed")

local triggers = workflow["on"]
assert(type(triggers) == "table", "CI trigger shape changed")
assert(
	type(triggers.push) == "table"
		and keyCount(triggers.push) == 1
		and type(triggers.push.branches) == "table"
		and #triggers.push.branches == 1
		and triggers.push.branches[1] == "main",
	"CI push trigger must target only main"
)
local barePullRequest = string.find(workflowSource, "\n  pull_request:\n", 1, true) ~= nil
local emptyPullRequest = string.find(workflowSource, "\n  pull_request: {}\n", 1, true) ~= nil
assert(barePullRequest ~= emptyPullRequest, "CI pull request trigger must remain unfiltered")
if barePullRequest then
	assert(keyCount(triggers) == 1 and triggers.pull_request == nil, "CI trigger shape changed")
else
	assert(
		keyCount(triggers) == 2
			and type(triggers.pull_request) == "table"
			and keyCount(triggers.pull_request) == 0,
		"CI trigger shape changed"
	)
end

assert(keyCount(workflow.permissions) == 1 and workflow.permissions.contents == "read", "CI permissions must remain read-only")

assert(
	type(workflow.jobs) == "table"
		and keyCount(workflow.jobs) == 1
		and type(workflow.jobs.verify) == "table",
	"CI must contain exactly the verify job"
)
local verifyJob = workflow.jobs.verify
assert(keyCount(verifyJob) == 3, "CI verify job shape changed")
assert(verifyJob["runs-on"] == "windows-2022", "CI runner must remain pinned")
assert(verifyJob["timeout-minutes"] == 10, "CI timeout must remain bounded")
assert(#verifyJob.steps == 5, "CI verify job must contain exactly five steps")

local checkoutStep = verifyJob.steps[1]
assert(keyCount(checkoutStep) == 3, "CI checkout step shape changed")
assert(checkoutStep.name == "Check out repository", "CI checkout step changed")
assert(checkoutStep.uses == "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1", "CI checkout action must remain pinned")
assert(keyCount(checkoutStep["with"]) == 1 and checkoutStep["with"]["persist-credentials"] == false, "checkout credentials must not persist")

local rokitStep = verifyJob.steps[2]
assert(keyCount(rokitStep) == 3, "CI Rokit step shape changed")
assert(rokitStep.name == "Install Rokit tools", "CI Rokit step changed")
assert(rokitStep.uses == "CompeyDev/setup-rokit@1d9390883f7ebce19d48f5b8d006e11d387c92ab", "CI Rokit action must remain pinned")
assert(keyCount(rokitStep["with"]) == 2, "CI Rokit inputs changed")
assert(rokitStep["with"].version == "v1.2.0", "CI Rokit version must remain pinned")
assert(rokitStep["with"].cache == false, "setup-rokit cache must remain disabled")

local acquisitionStep = verifyJob.steps[3]
assert(keyCount(acquisitionStep) == 2, "CI acquisition step shape changed")
assert(acquisitionStep.name == "Acquire benchmark libraries", "CI acquisition step changed")
assert(acquisitionStep.run == "lune run scripts/acquire-benchmark-libraries.luau --all", "CI must acquire pinned benchmark libraries")

local generationStep = verifyJob.steps[4]
assert(keyCount(generationStep) == 2, "CI generation step shape changed")
assert(generationStep.name == "Generate benchmark adapters", "CI generation step changed")
assert(generationStep.run == "lune run scripts/generate-benchmark-adapters.luau --all", "CI must generate pinned benchmark adapters")

local verificationStep = verifyJob.steps[5]
assert(keyCount(verificationStep) == 2, "CI verification step shape changed")
assert(verificationStep.name == "Verify foundation", "CI verification step changed")
assert(verificationStep.run == "lune run scripts/verify-foundation.luau", "CI must run aggregate foundation proof")
finish("CI workflow contract")
end

local ok, failure = pcall(verify)
if not ok and cursor > 0 then stages[cursor].status = "failed" end
local identityOk, finalSource = pcall(Verification.sourceIdentity)
local stable = identityOk and finalSource.fingerprint == source.fingerprint
if ok and not stable then ok = false; failure = "source changed or became unreadable during verification" end
if ok then
	local cleanupOk, cleanupFailure = pcall(output.cleanup)
	if not cleanupOk then ok = false; failure = `output cleanup failed: {tostring(cleanupFailure)}` end
end
local report = { version = 1, mode = if selection.full then "full" else "advisory-first",
	status = if ok then "passed" else "failed", source = source,
	finalSource = if identityOk then finalSource else nil, sourceStable = stable, stages = stages,
	reasons = selection.reasons, failure = if ok then nil else string.sub(tostring(failure), 1, 8192),
	artifacts = if ok then "cleaned" else output.artifacts,
	requiredFinal = "lune run scripts/verify-foundation.luau" }
fs.writeFile(output.root .. "/report.json", serde.encode("json", report, true) .. "\n")
for _, stage in stages do
	if stage.status == "blocked" or stage.status == "skipped" then print(`{string.upper(stage.status)} {stage.label}`) end
end
print(`{if ok then "PASS" else "FAIL"} {if selection.full then "Relay.Foundation.Proof" else "advisory first checks"}`)
if not ok then print(tostring(failure)); process.exit(1) end
