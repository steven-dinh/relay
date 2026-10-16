// Pure adapter checks. This executes our static adapter and synthetic data only, not a dump or decoder.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import './normalize-network.js';

globalThis.EventBaseId = 128;
globalThis.replicaSubtypeToCategoryMap = { 0: 10, 10: 3, 12: 5, 13: 6, 31: 11 };
globalThis.TimerInfo = [{ id: 0, name: '::expected' }, { id: 1, name: 'scope' }];
globalThis.RawToEvent = (ts, ti, tt, tl, index) => {
    const extraWords = Number((ts[index] >> 58n) & 3n);
    const extra = new Uint8Array(extraWords * 10);
    const view = new DataView(extra.buffer);
    for (let i = 0; i < extraWords; i++) {
        view.setBigUint64(i * 10, ts[index + i + 1], true);
        view.setUint16(i * 10 + 8, ti[index + i + 1], true);
    }
    return { type: tt[index] - EventBaseId, data: Number(ts[index] & 0x0003ffffffffffffn), extra, str: '' };
};
globalThis.relayNetworkPlugin = {
    category: 'Network',
    decode(event) {
        const data = BigInt(event.data);
        const subtype = Number(data >> 40n), stage = Number((data >> 32n) & 255n);
        return { isReplica: true, isCurl: false, evt: event, value: Number(data & 0xffffffffn), count: 1,
            subtype, stage, hidden: stage !== 0, ignoreEvent: subtype === 10 || subtype === 13,
            directionName: event.type === 3 ? 'Rx' : 'Tx', eventName: event.type === 3 ? 'Engine Network Rx' : 'Engine Network Tx',
            subsystemName: 'Engine Network', categoryName: 'Synthetic category', pktSubtype: String(subtype),
            packetId: event.extra.length >= 8 ? new DataView(event.extra.buffer).getBigUint64(0, true) : undefined };
    }
};

function frame(id = 10) { return { id, framestart: id, frameend: id + 1, paused: false, incomplete: false, ts: [[]], ti: [[]], tt: [[]], tl: [[]] }; }
function append(frame, type, ts, ti = 1) { frame.tt[0].push(type); frame.ts[0].push(ts); frame.ti[0].push(ti); }
function event(frame, { size = 100, stage = 0, subtype = 31, packetId, type = 3 } = {}) {
    const data = BigInt(size) | (BigInt(stage) << 32n) | (BigInt(subtype) << 40n);
    append(frame, EventBaseId + type, data | (packetId === undefined ? 0n : (1n << 58n)));
    if (packetId !== undefined) append(frame, 127, BigInt(packetId), 0);
}
function scoped(frame, fields, timer = 1) {
    append(frame, 1, frame.framestart + 0.1, timer);
    event(frame, fields);
    append(frame, 0, frame.framestart + 0.2, timer);
}
function run(frames, options = {}) { globalThis.Frames = frames; return normalizeNetwork({ expectedMarker: 'expected', ...options }); }

// Parent sizes and stage-2 children remain separate. Ignore subtypes 10/13 only in child linking.
const mixed = frame();
scoped(mixed, { packetId: 9007199254740993n });
scoped(mixed, { stage: 1, packetId: 9007199254740993n });
scoped(mixed, { stage: 2, subtype: 12, size: 20 });
scoped(mixed, { stage: 2, subtype: 10, size: 7 });
scoped(mixed, { stage: 0, subtype: 10, size: 5 }, 0);
scoped(mixed, { stage: 0, subtype: 13, size: 3 });
const result = run([mixed]);
assert.equal(result.accounting.viewerTotals.Rx.bytes, 108);
assert.equal(result.accounting.viewerTotals.Rx.count, 3);
assert.equal(result.accounting.exclusions.ignoredChildLinks, 1);
assert.equal(result.packetRelationships[0].packetId, '9007199254740993');
assert.equal(result.packetRelationships[0].deserializationGroups[0].childRecordIds.length, 1);
assert.equal(result.markerDescriptors.length, 1);
assert.equal(result.markerExecutions.length, 1);
assert.equal(result.markerExecutions[0].closed, true);
assert.deepEqual(run([mixed]), result, 'normalization is deterministic and does not mutate frame data');
assert.doesNotThrow(() => JSON.stringify(result));

// Repeated deserialization groups retain order and their own children; repeated receives are ambiguous.
const repeated = frame();
scoped(repeated, { packetId: 7 });
scoped(repeated, { packetId: 7 });
scoped(repeated, { stage: 1, packetId: 7 });
scoped(repeated, { stage: 2, subtype: 12, size: 11 });
scoped(repeated, { stage: 2, packetId: 7 });
scoped(repeated, { stage: 2, subtype: 12, size: 12 });
const repeatedResult = run([repeated]);
const packet = repeatedResult.packetRelationships[0];
assert.equal(packet.ambiguousReceiveIdentity, true);
assert.equal(packet.deserializationGroups.length, 2);
assert.deepEqual(packet.deserializationGroups.map(group => group.childRecordIds.length), [1, 1]);
assert.notEqual(packet.deserializationGroups[0].childRecordIds[0], packet.deserializationGroups[1].childRecordIds[0]);
assert.equal(repeatedResult.accounting.viewerTotals.Rx.bytes, 200);
assert.equal(repeatedResult.unresolvedLinks.length, 2);

// Events crossing frame boundaries belong to the scope's start frame, as in the viewer.
const a = frame(1), b = frame(2);
append(a, 1, 1.9, 0); event(a, { size: 9 }); append(b, 0, 2.1, 0);
const crossing = run([a, b]);
assert.equal(crossing.frames[0].viewerNetworkTotals.Rx.bytes, 9);
assert.equal(crossing.frames[1].viewerNetworkTotals.Rx.bytes, 0);
assert.equal(crossing.networkRecords[0].scope.exitFrame, 1);

// Unknown interpretations remain visible and prevent qualified totals.
const unknown = frame(); scoped(unknown, { subtype: 99 });
const unknownResult = run([unknown]);
assert.equal(unknownResult.networkRecords[0].subtype, 99);
assert.equal(unknownResult.accounting.qualifiedObservedTotals, null);
const unknownType = frame(); scoped(unknownType, { type: 42 });
const unknownTypeResult = run([unknownType]);
assert.equal(unknownTypeResult.unknownEvents[0].eventType, 42);
assert.equal(unknownTypeResult.accounting.qualifiedObservedTotals, null);

// A descriptor is not an execution, absence is not proof of zero traffic, and unclosed scopes are excluded.
const empty = run([frame()]);
assert.equal(empty.markerDescriptors.length, 1);
assert.equal(empty.markerExecutions.length, 0);
assert.equal(empty.availability.networkRecordsPresent, false);
assert.equal(empty.accounting.qualifiedObservedTotals, null);
assert.match(empty.availability.networkZeroMeaning, /not established/);
const open = frame(); append(open, 1, 10.1, 0); event(open);
const openResult = run([open]);
assert.equal(openResult.accounting.viewerTotals.Rx.bytes, 0);
assert.equal(openResult.accounting.qualifiedObservedTotals, null);
assert.equal(openResult.markerExecutions[0].closed, false);

assert.throws(() => run([mixed], { maxRawEntries: 2 }), /raw entry limit/);
assert.throws(() => run([mixed], { maxRecords: 1 }), /record limit/);
const truncated = frame(); append(truncated, EventBaseId + 3, 1n << 58n);
assert.throws(() => run([truncated]), /truncated event/);
const unsafeId = frame(); unsafeId.id = Number.MAX_SAFE_INTEGER + 1;
assert.throws(() => run([unsafeId]), /unsafe integer frame id/);
const originalTimers = globalThis.TimerInfo;
globalThis.TimerInfo = ['::expected::UiIdle_01', 'expected::UiIdle_64', 'expected::UiIdle_00',
    'expected::UiIdle_65', 'expected::UiIdle_001', 'wrong-side::UiIdle_01', 'expected::UiIdle_01extra']
    .map((name, id) => ({ id, name }));
const ordinalFrame = frame();
for (let timer = 0; timer < TimerInfo.length; timer++) {
    append(ordinalFrame, 1, 10.1, timer); append(ordinalFrame, 0, 10.2, timer);
}
const ordinals = run([ordinalFrame]);
assert.deepEqual(ordinals.markerDescriptors.map(descriptor => descriptor.ordinal), [1, 64]);
assert.deepEqual(ordinals.markerExecutions.map(execution => execution.timerIndex), [0, 1]);
globalThis.TimerInfo = originalTimers;
console.log('PASS: synthetic normalization, stage accounting, repeated links, wide IDs, markers, unknowns, and bounds');

// Optional positive adapter oracle: pinned viewer JS in the reviewed browser Worker.
// This uses synthetic packed network words, not the vendor binary decoder.
function executePinnedCases() {
    globalThis.CanvasNetworkHistory = {};
    const factories = g_Loader.pluginDefines.filter(factory => factory.toString().includes('category: "Network"'));
    if (factories.length !== 1) throw new Error('ambiguous pinned Network factory');
    globalThis.relayNetworkPlugin = factories[0]();
    globalThis.TimerInfo = [{ id: 0, name: '::expected' }, { id: 1, name: 'scope' }];
    const first = frame();
    scoped(first, { packetId: 9007199254740993n });
    scoped(first, { stage: 1, packetId: 9007199254740993n });
    scoped(first, { stage: 2, subtype: 12, size: 20 });
    scoped(first, { stage: 2, subtype: 10, size: 7 });
    scoped(first, { stage: 0, subtype: 10, size: 5 });
    scoped(first, { stage: 0, subtype: 13, size: 3 });
    scoped(first, { stage: 0, subtype: 12, size: 17, type: 4 });
    const second = frame(11);
    scoped(second, { packetId: 7 });
    scoped(second, { packetId: 7 });
    scoped(second, { stage: 1, packetId: 7 });
    scoped(second, { stage: 2, subtype: 12, size: 11 });
    scoped(second, { stage: 2, packetId: 7 });
    scoped(second, { stage: 2, subtype: 12, size: 12 });
    globalThis.Frames = [first, second];
    const plugin = relayNetworkPlugin;
    plugin.prepareEventsBefore();
    const context = { scopeStack: [], lastExit: null };
    for (let nFrame = 0; nFrame < Frames.length; nFrame++) {
        const current = Frames[nFrame];
        plugin.notifyOnFrameStart(current);
        const ts = current.ts[0], ti = current.ti[0], tt = current.tt[0], tl = current.tl[0];
        for (let index = 0; index < tt.length; index++) {
            if (tt[index] === 1) {
                context.scopeStack.push({ frame: current, nFrame, nLog: 0, timeStamp: ts[index] });
                plugin.notifyOnScopeEnter(context);
            } else if (tt[index] === 0) {
                context.lastExit = { timeStamp: ts[index] };
                plugin.notifyOnScopeExit(context);
                context.scopeStack.pop();
            } else if (tt[index] > EventBaseId) {
                const decoded = plugin.decode(RawToEvent(ts, ti, tt, tl, index), true);
                plugin.notifyOnEvent(decoded, context.scopeStack[context.scopeStack.length - 1]);
            }
        }
    }
    const normalized = normalizeNetwork({ expectedMarker: 'expected' });
    const viewerTotals = Frames.map(current => ({
        Rx: { bytes: current.netTotals.rx.sum, count: current.netTotals.rx.count },
        Tx: { bytes: current.netTotals.tx.sum, count: current.netTotals.tx.count },
    }));
    const viewerPackets = Array.from(plugin.packetIdMap, ([packetId, bucket]) => ({
        packetId: packetId.toString(),
        childValues: bucket.deserialize.packets.map(packet => packet.values.map(value => Number(BigInt(value.data) & 0xffffffffn))),
    }));
    return { normalized, viewerTotals, viewerPackets };
}

if (process.argv.includes('--viewer')) {
    const output = process.argv[process.argv.indexOf('--viewer') + 1];
    assert.ok(output && !fs.existsSync(output), 'provide a new output path for the viewer oracle report');
    const { spawnSync } = await import('node:child_process');
    const { fileURLToPath } = await import('node:url');
    const path = await import('node:path');
    const { profileRuntime } = await import('./runtime.mjs');
    const here = path.dirname(fileURLToPath(import.meta.url));
    const runtime = profileRuntime();
    const run = spawnSync(runtime.python,
        [path.join(here, 'bounded-process.py'), '--', runtime.node, fileURLToPath(import.meta.url), '--viewer-child', path.resolve(output)],
        { stdio: 'inherit', windowsHide: true });
    if (run.error) throw run.error;
    process.exitCode = run.status ?? 1;
} else if (process.argv.includes('--viewer-child')) {
    const path = await import('node:path');
    const { fileURLToPath } = await import('node:url');
    const { envelope, readBounded, LIMITS, browserSession, runWorker } = await import('./extract-network.mjs');
    const { profileAssets, profileRuntime } = await import('./runtime.mjs');
    assert.equal(process.argv.length, 4, 'viewer child requires a fresh report path');
    profileRuntime();
    const here = path.dirname(fileURLToPath(import.meta.url));
    const assets = envelope(readBounded(profileAssets(), LIMITS.html));
    const normalizer = fs.readFileSync(path.join(here, 'normalize-network.js'), 'utf8');
    const source = `globalThis.window = globalThis;
globalThis.document = { childNodes: [], getElementById() { return {}; }, createElement() { return {}; } };
Object.defineProperty(globalThis, 'g_Reload', { value: true, writable: false, configurable: true });
${assets.viewer}
Object.defineProperty(globalThis, 'g_Reload', { value: false, writable: true, configurable: true });
${normalizer}
${frame.toString()}
${append.toString()}
${event.toString()}
${scoped.toString()}
${executePinnedCases.toString()}
self.onmessage = () => {
  try { self.postMessage({ kind: 'result', json: JSON.stringify(executePinnedCases()) }); }
  catch (error) { self.postMessage({ kind: 'error', message: String(error.stack || error) }); }
};`;
    const session = await browserSession();
    let oracle;
    try { oracle = JSON.parse(await runWorker(session.page, source, {})); }
    finally { await session.browser.close(); }
    const normalized = oracle.normalized;
    assert.deepEqual(normalized.frames.map(frame => frame.viewerNetworkTotals), oracle.viewerTotals);
    assert.deepEqual(oracle.viewerTotals, [
        { Rx: { bytes: 108, count: 3 }, Tx: { bytes: 17, count: 1 } },
        { Rx: { bytes: 200, count: 2 }, Tx: { bytes: 0, count: 0 } },
    ]);
    for (const viewerPacket of oracle.viewerPackets) {
        const packet = normalized.packetRelationships.find(packet => packet.packetId === viewerPacket.packetId);
        const byId = new Map(normalized.networkRecords.map(record => [record.id, record]));
        assert.deepEqual(packet.deserializationGroups.map(group => group.childRecordIds.map(id => byId.get(id).size.value)), viewerPacket.childValues);
    }
    const report = { passed: true, viewerSha256: assets.provenance.viewerSha256,
        checks: ['per-frame Rx/Tx sizes and counts match pinned viewer helpers', 'stage-2 children do not inflate stage-0 totals',
            'subtypes 10/13 excluded only from stage-2 child links', 'repeated packet groups and ordered child values match pinned viewer helpers'],
        viewerTotals: oracle.viewerTotals, viewerPackets: oracle.viewerPackets,
        limitation: 'Synthetic packed events exercise RawToEvent and the pinned Network plugin, not the vendor binary decoder or a real positive network dump.' };
    fs.writeFileSync(process.argv[3], JSON.stringify(report, null, 2) + '\n', { flag: 'wx' });
    console.log('PASS: positive synthetic records agree with pinned viewer Network plugin accounting and links');
}
