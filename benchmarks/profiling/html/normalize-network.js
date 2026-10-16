/* Private adapter for the reviewed MicroProfiler viewer. No decoder or input HTML execution. */
(function (root) {
    "use strict";
    const LIMITS = Object.freeze({ maxFrames: 256, maxRawEntries: 1000000, maxRecords: 200000, maxStringLength: 16384 });

    function normalizeNetwork(options = {}) {
        function requireValue(condition, reason) {
            if (!condition) throw new Error("normalizer: " + reason);
        }
        function boundedLimit(name) {
            const value = options[name] === undefined ? LIMITS[name] : options[name];
            requireValue(Number.isSafeInteger(value) && value > 0 && value <= LIMITS[name], "invalid " + name);
            return value;
        }
        const maxRawEntries = boundedLimit("maxRawEntries");
        const maxRecords = boundedLimit("maxRecords");
        let outputRecords = 0;
        function reserve() { requireValue(++outputRecords <= maxRecords, "record limit exceeded"); }
        function scalar(value, label) {
            if (value === undefined || value === null) return null;
            if (typeof value === "bigint") return value.toString();
            if (typeof value === "number") {
                requireValue(Number.isFinite(value), "nonfinite " + label);
                requireValue(!Number.isInteger(value) || Number.isSafeInteger(value), "unsafe integer " + label);
                return value;
            }
            if (typeof value === "string") {
                requireValue(value.length <= LIMITS.maxStringLength, "string limit " + label);
                return value;
            }
            requireValue(typeof value === "boolean", "invalid scalar " + label);
            return value;
        }
        const expectedMarker = options.expectedMarker === undefined ? null : scalar(options.expectedMarker, "expectedMarker");
        requireValue(expectedMarker === null || (typeof expectedMarker === "string" && expectedMarker.length > 0), "invalid expectedMarker");
        const markerPrefix = expectedMarker === null ? null : expectedMarker + "::UiIdle_";
        const decoratedMarker = expectedMarker === null ? null : "::" + expectedMarker;
        const inputFrames = root.Frames;
        requireValue(Array.isArray(inputFrames) && inputFrames.length <= LIMITS.maxFrames, "frame limit or missing Frames");
        requireValue(typeof root.RawToEvent === "function" && Number.isInteger(root.EventBaseId), "viewer helpers unavailable");
        const lookup = root.g_Ext && root.g_Ext.typeLookup;
        const plugin = root.relayNetworkPlugin || (lookup && lookup[root.EventBaseId + 1] && lookup[root.EventBaseId + 1].plugin);
        requireValue(plugin && plugin.category === "Network" && typeof plugin.decode === "function", "Network plugin unavailable");
        const timerInfo = root.TimerInfo || [];
        requireValue(timerInfo.length <= maxRawEntries, "timer descriptor limit exceeded");
        const frames = [], markerDescriptors = [], markerExecutions = [], networkRecords = [], unknownEvents = [];
        const packetRelationships = [], unresolvedLinks = [], unsupported = [];
        const markerIndices = new Set();
        const stacks = [], currentPacketPerThread = [], packetBuckets = new Map();
        let rawEntries = 0;
        let extensionEntries = 0;
        function markerOrdinal(name) {
            if (expectedMarker === null || typeof name !== "string") return null;
            const canonical = name.startsWith("::") ? name.slice(2) : name;
            if (!canonical.startsWith(markerPrefix)) return null;
            const suffix = canonical.slice(markerPrefix.length);
            if (!/^[0-9]{2}$/.test(suffix)) return null;
            const ordinal = Number(suffix);
            return ordinal >= 1 && ordinal <= 64 ? ordinal : null;
        }
        for (let index = 0; index < timerInfo.length; index++) {
            const timer = timerInfo[index];
            if (!timer || expectedMarker === null) continue;
            const name = timer.name;
            const ordinal = markerOrdinal(name);
            if (name !== expectedMarker && name !== decoratedMarker && ordinal === null) continue;
            reserve();
            markerIndices.add(index);
            const descriptor = { timerIndex: index, viewerId: scalar(timer.id, "timer id"), name: scalar(name, "timer name") };
            if (ordinal !== null) descriptor.ordinal = ordinal;
            markerDescriptors.push(descriptor);
        }
        const counters = { hidden: 0, missingScope: 0, unclosedScope: 0, invalidScopeInterval: 0, unknownInterpretation: 0, unclassifiedExtensions: 0, ignoredChildLinks: 0 };
        function newTotals() { return { Rx: { bytes: 0, count: 0 }, Tx: { bytes: 0, count: 0 } }; }
        function add(totals, direction, size, count) {
            requireValue(direction === "Rx" || direction === "Tx", "invalid direction");
            const total = totals[direction];
            requireValue(Number.isSafeInteger(size) && size >= 0 && Number.isSafeInteger(count) && count >= 0, "invalid byte/count value");
            requireValue(Number.isSafeInteger(total.bytes + size) && Number.isSafeInteger(total.count + count), "total overflow");
            total.bytes += size;
            total.count += count;
        }
        function bucket(packetId) {
            const key = packetId.toString();
            let entry = packetBuckets.get(key);
            if (entry === undefined) {
                reserve();
                entry = { packetId: key, receiveRecordIds: [], deserializationGroups: [], identityScope: "viewer packet-id bucket; not globally unique packet identity" };
                packetBuckets.set(key, entry);
                packetRelationships.push(entry);
            }
            return entry;
        }
        function missingLink(record, reason) {
            reserve();
            unresolvedLinks.push({ recordId: record.id, reason });
        }
        function closeScope(scope, exitFrame, exitEntry, end) {
            if (scope.marker) {
                scope.marker.endMilliseconds = end;
                scope.marker.exitFrame = exitFrame;
                scope.marker.exitEntry = exitEntry;
                scope.marker.closed = true;
            }
            for (const item of scope.events) {
                const { record, ctx } = item;
                record.scope.endMilliseconds = end;
                record.scope.exitFrame = exitFrame;
                record.scope.exitEntry = exitEntry;
                record.scope.closed = true;
                record.scope.intervalVerified = end >= scope.start;
                if (!record.scope.intervalVerified) counters.invalidScopeInterval++;
                if (!ctx.hidden) {
                    // This is the viewer's engine-profiler accounting, never physical wire accounting.
                    add(frames[scope.frame].viewerNetworkTotals, ctx.directionName, ctx.value, ctx.count);
                    record.accounting.includedInViewerTotals = true;
                }
                if (!ctx.isReplica) continue;
                if (ctx.packetId !== undefined) {
                    const entry = bucket(ctx.packetId);
                    if (ctx.stage === 0) entry.receiveRecordIds.push(record.id);
                    if (ctx.stage === 1 || ctx.stage === 2) {
                        const group = entry.deserializationGroups[entry.deserializationGroups.length - 1];
                        if (group) {
                            // Mirrors notifyOnScopeExit: it updates the most recently opened group.
                            group.viewerScope = { recordId: record.id, frame: scope.frame, startMilliseconds: scope.start, endMilliseconds: end };
                        }
                    }
                } else if (ctx.stage === 2) {
                    if (ctx.ignoreEvent) {
                        counters.ignoredChildLinks++;
                        record.relationshipExclusion = "viewer ignores subtype 10/13 at stage-2 child-link boundary only";
                        continue;
                    }
                    const key = currentPacketPerThread[scope.log];
                    const entry = key === undefined ? undefined : packetBuckets.get(key);
                    const group = entry && entry.deserializationGroups[entry.deserializationGroups.length - 1];
                    // The pinned viewer checks packetId truthiness, so packet 0 is not linked.
                    if (key !== undefined && key !== "0" && group) {
                        group.childRecordIds.push(record.id);
                        record.viewerParentGroupId = group.id;
                    } else missingLink(record, "no current nonzero packet and deserialization group on this thread");
                }
            }
        }
        for (let frameIndex = 0; frameIndex < inputFrames.length; frameIndex++) {
            const frame = inputFrames[frameIndex];
            reserve();
            requireValue(Array.isArray(frame.ts) && Array.isArray(frame.tt) && Array.isArray(frame.ti) && Array.isArray(frame.tl), "invalid frame arrays");
            requireValue(frame.ts.length <= 256, "thread limit exceeded");
            requireValue(frame.ts.length === frame.tt.length && frame.ts.length === frame.ti.length && frame.ts.length === frame.tl.length, "thread array mismatch");
            const start = scalar(frame.framestart, "frame start"), end = scalar(frame.frameend, "frame end");
            requireValue(typeof start === "number" && typeof end === "number" && end >= start, "invalid frame interval");
            const previous = frames[frameIndex - 1];
            frames.push({ index: frameIndex, viewerId: scalar(frame.id, "frame id"), startMilliseconds: start, endMilliseconds: end,
                gpuStartMilliseconds: scalar(frame.framestartgpu, "GPU frame start"), gpuEndMilliseconds: scalar(frame.frameendgpu, "GPU frame end"),
                originalTimeUnit: "viewer milliseconds", paused: scalar(frame.paused, "paused"), incomplete: scalar(frame.incomplete, "incomplete"),
                gapFromPreviousMilliseconds: previous ? start - previous.endMilliseconds : null, viewerNetworkTotals: newTotals() });
            for (let log = 0; log < frame.tt.length; log++) {
                const ts = frame.ts[log], ti = frame.ti[log], tt = frame.tt[log], tl = frame.tl[log];
                requireValue(ts && ti && tt && tl && ts.length === ti.length && ts.length === tt.length, "entry array mismatch");
                rawEntries += tt.length;
                requireValue(rawEntries <= maxRawEntries, "raw entry limit exceeded");
                const stack = stacks[log] || (stacks[log] = []);
                for (let index = 0; index < tt.length; index++) {
                    const type = tt[index];
                    if (type === 1) {
                        const time = scalar(ts[index], "scope enter");
                        requireValue(typeof time === "number", "scope time is not viewer milliseconds");
                        const scope = { frame: frameIndex, log, entry: index, start: time, events: [] };
                        if (markerIndices.has(ti[index])) {
                            reserve();
                            scope.marker = { id: "marker:" + frameIndex + ":" + log + ":" + index, timerIndex: ti[index], frame: frameIndex, thread: log, entry: index,
                                startMilliseconds: time, endMilliseconds: null, exitFrame: null, exitEntry: null, closed: false };
                            markerExecutions.push(scope.marker);
                        }
                        stack.push(scope);
                    } else if (type === 0) {
                        const scope = stack.pop();
                        if (scope) {
                            const time = scalar(ts[index], "scope exit");
                            requireValue(typeof time === "number", "scope time is not viewer milliseconds");
                            closeScope(scope, frameIndex, index, time);
                        }
                    } else if (type > root.EventBaseId) {
                        extensionEntries++;
                        requireValue(typeof ts[index] === "bigint", "event word must retain integer bits");
                        const extraWords = Number((ts[index] >> 58n) & 3n);
                        requireValue(index + extraWords < ts.length, "truncated event extra words");
                        for (let extra = 1; extra <= extraWords; extra++) requireValue(typeof ts[index + extra] === "bigint", "invalid event extra word");
                        const event = root.RawToEvent(ts, ti, tt, tl, index);
                        const source = { frame: frameIndex, thread: log, entry: index };
                        if (event.type < 1 || event.type > 4) {
                            reserve();
                            const registeredCategory = lookup && lookup[type] && lookup[type].plugin && lookup[type].plugin.category;
                            const knownOtherPlugin = typeof registeredCategory === "string" && registeredCategory !== "Network";
                            if (!knownOtherPlugin) counters.unclassifiedExtensions++;
                            unknownEvents.push({ id: "extension:" + frameIndex + ":" + log + ":" + index, source, rawType: type, eventType: event.type,
                                packedWord: ts[index].toString(), data50Bits: scalar(event.data, "event data"), extraBytes: Array.from(event.extra), label: scalar(event.str, "event label"),
                                registeredCategory: scalar(registeredCategory, "extension category"), classification: knownOtherPlugin ? "other-viewer-plugin" : "unclassified-extension",
                                reason: "non-network or unknown extension type; excluded from network classification" });
                            continue;
                        }
                        const ctx = plugin.decode(event, true);
                        reserve();
                        const scope = stack[stack.length - 1];
                        const knownStage = !ctx.isReplica || ctx.stage === 0 || ctx.stage === 1 || ctx.stage === 2;
                        const knownSubtype = ctx.isReplica ? (root.replicaSubtypeToCategoryMap && Object.prototype.hasOwnProperty.call(root.replicaSubtypeToCategoryMap, ctx.subtype)) : ctx.subtype >= 0 && ctx.subtype <= 5;
                        const supported = Boolean(knownStage && knownSubtype);
                        const record = { id: "network:" + frameIndex + ":" + log + ":" + index, source, rawType: type, eventType: event.type,
                            packedWord: ts[index].toString(), packedWordMeaning: "event bits, not a timestamp", data50Bits: scalar(event.data, "network data"),
                            extraBytes: Array.from(event.extra), label: scalar(event.str, "event label"), direction: scalar(ctx.directionName, "direction"),
                            eventName: scalar(ctx.eventName, "event name"), subsystem: scalar(ctx.subsystemName, "subsystem"), category: scalar(ctx.categoryName, "category"),
                            subtype: scalar(ctx.subtype, "subtype"), subtypeName: scalar(ctx.pktSubtype === undefined ? ctx.curlSubtype : ctx.pktSubtype, "subtype name"), stage: scalar(ctx.stage, "stage"),
                            size: { value: scalar(ctx.value, "size"), unit: "bytes", source: "pinned viewer decode value; engine-profiler layer", physicalWireBytes: false }, count: scalar(ctx.count, "count"),
                            packetId: scalar(ctx.packetId, "packet id"), assetId: scalar(ctx.assetId, "asset id"),
                            scope: scope ? { frame: scope.frame, thread: log, entry: scope.entry, startMilliseconds: scope.start, endMilliseconds: null, exitFrame: null, exitEntry: null, closed: false,
                                intervalVerified: false, clockDomain: root.ThreadGpu && root.ThreadGpu[log] ? "GPU" : "CPU",
                                timingMeaning: "enclosing profiler scope, not packet arrival or delivery latency" } : null,
                            accounting: { includedInViewerTotals: false, hiddenByViewer: Boolean(ctx.hidden), interpretationSupported: supported, exclusion: ctx.hidden ? "nonzero replica stage or HTTP asset metadata" : null } };
                        if (!supported) counters.unknownInterpretation++;
                        if (ctx.hidden) counters.hidden++;
                        networkRecords.push(record);
                        if (!scope) {
                            counters.missingScope++;
                            record.accounting.exclusion = "no enclosing scope";
                            continue;
                        }
                        if (ctx.isReplica && ctx.packetId !== undefined) {
                            const entry = bucket(ctx.packetId);
                            if (ctx.stage === 1 || ctx.stage === 2) {
                                reserve();
                                currentPacketPerThread[log] = entry.packetId;
                                entry.deserializationGroups.push({ id: "deserialize:" + record.id, recordId: record.id, sourceThread: log, stage: ctx.stage,
                                    childRecordIds: [], viewerScope: null, relationshipBasis: "viewer ordered packet-id bucket and current packet per thread; not unique packet proof" });
                            }
                        }
                        scope.events.push({ record, ctx });
                    }
                }
            }
        }
        for (const stack of stacks) if (stack) for (const scope of stack) for (const { record } of scope.events) {
            counters.unclosedScope++;
            record.accounting.exclusion = "enclosing scope has no captured exit";
        }
        for (const entry of packetRelationships) {
            entry.ambiguousReceiveIdentity = entry.receiveRecordIds.length > 1;
            for (const group of entry.deserializationGroups) {
                group.receiveCandidatesFromPacketBucket = true;
                if (entry.receiveRecordIds.length !== 1) missingLink({ id: group.recordId }, entry.receiveRecordIds.length ? "multiple receive records share viewer packet-id bucket" : "no captured receive record for viewer packet-id bucket");
            }
        }
        const totals = newTotals();
        for (const frame of frames) for (const direction of ["Rx", "Tx"]) add(totals, direction, frame.viewerNetworkTotals[direction].bytes, frame.viewerNetworkTotals[direction].count);
        if (counters.unknownInterpretation) unsupported.push("Unknown network stage/subtype: viewer fallback values retained; qualified totals unavailable.");
        if (counters.missingScope || counters.unclosedScope) unsupported.push("Some network records lack a complete enclosing scope; viewer totals exclude them.");
        if (counters.invalidScopeInterval) unsupported.push("Some enclosing scope intervals are reversed; viewer totals retained but qualified totals unavailable.");
        const incompleteFrames = frames.some(frame => frame.incomplete);
        if (incompleteFrames) unsupported.push("Incomplete frame flags present; complete traffic totals unavailable.");
        if (unknownEvents.length) unsupported.push("Non-network/unknown extension records retained separately; network identity not inferred.");
        const supportedAccounting = networkRecords.length > 0 && counters.unknownInterpretation === 0 && counters.unclassifiedExtensions === 0 && counters.missingScope === 0 && counters.unclosedScope === 0 && counters.invalidScopeInterval === 0 && !incompleteFrames;
        const includedRecordIds = [];
        let networkDetailPresent = false;
        for (const record of networkRecords) {
            if (record.accounting.includedInViewerTotals) includedRecordIds.push(record.id);
            if (record.stage === 1 || record.stage === 2) networkDetailPresent = true;
        }
        return { frames, markerDescriptors, markerExecutions, networkRecords, unknownEvents, packetRelationships, unresolvedLinks,
            accounting: { unit: "bytes", layer: "engine-profiler viewer observations", viewerTotals: totals,
                qualifiedObservedTotals: supportedAccounting ? totals : null, exclusions: counters,
                includedRecordIds,
                rule: "Closed enclosing scopes only; nonzero replica stages and HTTP asset metadata excluded. Parent and child observations are never added together.",
                bytesPerSecond: null, bytesPerWorkloadEvent: null, workloadAttributed: false, physicalWireBytes: false },
            availability: { framesDecoded: frames.length, rawEntries, extensionEntries, networkRecordsPresent: networkRecords.length > 0,
                networkDetailPresent, expectedMarker, markerExecutionCount: markerExecutions.length,
                networkZeroMeaning: networkRecords.length ? null : "No decoded network records; capture verbosity and underlying traffic are not established.",
                absoluteFrameIdentityVerified: false, timestampSource: "viewer-decoded CPU milliseconds; raw packed network words retained separately" },
            unsupported: unsupported.concat(["No physical-wire, workload-only byte, synchronized-clock, or delivery-latency measurement.", "Packet relationships reproduce viewer bookkeeping and require capture qualification."]) };
    }
    root.normalizeNetwork = normalizeNetwork;
    root.relayNormalizerLimits = LIMITS;
})(globalThis);
