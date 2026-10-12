import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import http from 'node:http';
import { fileURLToPath } from 'node:url';
import { deflateSync } from 'node:zlib';
import { spawnSync } from 'node:child_process';
import { envelope, unpack, LIMITS, browserSession, runWorker, sealResult } from './extract-network.mjs';
import { profileAssets, profileRuntime } from './runtime.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const EVENT_CATEGORY_COUNT = 14;

function exactKeys(value, keys) {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    && Object.keys(value).sort().join('\0') === [...keys].sort().join('\0');
}
function safeCounter(value, keys) {
  if (!exactKeys(value, keys)) return false;
  for (const key of keys) {
    if (!Number.isSafeInteger(value[key]) || value[key] < 0) return false;
  }
  return true;
}
function viewerTotalMatchesFrame(viewer, frame) {
  if (!exactKeys(viewer?.totals, ['rx', 'tx'])) return false;
  if (!safeCounter(viewer.totals.rx, ['sum', 'count']) || !safeCounter(viewer.totals.tx, ['sum', 'count'])) return false;
  if (!exactKeys(frame?.viewerNetworkTotals, ['Rx', 'Tx'])) return false;
  for (const [direction, field] of [['Rx', 'rx'], ['Tx', 'tx']]) {
    const expected = frame.viewerNetworkTotals[direction];
    if (!safeCounter(expected, ['bytes', 'count'])) return false;
    if (viewer.totals[field].sum !== expected.bytes || viewer.totals[field].count !== expected.count) return false;
  }
  if (!Array.isArray(viewer.eventStats) || viewer.eventStats.length !== EVENT_CATEGORY_COUNT) return false;
  for (const category of viewer.eventStats) {
    if (!exactKeys(category, ['rx', 'tx'])) return false;
    if (!safeCounter(category.rx, ['sum', 'count']) || !safeCounter(category.tx, ['sum', 'count'])) return false;
  }
  return true;
}
function networkStatsShapeRegressionChecks() {
  const frame = { viewerNetworkTotals: { Rx: { bytes: 7, count: 2 }, Tx: { bytes: 3, count: 1 } } };
  const counter = () => ({ sum: 0, count: 0 });
  const viewer = { totals: { rx: { sum: 7, count: 2 }, tx: { sum: 3, count: 1 } },
    eventStats: Array.from({ length: EVENT_CATEGORY_COUNT }, () => ({ rx: counter(), tx: counter() })) };
  assert.equal(viewerTotalMatchesFrame(viewer, frame), true, 'valid pinned viewer shape rejected');
  const missingCategory = structuredClone(viewer);
  missingCategory.eventStats.pop();
  assert.equal(viewerTotalMatchesFrame(missingCategory, frame), false, 'dropped category accepted');
  const missingField = structuredClone(viewer);
  delete missingField.eventStats[0].rx.count;
  assert.equal(viewerTotalMatchesFrame(missingField, frame), false, 'dropped counter field accepted');
  const negativeField = structuredClone(viewer);
  negativeField.eventStats[0].rx.sum = -1;
  assert.equal(viewerTotalMatchesFrame(negativeField, frame), false, 'negative counter accepted');
  return ['dropped-category-rejected', 'dropped-counter-field-rejected', 'negative-counter-rejected'];
}

function packed(raw, trailing = Buffer.alloc(0)) {
  const compressed = Buffer.concat([deflateSync(raw), trailing]);
  const header = Buffer.alloc(8);
  header.writeUInt32LE(raw.length); header.writeUInt32LE(compressed.length, 4);
  return Buffer.concat([header, compressed]).toString('base64');
}
function containerChecks() {
  const baseline = fs.readFileSync(profileAssets());
  assert.equal(envelope(baseline).provenance.rawFormatVersion, 5);
  assert.deepEqual(unpack(packed(Buffer.from('abc')), 3), Buffer.from('abc'));
  assert.throws(() => unpack('not base64', 10), /base64/);
  assert.throws(() => unpack('AA==', 10), /header/);
  assert.throws(() => unpack(packed(Buffer.alloc(11)), 10), /bound/);
  assert.throws(() => unpack(packed(Buffer.from('abc'), Buffer.from([0])), 10), /trailing/);
  const huge = Buffer.from(packed(Buffer.alloc(1000)), 'base64'); huge.writeUInt32LE(5);
  assert.throws(() => unpack(huge.toString('base64'), 10));
  const badLength = Buffer.from(packed(Buffer.from('abc')), 'base64'); badLength.writeUInt32LE(100, 4);
  assert.throws(() => unpack(badLength.toString('base64'), 10), /length/);
  assert.throws(() => envelope(Buffer.from('<!--R0FLAAAA-->')), /viewer|layout/);
  assert.throws(() => envelope(Buffer.concat([baseline, Buffer.from('<!--R0FLAAAA-->')])), /ambiguous/);
  const altered = baseline.toString('utf8').replace('function ExecStatement(js)', 'function OtherStatement(js)');
  assert.throws(() => envelope(Buffer.from(altered)), /identity/);
  assert.throws(() => envelope(Buffer.alloc(LIMITS.html + 1)), /limit/);
  const sealed = sealResult({ frames: [], networkRecords: [], provenance: { trusted: false },
    format: 'forged', qualification: { workloadAttributed: true, historyPreserved: true },
    accounting: { workloadAttributed: true, physicalWireBytes: true } }, { trusted: true });
  assert.equal(sealed.provenance.trusted, true);
  assert.equal(sealed.qualification.workloadAttributed, false);
  assert.equal(sealed.qualification.historyPreserved, false);
  assert.equal(sealed.accounting.physicalWireBytes, false);
  console.log('Container bounds, exact assets, ambiguity and malformed-input checks passed.');
}

async function securityChecks() {
  let requests = 0;
  const server = http.createServer((_request, response) => { requests++; response.end('unexpected'); });
  server.on('upgrade', (_request, socket) => { requests++; socket.destroy(); });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const endpoint = `http://127.0.0.1:${server.address().port}/denied`;
  const session = await browserSession();
  try {
    const source = `self.onmessage = async ({data}) => {
      const blocked = async operation => { try { await operation(); return false; } catch { return true; } };
      const fetchHttp = await blocked(() => fetch(data.endpoint));
      const fetchFile = await blocked(() => fetch('file:///C:/Windows/win.ini'));
      const scriptHttp = await blocked(() => importScripts(data.endpoint));
      const scriptFile = await blocked(() => importScripts('file:///C:/Windows/win.ini'));
      const socket = await new Promise(resolve => { try {
        const ws = new WebSocket(data.endpoint.replace('http:', 'ws:'));
        ws.onopen = () => { ws.close(); resolve(false); };
        ws.onerror = () => resolve(true);
      } catch { resolve(true); } });
      const nestedSource = 'onmessage = async({data}) => { try { await fetch(data); postMessage(false); } catch { postMessage(true); } };';
      const nestedUrl = URL.createObjectURL(new Blob([nestedSource], {type:'text/javascript'}));
      const nested = await new Promise(resolve => {
        const child = new Worker(nestedUrl);
        child.onmessage = ({data}) => { child.terminate(); resolve(data); };
        child.onerror = () => { child.terminate(); resolve(true); };
        child.postMessage(data.endpoint);
      });
      URL.revokeObjectURL(nestedUrl);
      // Internally declared wasm memory: initial1, max8192 pages; V8 caps growth at4096.
      const wasm = new Uint8Array([0,97,115,109,1,0,0,0,5,5,1,1,1,128,64,7,10,1,6,109,101,109,111,114,121,2,0]);
      const module = await WebAssembly.instantiate(wasm);
      const wasmBound = await blocked(() => module.instance.exports.memory.grow(4096));
      postMessage({kind:'result',json:JSON.stringify({fetchHttp,fetchFile,scriptHttp,scriptFile,socket,nested,wasmBound,
        nodeAbsent:typeof process==='undefined' && typeof require==='undefined',
        hostAbsent:typeof nodeRepl==='undefined' && typeof showOpenFilePicker==='undefined'})});
    };`;
    const result = JSON.parse(await runWorker(session.page, source, { endpoint }));
    for (const [name, value] of Object.entries(result)) assert.equal(value, true, name);
    assert.equal(requests, 0, 'a denied worker request reached a real listener');
    assert.equal(session.sandboxEnabled, true);
    await assert.rejects(runWorker(session.page, 'onmessage=()=>postMessage("untrusted text")', {}), /invalid worker message/);
    console.log(JSON.stringify({ securityChecks: 'passed', chromium: session.version, observedRequests: requests, ...result }));
  } finally { await session.browser.close(); await new Promise(resolve => server.close(resolve)); }
}

if (process.argv.includes('--network-regression')) {
  const outputs = process.argv.slice(process.argv.indexOf('--network-regression') + 1);
  assert.ok(outputs.length > 0, 'provide fresh extractor JSON outputs');
  const structuralChecks = networkStatsShapeRegressionChecks();
  let positiveRecords = 0;
  for (const filename of outputs) {
    const report = JSON.parse(fs.readFileSync(filename, 'utf8'));
    assert.equal(report.availability.viewerNetworkTotalsAvailable, true);
    assert.ok(Array.isArray(report.frames) && report.frames.length > 0, 'network regression requires frames');
    assert.ok(Array.isArray(report.viewerTotals) && report.viewerTotals.length === report.frames.length,
      'viewer totals must be present for every frame');
    for (let index = 0; index < report.frames.length; index++) {
      const frame = report.frames[index], viewer = report.viewerTotals[index];
      assert.equal(viewerTotalMatchesFrame(viewer, frame), true,
        `frame ${index} must contain 14 explicit categories and safe rx/tx counters`);
    }
    positiveRecords += report.networkRecords.length;
  }
  assert.ok(positiveRecords > 0, 'regression requires a real positive network capture');
  console.log(JSON.stringify({ networkViewerRegression: 'passed', outputs: outputs.length, positiveRecords, structuralChecks }));
} else if (process.argv.includes('--cli-failures')) {
  const args = process.argv.slice(process.argv.indexOf('--cli-failures') + 1);
  assert.equal(args.length, 3, 'provide an empty-capture input, existing output, and new failure output path');
  const [emptyInput, existingOutput, newOutput] = args.map(filename => path.resolve(filename));
  assert.ok(fs.existsSync(emptyInput) && fs.existsSync(existingOutput));
  assert.ok(!fs.existsSync(newOutput), 'failure output path must be new');
  const runtime = profileRuntime();
  const cli = fileURLToPath(new URL('./extract-network.mjs', import.meta.url));
  const empty = spawnSync(runtime.node, [cli, emptyInput, newOutput],
    { encoding: 'utf8', windowsHide: true });
  assert.notEqual(empty.status, 0, 'empty capture must fail');
  assert.match(`${empty.stdout}\n${empty.stderr}`, /dump contains no captured frames/i);
  assert.ok(!fs.existsSync(newOutput), 'empty capture must not create a measurement report');
  const before = fs.readFileSync(existingOutput);
  const overwrite = spawnSync(runtime.node, [cli, emptyInput, existingOutput],
    { encoding: 'utf8', windowsHide: true });
  assert.notEqual(overwrite.status, 0, 'existing output must be rejected');
  assert.match(`${overwrite.stdout}\n${overwrite.stderr}`, /output already exists/i);
  assert.deepEqual(fs.readFileSync(existingOutput), before, 'existing output bytes changed');
  console.log(JSON.stringify({ emptyCapture: 'rejected-without-report', overwrite: 'rejected-with-bytes-preserved' }));
} else if (process.argv.includes('--security-child')) {
  await securityChecks();
} else {
  containerChecks();
  const runtime = profileRuntime();
  const result = spawnSync(runtime.python,
    [path.join(HERE, 'bounded-process.py'), '--', runtime.node, fileURLToPath(import.meta.url), '--security-child'],
    { stdio: 'inherit', windowsHide: true });
  if (result.error) throw result.error;
  assert.equal(result.status, 0, 'bounded browser security probe failed');
}
