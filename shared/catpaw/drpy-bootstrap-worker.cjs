// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
'use strict';
const { parentPort, workerData } = require('node:worker_threads');
const fs = require('node:fs');
const crypto = require('node:crypto');
const { extractKnownPlugin, MAX } = require('./drpy-guard-extractor.cjs');
try {
  const stat = fs.lstatSync(workerData.file);
  if (!stat.isFile() || stat.isSymbolicLink() || !stat.size || stat.size > MAX) throw Error('invalid_artifact');
  const descriptor = fs.openSync(workerData.file, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0));
  let data;
  try {
    const opened = fs.fstatSync(descriptor);
    if (!opened.isFile() || !opened.size || opened.size > MAX) throw Error('invalid_artifact');
    data = Buffer.alloc(opened.size);
    let offset = 0;
    while (offset < data.length) { const read = fs.readSync(descriptor, data, offset, data.length - offset, offset); if (!read) throw Error('guard_artifact_integrity'); offset += read; }
    if (fs.readSync(descriptor, Buffer.alloc(1), 0, 1, offset)) throw Error('guard_artifact_integrity');
  } finally { fs.closeSync(descriptor); }
  if (crypto.createHash('sha256').update(data).digest('hex') !== workerData.hash) throw Error('guard_artifact_integrity');
  const adapter = workerData.adapter;
  if (!['dm84-v1', 'auete-v1', 'bttwoo-v1', 'appgz-v1', 't4-v1', 'fy-v1'].includes(adapter)) throw Error('invalid_artifact');
  const config = adapter === 't4-v1' ? require('./drpy-t4-extractor.cjs').extractT4(data, workerData.extension) :
    adapter === 'fy-v1' ? require('./drpy-fy-extractor.cjs').extractFy(data) : extractKnownPlugin(data, adapter);
  const factory = { 'dm84-v1': './drpy-dm84-adapter.cjs', 'auete-v1': './drpy-auete-adapter.cjs', 'bttwoo-v1': './drpy-bttwoo-adapter.cjs', 'appgz-v1': './drpy-appgz-adapter.cjs', 't4-v1': './drpy-t4-adapter.cjs', 'fy-v1':'./drpy-fy-adapter.cjs' }[adapter];
  const rule = require(factory)(config);
  parentPort.postMessage({ version: 1, rule, origin: config.origin });
} catch (error) {
  parentPort.postMessage({ error: ['guard_artifact_unsupported', 'guard_artifact_integrity'].includes(error.message) ? error.message : 'guard_artifact_invalid' });
}
