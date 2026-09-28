#!/usr/bin/env node
// Enumerate static Mocha-style test declarations. Counts are not expanded runtime cases or coverage.
const fs = require('node:fs'); const path = require('node:path');
const ts = require('typescript'); // Test tooling only; npm install typescript@5.8.3, or set NODE_PATH.
const root = process.argv[2]; const output = process.argv[3] || process.cwd();
if (!root) throw new Error('Usage: node inventory-upstream-tests.cjs <upstream-checkout> [output-dir]');
const packages = ['socket.io-client', 'engine.io-client', 'socket.io-parser', 'engine.io-parser'];
const entries = [];
function walk(dir) { return fs.readdirSync(dir,{withFileTypes:true}).flatMap(e => e.isDirectory() ? walk(path.join(dir,e.name)) : [path.join(dir,e.name)]); }
for (const pkg of packages) {
  for(const file of walk(path.join(root,'packages',pkg,'test')).sort()) {
    const rel=path.relative(root,file).split(path.sep).join('/');
    if (!/\.(?:[cm]?js|ts)$/.test(file) || /\/(?:support|fixtures)\//.test(rel)) continue;
    const source=ts.createSourceFile(file,fs.readFileSync(file,'utf8'),ts.ScriptTarget.Latest,true);
    function visit(node, parents=[], conditional=false) {
      if (ts.isCallExpression(node)) {
        const callee=node.expression.getText(source);
        const kind=callee.match(/^(describe|context|suite|it|specify|test)(?:\.(skip|only))?$/);
        if(kind && node.arguments.length) {
          const titleNode=node.arguments[0];
          const title=ts.isStringLiteralLike(titleNode) ? titleNode.text : titleNode.getText(source);
          const dynamic=!ts.isStringLiteralLike(titleNode);
          if(['it','specify','test'].includes(kind[1])) {
            entries.push({package:pkg, file:rel, line:source.getLineAndCharacterOfPosition(node.getStart(source)).line+1,
              scope:/test-d\.ts$/.test(file)?'typescript-type-contract':'runtime-declaration',
              suite:parents.join(' > '), title, modifier:kind[2]||'', conditional_or_parameterized:conditional||dynamic,
              status:'unmapped', swift_tests:'', review_note:''});
            return;
          }
          for (const arg of node.arguments.slice(1)) visit(arg,[...parents,title],conditional||dynamic||kind[2]==='skip');
          return;
        }
      }
      const nextConditional=conditional || ts.isIfStatement(node) || ts.isForStatement(node) || ts.isForOfStatement(node) ||
        (ts.isCallExpression(node) && /\.(forEach|map)$/.test(node.expression.getText(source)));
      ts.forEachChild(node,child=>visit(child,parents,nextConditional));
    }
    visit(source);
  }
}
fs.mkdirSync(output,{recursive:true});
fs.writeFileSync(path.join(output,'javascript-test-inventory.json'),JSON.stringify(entries,null,2)+'\n');
const counts={}; for(const e of entries) {const k=e.package+':'+e.scope;counts[k]=(counts[k]||0)+1;}
console.log(JSON.stringify({method:'static Mocha-style declarations; not expanded test executions or semantic coverage',counts,total:entries.length},null,2));
