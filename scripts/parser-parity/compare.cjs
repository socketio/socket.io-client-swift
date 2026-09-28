const {Decoder, Encoder} = require(require('path').join(process.env.PARITY_TEMP, 'js/index.js'));
const {spawnSync}=require('child_process'); const fs=require('fs');
let seed=0x12345789; function rand(n) {seed=(Math.imul(seed,1664525)+1013904223)>>>0;return seed%n;}
function scalar() {return [null,true,false,-1,0,5,12345,1.5,'','a','é🦧','"[,]\\',String(rand(999))][rand(13)];}
function value(depth=0) { if(depth>3 || rand(4)<2)return scalar();return rand(2)?[value(depth+1),value(depth+1)]:{x:value(depth+1),unicode:'🦧',y:value(depth+1)};}
const vectors=[];
for(let i=0;i<5000;i++) {
 const type=rand(7);const ns=['/','/foo','/é🦧'][rand(3)];const id=[undefined,0,1,999][rand(4)];
 let data;let binaries=[];let header=String(type);
 if(type===5||type===6) {const n=1+rand(3);header+=n+'-';for(let b=0;b<n;b++)binaries.push(Array.from({length:rand(12)},()=>rand(256)));
 data=(type===5?['event']:[]).concat(binaries.map((_,num)=>({_placeholder:true,num})),[value()]);}
 else if(type===2)data=[rand(2)?'event':123,value(),value()];
 else if(type===3)data=[value(),value()];
 else if(type===0)data={sid:'s'+rand(9),a:value()};
 else if(type===4)data=rand(2)?'denied':{message:'denied',data:value()};
 if(ns!=='/')header+=ns+',';
 if([2,3,5,6].includes(type)&&id!==undefined)header+=id;
 if(data!==undefined)header+=JSON.stringify(data);
 vectors.push({class:'valid',header,binaries});
}
for(const header of ['', '2','3','4','5','6','2123','51-','51','50-["x"]','5a-','511-["x"]','20[]','2[true]','2[null]','2[{}]','1{}','0[]','41','4[1]','8','2["connect"]','2["removeListener"]','51-["x",{"_placeholder":true,"num":-1}]','51-["x",{"_placeholder":true,"num":99}]','51-["x",{"_placeholder":true,"num":"0"}]','51-["x",{"_placeholder":1,"num":0}]','501-["x",{"_placeholder":true,"num":0}]','51e0-["x",{"_placeholder":true,"num":0}]'])vectors.push({class:'malformed-or-noncanonical',header,binaries:header.startsWith('5')?[[1]]:[]});
// Encode direction: the Swift encoder produces the wire form, the pinned
// JavaScript decoder reads it, and the result must be the source packet again.
// Attachments are written as {__bytes:[...]} markers, which is also what the
// normalizer below produces for a decoded Buffer.
function bytes() {return {__bytes:Array.from({length:1+rand(8)},()=>rand(256))};}
function binaryValue(depth=0) {if(depth>2||rand(4)<2)return rand(3)===0?bytes():scalar();return rand(2)?[binaryValue(depth+1),binaryValue(depth+1)]:{x:binaryValue(depth+1),unicode:'🦧',y:binaryValue(depth+1)};}
const encodeVectors=[];
for(let i=0;i<1000;i++) {
 const type=[0,1,2,2,3,3,4][rand(7)];const nsp=['/','/foo','/é🦧'][rand(3)];
 let id;let data;
 if(type===2)   {id=[undefined,0,1,999][rand(4)];data=['event',binaryValue(),binaryValue()];}
 else if(type===3) {id=[undefined,0,1,999][rand(4)];data=[binaryValue(),binaryValue()];}
 else if(type===0) data={sid:'s'+rand(9),a:value()};
 else if(type===4) data=rand(2)?'denied':{message:'denied',data:value()};
 encodeVectors.push({type,nsp,id,data});
}
function norm(v) {if(Buffer.isBuffer(v))return {__bytes:Array.from(v)};if(Array.isArray(v))return v.map(norm);if(v&&typeof v==='object')return Object.fromEntries(Object.entries(v).map(([k,x])=>[k,norm(x)]));return v;}
function decode(header, binaries) {try {let result={status:'pending'};const d=new Decoder();d.on('decoded',p=>{result={status:'ok',type:p.type,id:p.id??-1,nsp:p.nsp,data:norm(p.data??null)}});d.add(header);for(const b of binaries)d.add(Buffer.from(b));return result;}catch {return {status:'error'};}}
function javascript(input) {return decode(input.header, input.binaries);}
// Exercise the actual pinned JS encoder too. Compare normalized packet
// semantics in both directions; object key order and attachment numbering
// are representation choices, not meaningful JSON differences.
function restore(v) {
 if(Array.isArray(v))return v.map(restore);
 if(v&&typeof v==='object') {
  if(Object.keys(v).length===1&&Array.isArray(v.__bytes))return Buffer.from(v.__bytes);
  return Object.fromEntries(Object.entries(v).map(([k,x])=>[k,restore(x)]));
 }
 return v;
}
const referenceWire=encodeVectors.map(v=>{
 const packet={...v}; if(v.data!==undefined)packet.data=restore(v.data);
 const frames=new Encoder().encode(packet);
 return {header:frames[0],binaries:frames.slice(1).map(b=>Array.from(b))};
});
const input=vectors.map(JSON.stringify).concat(encodeVectors.map(v=>JSON.stringify({encode:v})))
 .concat(referenceWire.map(JSON.stringify)).join('\n')+'\n';
const proc=spawnSync(require('path').join(process.env.PARITY_TEMP, 'swift-decoder'),[],{cwd:process.env.PARITY_TEMP,input,maxBuffer:32*1024*1024,encoding:'utf8'});
if(proc.status!==0)throw new Error(proc.stderr);
const out=proc.stdout.trim().split('\n').map(JSON.parse);
if(out.length !== vectors.length + 2*encodeVectors.length) throw new Error('Incomplete Swift output');
const sw=out.slice(0, vectors.length);
const encoded=out.slice(vectors.length, vectors.length+encodeVectors.length);
const decodedReference=out.slice(vectors.length+encodeVectors.length);
const differences=[];
const canonical = v=>JSON.stringify(v,(k,x)=>x&&typeof x==='object'&&!Array.isArray(x)?Object.fromEntries(Object.entries(x).sort(([a],[b])=>a.localeCompare(b))):x);
vectors.forEach((v,i)=>{const js=javascript(v);if(canonical(js)!==canonical(sw[i]))differences.push({input:v,javascript:js,swift:sw[i]});});
const encodeDifferences=[];
const javascriptEncoderDifferences=[];
encodeVectors.forEach((v,i)=>{
 const swiftOut=encoded[i];
 const expected={status:'ok',type:v.type,id:v.id??-1,nsp:v.nsp,data:v.data===undefined?null:v.data};
 const reference=decode(referenceWire[i].header,referenceWire[i].binaries);
 if(canonical(reference)!==canonical(expected))throw new Error('Invalid JS encoder oracle vector '+i);
 if(canonical(decodedReference[i])!==canonical(reference))javascriptEncoderDifferences.push({input:v,javascript:reference,swift:decodedReference[i]});
 if(swiftOut.status!=='ok') {encodeDifferences.push({input:v,expected,swift:swiftOut});return;}
 const actual=decode(swiftOut.header, swiftOut.binaries||[]);
 if(canonical(actual)!==canonical(expected))encodeDifferences.push({input:v,wire:{header:swiftOut.header,attachments:(swiftOut.binaries||[]).length},expected,javascript:actual});
});
const result={upstream:'aaf2af36ec8ad05910f357a788e0e358bad32738',validCases:5000,otherCases:vectors.length-5000,encodeCases:encodeVectors.length,javascriptEncoderCases:referenceWire.length,javascriptEncoderDifferences,validDifferences:differences.filter(d=>d.input.class==='valid').length,encodeDifferences,differences};
fs.writeFileSync(process.env.PARITY_OUTPUT || 'decoder-differential-results.json',JSON.stringify(result,null,2));
console.log(JSON.stringify({validCases:5000,otherCases:vectors.length-5000,encodeCases:encodeVectors.length,javascriptEncoderCases:referenceWire.length,javascriptEncoderDifferences:javascriptEncoderDifferences.length,validDifferences:result.validDifferences,encodeDifferences:encodeDifferences.length,differences:differences.filter(d=>d.input.class!=='valid')},null,2));
if(result.validDifferences || javascriptEncoderDifferences.length) process.exitCode = 1;
// The encoder direction has no accepted divergences: any difference fails.
if(encodeDifferences.length) {console.error(JSON.stringify(encodeDifferences.slice(0,5),null,2)); process.exitCode = 1;}
// Malformed inputs are reported, not silently represented as matching upstream behavior.
const expected = require(require('path').join(__dirname, '../../Documentation/ReviewEvidence/DecoderDifferential.json')).differences;
if(canonical(differences) !== canonical(expected)) throw new Error('Malformed-input behavior changed; review the recorded contract');
