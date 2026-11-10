// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
'use strict';
const crypto = require('node:crypto');

// Legacy imported-source protocol only. Keys come from the caller, never from
// host credentials. This exposes two bounded RSA operations, not Node APIs.
function bytes(value, maximum) {
  if (typeof value !== 'string' || !value || value.length > maximum * 2 ||
      !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value)) throw Error();
  const result = Buffer.from(value, 'base64');
  if (!result.length || result.length > maximum || result.toString('base64') !== value) throw Error();
  return result;
}
module.exports = function rsaPkcs1(operation, key, input) {
  try {
    const encrypt = operation === 'encrypt';
    if (!encrypt && operation !== 'decrypt') throw Error();
    const der = bytes(key, 2048), data = bytes(input, encrypt ? 117 : 1024);
    const parsed = encrypt ? crypto.createPublicKey({key:der,format:'der',type:'spki'}) :
      crypto.createPrivateKey({key:der,format:'der',type:'pkcs8'});
    // The reviewed response key has a 1023-bit modulus, still a 128-byte block.
    // Keep that precise legacy size; do not silently accept arbitrary RSA keys.
    if (parsed.asymmetricKeyType !== 'rsa' || ![1023,1024].includes(parsed.asymmetricKeyDetails.modulusLength)) throw Error();
    if (encrypt) return crypto.publicEncrypt({key:parsed,padding:crypto.constants.RSA_PKCS1_PADDING},data).toString('base64');
    if (data.length % 128) throw Error();
    const output = [];
    for (let offset = 0; offset < data.length; offset += 128) {
      // Node 22 may disable OpenSSL PKCS#1 v1.5 privateDecrypt. Decode exactly
      // the protocol's type-2 block after the RSA primitive; never accept an
      // unpadded block, short PS, embedded zero in PS, or a different block type.
      const block = crypto.privateDecrypt({key:parsed,padding:crypto.constants.RSA_NO_PADDING},data.subarray(offset,offset+128));
      const end = block.indexOf(0, 2);
      if (block.length !== 128 || block[0] !== 0 || block[1] !== 2 || end < 10 || end === 127) throw Error();
      output.push(block.subarray(end + 1));
    }
    const result = Buffer.concat(output);
    if (result.length > 512) throw Error();
    return result.toString('base64');
  } catch (_) { throw Error('drpy_crypto_invalid'); }
};
