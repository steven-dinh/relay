import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { inflateSync } from 'node:zlib';
import { createRequire } from 'node:module';
import { spawnSync } from 'node:child_process';
import { fileSha256, PINS, profileAssets, profileRuntime } from './runtime.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
export const LIMITS = Object.freeze({ html: 8 * 1024 ** 2, raw: 16 * 1024 ** 2,
  tools: 1024 ** 2, emitted: 16 * 1024 ** 2, output: 32 * 1024 ** 2,
  rawEntries: 1000000, records: 200000, frames: 32, decodeMs: 30000 });
const PIN = Object.freeze({
  viewer: '9a72bd475b9a87a8cd52bdf710fa864f48809099b8b0f2b20af79b4d734e0911',
  tools: '36a8c16e84cbc9a57381154227a74072ba471c752dd62167a3db4df918f85e46',
  rawVersion: 5, playwright: PINS.playwright, chromiumRevision: PINS.chromiumRevision,
});
const sha = data => createHash('sha256').update(data).digest('hex');
function requireThat(value, message) { if (!value) throw new Error(message); }

export function readBounded(filename, ceiling) {
  const fd = fs.openSync(filename, 'r');
  try {
    requireThat(fs.fstatSync(fd).size <= ceiling, 'input size limit exceeded');
    const bytes = Buffer.alloc(ceiling + 1);
    let size = 0, n;
    do { n = fs.readSync(fd, bytes, size, bytes.length - size, null); size += n; }
    while (n && size < bytes.length);
    requireThat(size <= ceiling, 'input grew beyond size limit');
    return bytes.subarray(0, size);
  } finally { fs.closeSync(fd); }
}

export function unpack(token, ceiling) {
  requireThat(token.length % 4 === 0 && /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(token), 'invalid base64');
  const container = Buffer.from(token, 'base64');
  requireThat(container.length >= 8, 'truncated container header');
  requireThat(container.toString('base64') === token, 'noncanonical base64');
  const rawSize = container.readUInt32LE(0), compressedSize = container.readUInt32LE(4);
  requireThat(rawSize > 0 && rawSize <= ceiling, 'declared decompressed size exceeds bound');
  requireThat(compressedSize === container.length - 8, 'compressed length mismatch');
  const result = inflateSync(container.subarray(8), { maxOutputLength: ceiling, info: true });
  requireThat(result.engine.bytesWritten === compressedSize, 'trailing compressed data');
  requireThat(result.buffer.length === rawSize, 'decompressed length mismatch');
  return result.buffer;
}

export function envelope(html) {
  requireThat(html.length <= LIMITS.html, 'HTML size limit exceeded');
  const text = new TextDecoder('utf-8', { fatal: true }).decode(html);
  const scripts = [...text.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/gi)];
  requireThat(scripts.length === 1 && sha(scripts[0][1]) === PIN.viewer, 'unsupported viewer identity');
  // The pinned script itself contains example comment literals. They are code, not containers.
  const comments = [...text.matchAll(/<!--([\s\S]*?)-->/g)].filter(m =>
    m.index < scripts[0].index || m.index >= scripts[0].index + scripts[0][0].length);
  const payloads = comments.filter(m => m[1].startsWith('R0FL'));
  requireThat(payloads.length === 1 && comments[0] === payloads[0], 'missing or ambiguous R0FL container');
  requireThat(comments.length === 2, 'unsupported HTML comment layout');
  const tools = unpack(comments[1][1].trim(), LIMITS.tools);
  requireThat(sha(tools) === PIN.tools, 'unsupported decoder identity');
  const raw = unpack(payloads[0][1].slice(4), LIMITS.raw);
  requireThat(raw.length >= 4 && raw.readUInt32LE(0) === PIN.rawVersion, 'unsupported raw format');
  return { raw, viewer: scripts[0][1], tools: new TextDecoder('utf-8', { fatal: true }).decode(tools),
    provenance: { htmlSha256: sha(html), rawSha256: sha(raw), viewerSha256: PIN.viewer,
      decoderSha256: PIN.tools, rawFormatVersion: PIN.rawVersion } };
}

function workerSource(assets, normalizeSource) {
  // Only the pinned baseline supplies executable assets. Incoming HTML is inert.
  return `globalThis.window = globalThis;
globalThis.document = { childNodes: [], getElementById() { return {}; }, createElement() { return {}; } };
Object.defineProperty(globalThis, 'g_Reload', { value: true, writable: false, configurable: true });
${assets.viewer}
Object.defineProperty(globalThis, 'g_Reload', { value: false, writable: true, configurable: true });
globalThis.g_cliMode = true;
${assets.tools}
${normalizeSource}
self.onmessage = async function(event) {
  const send = self.postMessage.bind(self);
  self.postMessage = () => {};
  try {
    const input = event.data;
    const caps = input.caps;
    const binary = atob(input.rawBase64);
    const raw = Uint8Array.from(binary, character => character.charCodeAt(0));
    if (raw.length > caps.raw + 8) throw new Error('raw input bound exceeded');
    self.Tools = await ToolsModule();
    Tools.ccall('Init', 'number', []);
    Tools.ccall('SetWorkerMode', 'number', ['number'], [0]);
    self.isWorker = false;
    InitDataVars();
    let emitted = 0;
    const execute = self.ExecStatement;
    self.ExecStatement = function(source) {
      emitted += new TextEncoder().encode(source).length;
      if (emitted > caps.emitted) throw new Error('emitted statement bound exceeded');
      execute(source);
    };
    const pointer = Tools._malloc(raw.length);
    try {
      Tools.HEAPU8.set(raw, pointer);
      const meta = ComposeExporterFuncMetaArg('ParseRaw', 'capture.html', 0, 0);
      Tools.cwrap('ParseRaw', 'number', ['string', 'number', 'number'])(meta, pointer, raw.length);
    } finally { Tools._free(pointer); }
    if (!Array.isArray(Frames)) throw new Error('decoder did not produce frames');
    if (Frames.length === 0) throw new Error('dump contains no captured frames; measurements unavailable');
    if (Frames.length > caps.frames) throw new Error('frame count exceeds supported 32-frame scope');
    let entries = 0;
    for (const frame of Frames) for (const stream of frame.tt) entries += stream.length;
    if (entries > caps.rawEntries) throw new Error('raw entry bound exceeded');
    InitViewerVars(); InitPluginVars(); InitGroups(); InitFrameInfo(); PreprocessMinimal();
    CliInitPlugins(false);
    const networkPlugins = g_Ext.plugins.filter(plugin => plugin.category === 'Network');
    if (networkPlugins.length !== 1) throw new Error('Network viewer plugin unavailable');
    const networkPlugin = networkPlugins[0];
    for (const plugin of g_Ext.plugins) if (!plugin.isBackground) plugin.isActive = plugin === networkPlugin;
    g_Ext.currentPlugin = networkPlugin;
    for (let type = EventBaseId + 1; type <= EventBaseId + 4; type++) {
      const entry = g_Ext.typeLookup[type];
      if (!entry || entry.plugin !== networkPlugin) throw new Error('Network viewer event selection unavailable');
      entry.subSelections.fill(true);
    }
    // Hidden empty plugins are omitted by InitPluginStates; initialize explicit zero totals too.
    for (const key of ['subscribedFrameStart', 'subscribedScopeEnter', 'subscribedScopeExit']) {
      if (!g_Ext[key].includes(networkPlugin)) g_Ext[key].push(networkPlugin);
    }
    PrepareEvents();
    const normalized = normalizeNetwork({ expectedMarker: input.marker,
      maxRawEntries: caps.rawEntries, maxRecords: caps.records });
    const plainTotals = value => ({ rx: { sum: value.rx.sum, count: value.rx.count },
      tx: { sum: value.tx.sum, count: value.tx.count } });
    const viewerTotals = Frames.map(frame => ({ id: String(frame.id), totals: plainTotals(frame.netTotals),
      eventStats: frame.netEventStats.map(plainTotals) }));
    normalized.availability.viewerNetworkTotalsAvailable = true;
    const result = { ...normalized, viewerTotals, decoder: { emittedBytes: emitted, rawEntries: entries,
      heapBytes: Tools.HEAPU8.length, dumpHost: typeof DumpHost === 'string' ? DumpHost : null,
      tickToTimeScale: g_TickToTimeScale } };
    const json = JSON.stringify(result, (_key, value) => typeof value === 'bigint' ? value.toString() : value);
    if (new TextEncoder().encode(json).length > caps.output) throw new Error('output bound exceeded');
    send({ kind: 'result', json });
  } catch(error) { send({ kind: 'error', message: String(error?.stack || error).slice(0, 4000) }); }
};`;
}

const CSP = "default-src 'none'; script-src blob: 'unsafe-eval'; worker-src blob:; connect-src 'none'; base-uri 'none'; form-action 'none'; frame-src 'none'; object-src 'none'";

export async function browserSession() {
  const runtime = profileRuntime();
  const require = createRequire(path.join(runtime.root, 'node/node_modules/_relay-resolve.cjs'));
  const { chromium } = require('playwright');
  requireThat(require('playwright/package.json').version === PIN.playwright, 'unsupported Playwright version');
  requireThat(chromium.executablePath().includes(`chromium-${PIN.chromiumRevision}`), 'unsupported Chromium revision');
  const browser = await chromium.launch({ headless: true, chromiumSandbox: true,
    args: ['--enable-automation', '--js-flags=--max-old-space-size=128 --wasm-max-mem-pages=4096'], timeout: 15000 });
  try {
    const cdp = await browser.newBrowserCDPSession();
    const { arguments: args } = await cdp.send('Browser.getBrowserCommandLine');
    requireThat(!args.includes('--no-sandbox') && !args.includes('--disable-web-security'), 'browser sandbox disabled');
    const context = await browser.newContext({ offline: true, acceptDownloads: false, serviceWorkers: 'block' });
    await context.route('**/*', route => route.abort());
    await context.routeWebSocket('**/*', socket => socket.close());
    await context.clearPermissions();
    const page = await context.newPage();
    context.on('page', popup => { if (popup !== page) void popup.close(); });
    page.on('dialog', dialog => void dialog.dismiss());
    await page.setContent(`<meta http-equiv="Content-Security-Policy" content="${CSP}">`);
    requireThat(browser.version() === PINS.chromiumVersion, 'unsupported Chromium version');
    return { browser, page, version: browser.version(), sandboxEnabled: true };
  } catch (error) { await browser.close(); throw error; }
}

export async function runWorker(page, source, input) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => {
      // The outer Windows Job owner observes this root exit and kills all descendants.
      process.stderr.write('decoder host deadline exceeded\n');
      process.exit(124);
    }, LIMITS.decodeMs);
  });
  try {
    return await Promise.race([timeout, page.evaluate(async ({ source, input, limit, timeoutMs }) => {
      return new Promise((resolve, reject) => {
        const url = URL.createObjectURL(new Blob([source], { type: 'text/javascript' }));
        const worker = new Worker(url);
        const finish = (error, value) => {
          clearTimeout(timer); worker.terminate(); URL.revokeObjectURL(url);
          if (error) reject(error); else resolve(value);
        };
        const timer = setTimeout(() => finish(new Error('worker deadline exceeded')), timeoutMs);
        worker.onerror = event => finish(new Error(String(event.message).slice(0, 4000)));
        worker.onmessage = event => {
          const data = event.data;
          if (!data || typeof data !== 'object') return finish(new Error('invalid worker message'));
          if (data.kind === 'error' && typeof data.message === 'string') return finish(new Error(data.message.slice(0, 4000)));
          if (data.kind !== 'result' || typeof data.json !== 'string' || data.json.length > limit)
            return finish(new Error('invalid or excessive worker output'));
          finish(null, data.json);
        };
        worker.postMessage(input);
      });
    }, { source, input, limit: LIMITS.output, timeoutMs: LIMITS.decodeMs })]);
  } finally { clearTimeout(timer); }
}

export async function extract(filename, marker = null) {
  requireThat(marker === null || (typeof marker === 'string' && marker.length <= 256), 'marker too long');
  const input = envelope(readBounded(filename, LIMITS.html));
  const anchor = profileAssets();
  const assets = envelope(readBounded(anchor, LIMITS.html));
  const normalizer = readBounded(path.join(HERE, 'normalize-network.js'), 256 * 1024).toString('utf8');
  const session = await browserSession();
  try {
    const resultJson = await runWorker(session.page, workerSource(assets, normalizer),
      { rawBase64: Buffer.concat([Buffer.from('    R0FL'), input.raw]).toString('base64'), marker, caps: LIMITS });
    requireThat(Buffer.byteLength(resultJson) <= LIMITS.output, 'output byte bound exceeded');
    const result = JSON.parse(resultJson);
    return sealResult(result, { ...input.provenance,
      anchorSha256: fileSha256(anchor),
      parserSha256: sha(fs.readFileSync(fileURLToPath(import.meta.url))), normalizerSha256: sha(normalizer),
      runtimeModuleSha256: fileSha256(path.join(HERE, 'runtime.mjs')),
      boundedProcessSha256: fileSha256(path.join(HERE, 'bounded-process.py')),
      nodeVersion: PINS.nodeVersion, nodeSha256: PINS.nodeSha256,
      pythonVersion: PINS.pythonVersion, pythonSha256: PINS.pythonSha256,
      playwright: PIN.playwright, chromiumRevision: PIN.chromiumRevision, chromiumVersion: session.version });
  } finally { await session.browser.close(); }
}

export function sealResult(result, provenance) {
  requireThat(result && Array.isArray(result.frames) && result.frames.length <= LIMITS.frames
    && Array.isArray(result.networkRecords) && result.networkRecords.length <= LIMITS.records, 'invalid normalized result');
  const report = {};
  for (const key of ['frames', 'markerDescriptors', 'markerExecutions', 'networkRecords', 'unknownEvents',
    'packetRelationships', 'unresolvedLinks', 'accounting', 'availability', 'unsupported', 'viewerTotals', 'decoder']) {
    if (Object.hasOwn(result, key)) report[key] = result[key];
  }
  if (report.accounting) report.accounting = { ...report.accounting,
    bytesPerSecond: null, bytesPerWorkloadEvent: null, workloadAttributed: false, physicalWireBytes: false };
  return { ...report, format: 'relay-microprofiler-network-v1', provenance,
    qualification: { decoded: true, retained: false, historyPreserved: false, workloadAttributed: false } };
}

async function main(args) {
  if (args[0] !== '--bounded-child') {
    const runtime = profileRuntime();
    const command = [path.join(HERE, 'bounded-process.py'), '--', runtime.node,
      fileURLToPath(import.meta.url), '--bounded-child', ...args];
    const run = spawnSync(runtime.python, command, { stdio: 'inherit', windowsHide: true });
    if (run.error) throw run.error;
    process.exitCode = run.status ?? 1;
    return;
  }
  args.shift();
  requireThat(args.length >= 2, 'usage: node extract-network.mjs INPUT.html OUTPUT.json [MARKER]');
  const [input, output, marker = null] = args;
  requireThat(args.length <= 3, 'unexpected arguments');
  requireThat(!fs.existsSync(output), 'output already exists');
  const result = await extract(input, marker);
  const json = JSON.stringify(result, null, 2) + '\n';
  requireThat(Buffer.byteLength(json) <= LIMITS.output, 'formatted output bound exceeded');
  fs.writeFileSync(output, json, { flag: 'wx' });
  console.log(JSON.stringify({ output: path.resolve(output), frames: result.frames.length,
    networkRecords: result.networkRecords.length, qualification: result.qualification }));
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).catch(error => { console.error(String(error.message).slice(0, 5000)); process.exitCode = 1; });
}
