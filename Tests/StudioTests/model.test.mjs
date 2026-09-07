import test from 'node:test';
import assert from 'node:assert/strict';
import {traceEvents,visibleRange,parseHeaders,validateReport,compareReports} from '../../Studio/model.mjs';

test('separates executor slices from request wall-time spans and other runs',()=>{
  const report={id:'run',serverTrace:{traceEvents:[
    {name:'job',ph:'X',cat:'executor',ts:100,dur:20,tid:'worker-0',args:{requestID:'run:1'}},
    {name:'handler',ph:'X',cat:'handler',ts:100,dur:200,tid:'request:run:1',args:{requestID:'run:1'}},
    {name:'job',ph:'X',cat:'executor',ts:100,dur:20,tid:'worker-0',args:{requestID:'other:1'}},
    {name:'invalid',ph:'X',cat:'executor',ts:NaN,dur:20,tid:'worker-0',args:{requestID:'run:1'}}
  ]}};
  assert.equal(traceEvents(report,'workers').length,1);
  assert.equal(traceEvents(report,'requests')[0].dur,200);
  assert.equal(traceEvents(report,'workers','run:2').length,0);
});
test('zoom and pan use the actual trace bounds',()=>{
  assert.deepEqual(visibleRange([{ts:100,dur:400}],2,100),{start:300,end:500});
  assert.deepEqual(visibleRange([],2,100),{start:0,end:1});
});
test('preserves colons inside header values',()=>{
  assert.deepEqual(parseHeaders('Accept: text/plain\nX-URL: http://localhost:80/'),{'Accept':'text/plain','X-URL':'http://localhost:80/'});
  assert.throws(()=>parseHeaders('broken'));
});
test('rejects unrelated files',()=>assert.throws(()=>validateReport({traceEvents:[]})));
test('comparison does not invent percentages with zero baseline',()=>{
  const result=compareReports({summary:{latency:{p99:20},achievedRPS:100}},{summary:{latency:{p99:0},achievedRPS:50}});
  assert.equal(result.p99,null);assert.equal(result.rate,100);
});
