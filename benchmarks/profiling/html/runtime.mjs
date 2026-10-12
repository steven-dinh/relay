import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';

export const PINS = Object.freeze({
  nodeVersion: 'v24.19.0',
  nodeBytes: 92825416,
  nodeSha256: '3602f2bb1a10f2cbab4c36886218a33c1ab3db87290e73b033c46c77147d0237',
  pythonVersion: 'Python 3.12.14',
  pythonBytes: 106448,
  pythonSha256: '10d845f50a2af64e3500bb2fcb348b5bc98a75d8ddada63e45ba1da6a1fc79d1',
  anchorBytes: 867369,
  anchorSha256: '830a40c6ef29ae15ced56f9fbc2cc987b015f0ea7e217dbb5380e87a9d806a96',
  playwright: '1.62.1',
  chromiumRevision: '1234',
  chromiumVersion: '151.0.7922.34',
});

function requireThat(value, message) {
  if (!value) throw new Error(message);
}

function sha256File(filename, expectedBytes) {
  const stat = fs.statSync(filename);
  requireThat(stat.isFile() && (expectedBytes === undefined || stat.size === expectedBytes),
    'unsupported pinned file size');
  const hash = createHash('sha256');
  const fd = fs.openSync(filename, 'r');
  const chunk = Buffer.allocUnsafe(1024 * 1024);
  try {
    let count;
    while ((count = fs.readSync(fd, chunk, 0, chunk.length, null)) !== 0) hash.update(chunk.subarray(0, count));
  } finally {
    fs.closeSync(fd);
  }
  return hash.digest('hex');
}

export function profileRuntime() {
  const root = process.env.RELAY_PROFILE_RUNTIME;
  requireThat(typeof root === 'string' && path.isAbsolute(root), 'RELAY_PROFILE_RUNTIME must be an absolute runtime root');
  const node = path.join(root, 'node/bin/node.exe');
  const python = path.join(root, 'python/python.exe');
  requireThat(sha256File(node, PINS.nodeBytes) === PINS.nodeSha256, 'unsupported pinned Node executable');
  requireThat(sha256File(process.execPath, PINS.nodeBytes) === PINS.nodeSha256 && process.version === PINS.nodeVersion,
    'run the CLI with the pinned Node executable');
  requireThat(sha256File(python, PINS.pythonBytes) === PINS.pythonSha256, 'unsupported pinned Python executable');
  const version = spawnSync(python, ['--version'], { encoding: 'utf8', windowsHide: true });
  requireThat(version.status === 0 && (version.stdout || version.stderr).trim() === PINS.pythonVersion,
    'pinned Python version check failed');
  return { root: path.resolve(root), node, python };
}

export function profileAssets() {
  const filename = process.env.RELAY_PROFILE_ASSETS;
  requireThat(typeof filename === 'string' && path.isAbsolute(filename),
    'RELAY_PROFILE_ASSETS must name the reviewed external anchor HTML');
  requireThat(sha256File(filename, PINS.anchorBytes) === PINS.anchorSha256, 'unsupported reviewed anchor HTML');
  return path.resolve(filename);
}

export function fileSha256(filename) {
  return sha256File(filename);
}
