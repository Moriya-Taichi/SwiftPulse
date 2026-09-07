export function validateTrace(value) {
  if (!value || value.kind !== 'swiftpulse.trace' || value.schemaVersion !== 1 || !Array.isArray(value.traceEvents) || value.traceEvents.length > 1000000 || !Number.isFinite(value.epochMS)) throw new Error('SwiftPulseのトレースJSONを指定してください。');
  for (const e of value.traceEvents) {
    if (e.ph !== 'X' || typeof e.name !== 'string' || typeof e.cat !== 'string' || typeof e.tid !== 'string' || !Number.isFinite(e.ts) || !Number.isFinite(e.dur) || e.ts < 0 || e.dur < 0 || !e.args || typeof e.args !== 'object' || Array.isArray(e.args) || Object.values(e.args).some(v => typeof v !== 'string')) throw new Error('不正な実行区間です。');
    if (e.sequence != null && (!Number.isSafeInteger(e.sequence) || e.sequence < 1)) throw new Error('不正なイベント番号です。');
  }
  for (const key of ['nextCursor','oldestCursor']) if (value[key] != null && (!Number.isSafeInteger(value[key]) || value[key] < 0)) throw new Error('不正なカーソルです。');
  if (value.sessionID != null && typeof value.sessionID !== 'string') throw new Error('不正なセッションです。');
  return value;
}
export function mergeTrace(previous, incoming, capacity = 20000) {
  validateTrace(incoming);
  const same = previous && incoming.sessionID && previous.sessionID === incoming.sessionID;
  let events = same ? previous.traceEvents : [];
  const cursor = same ? (previous.nextCursor ?? 0) : 0;
  const fresh = incoming.traceEvents.filter(e => e.sequence == null || e.sequence > cursor);
  const first = fresh[0]?.sequence;
  const skipped = same && first != null ? Math.max(0, first - cursor - 1) : 0;
  // Unsequenced legacy snapshots replace the current view rather than duplicating events.
  if (incoming.nextCursor == null) events = [];
  const trace = {...incoming, traceEvents:[...events, ...fresh].slice(-capacity)};
  return {trace, skipped, restarted:!!previous && !same};
}
export function percentile(values, q = .95) {
  if (!values.length) return 0;
  const sorted = values.slice().sort((a,b)=>a-b);
  return sorted[Math.max(0,Math.ceil(sorted.length*q)-1)];
}
export function requestRows(trace, search = '') {
  const jobs = new Map();
  for (const e of trace?.traceEvents ?? []) if (e.cat === 'executor' && e.args.requestID) {
    const list = jobs.get(e.args.requestID) ?? []; list.push(Number(e.args.queueUS) || 0); jobs.set(e.args.requestID,list);
  }
  const needle = search.toLowerCase();
  return (trace?.traceEvents ?? []).filter(e => e.cat === 'request' && e.args.requestID).map(e => ({id:e.args.requestID,path:e.args.path ?? '/',method:e.args.method ?? '',status:e.args.status ?? '—',start:e.ts,end:e.ts+e.dur,durationMS:e.dur/1000,queueMS:percentile(jobs.get(e.args.requestID) ?? [])/1000})).filter(r => `${r.path} ${r.id}`.toLowerCase().includes(needle)).sort((a,b)=>b.end-a.end);
}
export function maxOverlap(rows) {
  const edges=rows.filter(r=>r.end>r.start).flatMap(r=>[[r.start,1],[r.end,-1]]).sort((a,b)=>a[0]-b[0] || a[1]-b[1]);
  let current=0,peak=0;for(const [,delta] of edges){current+=delta;peak=Math.max(peak,current);}return peak;
}
export function traceEvents(trace, mode='workers', requestID='', ids=null) {
  return (trace?.traceEvents ?? []).filter(e => (!requestID || e.args.requestID===requestID) && (!ids || ids.has(e.args.requestID)) && (mode==='workers' ? e.cat==='executor' : ['request','handler','io'].includes(e.cat)&&e.args.requestID));
}
export function visibleRange(events, zoom=1, pan=100) {
  if(!events.length)return {start:0,end:1};
  let min=Infinity,max=-Infinity;for(const e of events){min=Math.min(min,e.ts);max=Math.max(max,e.ts+e.dur);}
  const span=Math.max(1,max-min),width=span/Math.max(1,zoom),start=min+(span-width)*Math.min(1,Math.max(0,pan/100));return {start,end:start+width};
}
