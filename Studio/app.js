import {validateReport, traceEvents, compareReports, parseHeaders, visibleRange} from './model.mjs';
const $ = id => document.getElementById(id);
let report = null, baseline = null, mode = 'workers', selected = '', online = false, activeID = null, traceHits = [];
const fmt = (value, digits = 1) => Number(value).toLocaleString('en-US', {maximumFractionDigits:digits});
function notice(message = '', error = false) { $('notice').hidden = !message; $('notice').textContent = message; $('notice').classList.toggle('error',error); }
async function api(path, options) { const r = await fetch(path, options); if (!r.ok) throw new Error(await r.text()); return r.headers.get('content-type')?.includes('application/json') ? r.json() : r.text(); }
function load(value, source = '') { report = validateReport(value); selected = ''; $('zoom').value = 1; $('pan').value = 0; $('search').value = ''; $('export').disabled = false; $('run-title').textContent = `${source ? source+' · ' : ''}${report.configuration.method} ${report.configuration.url} · ${new Date(report.startedAtEpochMS).toLocaleString()}`; render(); }
function renderMetrics(summary, config = {}) {
  $('metric-rate').textContent = fmt(summary.achievedRPS);
  $('rate-detail').textContent = `目標 ${fmt(config.rate ?? 0)} req/s · 開始 ${fmt(summary.started,0)}件`;
  $('metric-p99').textContent = `${fmt(summary.latency?.p99 ?? 0,2)} ms`;
  $('metric-success').textContent = `${fmt(summary.successRate*100,2)}%`;
  $('success-detail').textContent = `完了 ${fmt(summary.completed,0)}件 · 失敗 ${fmt(summary.failed,0)}件`;
  $('metric-dropped').textContent = fmt(summary.droppedCapacity+summary.droppedLate,0);
  $('drop-detail').textContent = `上限 ${fmt(summary.droppedCapacity,0)} / 遅延 ${fmt(summary.droppedLate,0)}`;
}
function render() {
  if (!report) return;
  renderMetrics(report.summary, report.configuration);
  const s = report.summary;
  $('timing-detail').textContent = `P50 ${fmt(s.latency.p50,2)} ms · P95 ${fmt(s.latency.p95,2)} ms · 予定時刻→完了 P99 ${fmt(s.scheduleToCompletion.p99,2)} ms · スケジューラ遅延 P99 ${fmt(s.schedulerLag.p99,2)} ms · 最大同時実行 ${s.peakInFlight} · 分位点は最大約2%の量子化誤差`;
  $('sample-note').textContent = `完了 ${fmt(s.completed,0)}件中、保存された ${fmt(report.requests.length,0)}件。表示は検索結果の先頭200件。`;
  if (baseline) {
    const delta = compareReports(report,baseline);
    $('p99-detail').textContent = delta.p99 === null ? '比較元 P99 = 0' : `比較元に対し ${delta.p99 >= 0 ? '+' : ''}${fmt(delta.p99)}%`;
  } else $('p99-detail').textContent = '発行開始 → 完了';
  const warnings = [];
  if (s.cancelled) warnings.push('この実行は途中で停止されました。');
  if (s.droppedCapacity+s.droppedLate) warnings.push('未発行の枠があります。表示レイテンシは発行できたリクエストの分布であり、未発行分を含みません。');
  if (report.traceError) warnings.push(`トレース取得失敗: ${report.traceError}`);
  if (baseline) warnings.push(`比較元: ${baseline.id.slice(0,8)}。条件が異なる実行の差分は性能改善の根拠にはなりません。`);
  notice(warnings.join(' '));
  renderRows(); drawRate(); drawTrace();
}
function renderRows() {
  const root = $('request-rows'); root.replaceChildren();
  if (!report) return;
  const query = $('search').value.toLowerCase();
  const rows = report.requests.filter(r => `${r.id} ${r.status} ${r.error??''}`.toLowerCase().includes(query)).slice(0,200);
  for (const r of rows) {
    const row = document.createElement('tr'); row.tabIndex = 0; row.classList.toggle('selected',selected === r.id);
    const values = [`#${r.sequence} · ${r.id.slice(0,8)}`,String(r.status),`${fmt(r.latencyMS,2)} ms`,`${fmt(r.lagMS,2)} ms`,`${fmt(r.totalMS,2)} ms`,fmt(r.bytes,0)];
    values.forEach((text,i) => { const cell = document.createElement('td'); if (i===1) { const code = document.createElement('span'); code.className = `code ${r.status<200 || r.status>=400 || r.error ? 'bad' : ''}`; code.textContent = text; cell.append(code); } else cell.textContent = text; row.append(cell); });
    const choose = () => { selected = r.id; $('selection').textContent = `${r.id} · ${r.error ?? '通信エラーなし'} · 予定 ${fmt(r.scheduledMS,2)} ms / 開始 ${fmt(r.startedMS,2)} ms / 完了 ${fmt(r.endedMS,2)} ms`; renderRows(); drawTrace(); };
    row.addEventListener('click',choose); row.addEventListener('keydown',e=>{if(e.key==='Enter')choose();}); root.append(row);
  }
  if (!rows.length) { const row=document.createElement('tr'),cell=document.createElement('td');cell.colSpan=6;cell.textContent='一致するリクエストがありません。';row.append(cell);root.append(row); }
}
function canvas(id,height) {
  const element=$(id),width=element.parentElement.clientWidth,dpr=window.devicePixelRatio||1;
  element.width=Math.max(1,width*dpr);element.height=height*dpr;element.style.height=`${height}px`;
  const ctx=element.getContext('2d');ctx.scale(dpr,dpr);ctx.font='10px ui-monospace,monospace';
  return {ctx,width,height};
}
function drawRate() {
  const {ctx,width,height}=canvas('rate-chart',235),left=48,right=60,top=15,bottom=34,w=width-left-right,h=height-top-bottom;
  ctx.clearRect(0,0,width,height);
  const buckets=report?.buckets??[],maxTime=Math.max(1,...buckets.map(b=>b.second+1));
  const maxRate=Math.max(1,...buckets.map(b=>Math.max(b.scheduled,b.started,b.completed)))*1.15;
  const maxLatency=Math.max(1,...buckets.map(b=>b.latencyMaxMS))*1.15;
  ctx.fillStyle='#8798af';ctx.strokeStyle='#243146';ctx.lineWidth=1;
  for(let i=0;i<=4;i++){const y=top+h*i/4;ctx.beginPath();ctx.moveTo(left,y);ctx.lineTo(width-right,y);ctx.stroke();ctx.fillText(fmt(maxRate*(1-i/4),0),8,y+3);ctx.fillText(`${fmt(maxLatency*(1-i/4),0)}ms`,width-right+10,y+3);}
  for(let i=0;i<=5;i++)ctx.fillText(`${fmt(maxTime*i/5)}s`,left+w*i/5-8,height-10);
  const map=new Map(buckets.map(b=>[b.second,b]));
  for(const [key,color,maximum] of [['scheduled','#73849c',maxRate],['started','#68e7b7',maxRate],['completed','#66b9fa',maxRate],['latencyMaxMS','#ffb477',maxLatency]]){
    ctx.strokeStyle=color;ctx.lineWidth=key==='scheduled'?1:2;ctx.setLineDash(key==='scheduled'?[4,4]:[]);ctx.beginPath();
    for(let second=0;second<maxTime;second++){const x=left+w*(second+0.5)/maxTime,y=top+h*(1-(map.get(second)?.[key]??0)/maximum);second?ctx.lineTo(x,y):ctx.moveTo(x,y);}
    ctx.stroke();ctx.setLineDash([]);
  }
}
function drawTrace() {
  const events=traceEvents(report,mode,selected),lanes=[...new Set(events.map(e=>e.tid))].sort().slice(0,32);
  $('trace-empty').hidden=events.length>0;$('trace-chart').hidden=!events.length;traceHits=[];
  const dropped=report?.serverTrace?.droppedEvents??0;
  $('trace-note').textContent=`${events.length.toLocaleString()}区間 · 最大32レーンを表示 · 記録上限による欠落 ${dropped.toLocaleString()}件。${mode==='workers'?'ジョブ区間はexecutor上の経過時間です。OSのCPU稼働率ではありません。':'Handlerと送信の区間には待機時間が含まれます。'}${selected?' · 選択中のリクエストで絞り込み':''}`;
  if(!events.length)return;
  const {ctx,width,height}=canvas('trace-chart',Math.max(120,lanes.length*33+45));
  const left=mode==='workers'?105:125,right=22,w=width-left-right;
  const range=visibleRange(events,Number($('zoom').value),Number($('pan').value)),duration=range.end-range.start;
  ctx.fillStyle='#8798af';ctx.strokeStyle='#243146';
  for(let i=0;i<=5;i++){const x=left+w*i/5;ctx.fillText(`${fmt((range.start+duration*i/5)/1000,2)}ms`,x-15,16);ctx.beginPath();ctx.moveTo(x,26);ctx.lineTo(x,height);ctx.stroke();}
  lanes.forEach((lane,i)=>ctx.fillText(lane.startsWith('request:')?`#${lane.split(':').at(-1)}`:lane,15,47+i*33));
  ctx.save();ctx.beginPath();ctx.rect(left,26,w,height-26);ctx.clip();
  for(const e of events){const index=lanes.indexOf(e.tid);if(index<0||e.ts+e.dur<range.start||e.ts>range.end)continue;
    const x=left+w*(e.ts-range.start)/duration,y=33+index*33,barWidth=Math.max(1,w*e.dur/duration);
    const colors=['#68e7b7','#66b9fa','#b8a3ff','#ffb477'];const sequence=Number(e.args.requestID.split(':').at(-1))||0;
    ctx.fillStyle=e.cat==='io'?'#ffb477':colors[sequence%4];ctx.globalAlpha=.85;ctx.fillRect(x,y,barWidth,19);ctx.globalAlpha=1;
    traceHits.push({x:Math.max(left,x),y,w:Math.min(x+barWidth,width-right)-Math.max(left,x),h:19,event:e});
  }ctx.restore();
}
$('trace-chart').addEventListener('click',e=>{const rect=e.currentTarget.getBoundingClientRect(),x=e.clientX-rect.left,y=e.clientY-rect.top;const hit=traceHits.find(h=>x>=h.x&&x<=h.x+h.w&&y>=h.y&&y<=h.y+h.h);if(hit){const item=hit.event;$('selection').textContent=`${item.name} · ${item.args.requestID} · ${fmt(item.dur/1000,3)} ms · キュー待ち ${fmt(Number(item.args.queueUS??0)/1000,3)} ms · OS thread ${item.args.osThreadID??'—'}`;}});
async function refreshHistory(){const runs=await api('/api/runs');const list=$('history');list.replaceChildren();for(const run of runs){const button=document.createElement('button');button.classList.toggle('active',report?.id===run.id);button.textContent=`${new Date(run.startedAtEpochMS).toLocaleTimeString()} · ${fmt(run.summary.achievedRPS)} req/s`;const small=document.createElement('small');small.textContent=`P99 ${fmt(run.summary.latency.p99,2)} ms · ${run.id.slice(0,8)}`;button.append(small);button.onclick=async()=>{try{load(await api(`/api/runs/${encodeURIComponent(run.id)}`));await refreshHistory();}catch(e){notice(e.message,true);}};list.append(button);}return runs;}
async function poll(){try{const state=await api('/api/status');online=true;$('connection').textContent=state.activeID?'実行中':'ローカル接続';$('connection').classList.add('live');$('start').disabled=!!state.activeID;$('stop').disabled=!state.activeID;
  if(state.activeID&&state.summary){renderMetrics(state.summary,{rate:Number($('rate').value)});notice(`負荷テスト実行中 · ${fmt(state.summary.elapsed)}秒 · 完了 ${state.summary.completed}件`);}
  if(activeID&&!state.activeID){const runs=await refreshHistory();const result=runs.find(r=>r.id===activeID);if(result)load(await api(`/api/runs/${encodeURIComponent(result.id)}`));if(state.error)notice(state.error,true);}
  activeID=state.activeID;
}catch{online=false;$('connection').textContent='ファイル閲覧モード';$('connection').classList.remove('live');$('start').disabled=true;$('stop').disabled=true;}}
$('attack-form').addEventListener('submit',async e=>{e.preventDefault();try{if(!online)throw new Error('pulse studio を起動して接続してください。');const config={url:$('target').value,method:$('method').value,headers:parseHeaders($('headers').value),rate:Number($('rate').value),duration:Number($('duration').value),concurrency:Number($('concurrency').value),timeout:Number($('timeout').value),maxLagMS:Number($('max-lag').value),maxSamples:20000,maxResponseBytes:16777216,traceURL:$('trace-url').value||null};$('start').disabled=true;const result=await api('/api/attack',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(config)});activeID=result.id;notice('テストを開始しました。');await poll();}catch(error){notice(error.message,true);$('start').disabled=!online;}});
$('stop').onclick=async()=>{try{await api('/api/stop',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'});notice('停止処理中です。完了した結果は保存されます。');}catch(e){notice(e.message,true);}};
async function fileReport(file){if(!file)return null;if(file.size>64*1024*1024)throw new Error('64 MiB以下のJSONを指定してください。');return validateReport(JSON.parse(await file.text()));}
$('import').onclick=()=>$('file').click();$('compare').onclick=()=>$('baseline-file').click();
$('file').onchange=async e=>{try{const value=await fileReport(e.target.files[0]);if(value)load(value,'インポート');}catch(error){notice(error.message,true);}finally{e.target.value='';}};
$('baseline-file').onchange=async e=>{try{baseline=await fileReport(e.target.files[0]);if(report)render();else if(baseline){load(baseline,'比較元');baseline=null;}}catch(error){notice(error.message,true);}finally{e.target.value='';}};
$('demo').onclick=async()=>{try{load(await api('demo-run.json'),'ローカル実測サンプル');}catch(e){notice(e.message,true);}};
$('export').onclick=()=>{if(!report)return;const url=URL.createObjectURL(new Blob([JSON.stringify(report)],{type:'application/json'})),link=document.createElement('a');link.href=url;link.download=`pulse-${report.id}.json`;link.click();setTimeout(()=>URL.revokeObjectURL(url),1000);};
$('workers').onclick=()=>{mode='workers';$('workers').classList.add('selected');$('requests').classList.remove('selected');drawTrace();};
$('requests').onclick=()=>{mode='requests';$('requests').classList.add('selected');$('workers').classList.remove('selected');drawTrace();};
$('clear-filter').onclick=()=>{selected='';renderRows();drawTrace();};$('zoom').oninput=drawTrace;$('pan').oninput=drawTrace;$('search').oninput=renderRows;
$('refresh').onclick=()=>refreshHistory().catch(e=>notice(e.message,true));
let resizing;new ResizeObserver(()=>{clearTimeout(resizing);resizing=setTimeout(()=>{drawRate();drawTrace();},60);}).observe(document.querySelector('main'));
await poll();if(online)await refreshHistory().catch(()=>{});setInterval(poll,750);
