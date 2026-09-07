export function validateReport(value) {
  if (!value || value.kind !== 'swiftpulse.run' || value.schemaVersion !== 1 || typeof value.id !== 'string' || !value.configuration || !value.summary || !Array.isArray(value.requests) || !Array.isArray(value.buckets)) throw new Error('SwiftPulse v1の実行結果JSONを指定してください。');
  for (const key of ['scheduled','started','completed','failed','droppedCapacity','droppedLate','achievedRPS','successRate','elapsed']) if (!Number.isFinite(value.summary[key]) || value.summary[key] < 0) throw new Error(`不正な集計値: ${key}`);
  for (const key of ['latency','scheduleToCompletion','schedulerLag']) for (const p of ['p50','p95','p99','max','mean']) if (!Number.isFinite(value.summary[key]?.[p])) throw new Error('不正なレイテンシ集計です。');
  if (value.requests.length > 1000000 || value.buckets.length > 10000) throw new Error('結果が大きすぎます。');
  for (const r of value.requests) if (typeof r.id !== 'string' || ![r.sequence,r.scheduledMS,r.startedMS,r.endedMS,r.latencyMS,r.lagMS,r.totalMS,r.status,r.bytes].every(Number.isFinite)) throw new Error('不正なリクエストデータです。');
  for (const b of value.buckets) if (![b.second,b.scheduled,b.started,b.completed,b.dropped,b.latencyMaxMS].every(Number.isFinite)) throw new Error('不正な時系列データです。');
  return value;
}
export function traceEvents(report, mode = 'workers', requestID = '') {
  const events = report?.serverTrace?.traceEvents;
  if (!Array.isArray(events)) return [];
  return events.filter(e => e.ph === 'X' && Number.isFinite(e.ts) && Number.isFinite(e.dur) && e.dur >= 0 && typeof e.tid === 'string' &&
    typeof e.args?.requestID === 'string' && e.args.requestID.startsWith(`${report.id}:`) && (!requestID || e.args.requestID === requestID) &&
    (mode === 'workers' ? e.cat === 'executor' : e.cat === 'handler' || e.cat === 'io'));
}
export function compareReports(current, baseline) {
  const percent = (a,b) => b === 0 ? null : (a-b)/b*100;
  return {p99: percent(current.summary.latency.p99, baseline.summary.latency.p99), rate: percent(current.summary.achievedRPS, baseline.summary.achievedRPS)};
}
export function parseHeaders(text) {
  const headers = {};
  for (const line of text.split('\n').filter(x => x.trim())) {
    const index = line.indexOf(':');
    if (index <= 0) throw new Error('ヘッダーは Name: value の形式で指定してください。');
    headers[line.slice(0,index).trim()] = line.slice(index+1).trim();
  }
  return headers;
}
export function visibleRange(events, zoom = 1, pan = 0) {
  if (!events.length) return {start:0,end:1};
  let min = Infinity, max = -Infinity;
  for (const e of events) { min = Math.min(min,e.ts); max = Math.max(max,e.ts+e.dur); }
  const span = Math.max(1,max-min), width = span / Math.max(1,zoom);
  const start = min + (span-width) * Math.min(1,Math.max(0,pan/100));
  return {start,end:start+width};
}
