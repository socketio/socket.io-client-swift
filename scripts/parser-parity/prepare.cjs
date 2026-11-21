const fs = require('node:fs'), path = require('node:path'), crypto = require('node:crypto');
const ts = require('typescript');
const root = process.argv[2], out = path.join(process.env.PARITY_TEMP, 'js');
const hashes = {
  "packages/socket.io-parser/lib/index.ts": "af93953f698c09b1750c5ef7af6219f66b6ceeccad3dd58765de3baefd0e0576",
  "packages/socket.io-parser/lib/binary.ts": "f825fb4ed6239a57db66290b4007de347ff84d4aac1a630bff5ca9ea252de0e4",
  "packages/socket.io-parser/lib/is-binary.ts": "0e986c7d272b92eaef4d8bc36437a91d3609d50a2156cd047b81760fa2a17ec8",
  "packages/socket.io-component-emitter/lib/cjs/index.js": "035ac0e824962a30ea6b60ffbf8dd158232514430f67e378faeb73144bb1ca0e"
};
for (const [file, expected] of Object.entries(hashes)) {
  const actual = crypto.createHash('sha256').update(fs.readFileSync(path.join(root, file))).digest('hex');
  if (actual !== expected) throw new Error('Pinned upstream source changed: ' + file);
}
fs.mkdirSync(path.join(out, 'node_modules/@socket.io/component-emitter'), {recursive:true});
fs.cpSync(path.join(root, 'packages/socket.io-component-emitter/lib/cjs'), path.join(out, 'node_modules/@socket.io/component-emitter'), {recursive:true});
// Disable logging only; decoder and event-emitter logic remain the actual upstream source.
fs.mkdirSync(path.join(out, 'node_modules/debug'), {recursive:true});
fs.writeFileSync(path.join(out, 'node_modules/debug/index.js'), 'module.exports = () => () => {};\n');
for (const name of ['index', 'binary', 'is-binary']) {
  const source = fs.readFileSync(path.join(root, 'packages/socket.io-parser/lib', name + '.ts'), 'utf8');
  fs.writeFileSync(path.join(out, name + '.js'), ts.transpileModule(source, {compilerOptions:{module:ts.ModuleKind.CommonJS, target:ts.ScriptTarget.ES2020, esModuleInterop:true}}).outputText);
}
