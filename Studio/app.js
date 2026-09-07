import {validateTrace,mergeTrace,requestRows,maxOverlap,percentile,traceEvents,visibleRange} from './model.mjs';
const $=id=>document.getElementById(id);
let trace=null,live=true,mode='workers',selected='',target='',generation=0,inFlight=false,hitboxes=[],skipped=0;
const ms=n=>`${n.toFixed(n<1?3:2)} ms`;
function notice(message,error=false){$('notice').hidden=!message;$('notice').textContent=message;$('notice').classList.toggle('error',error);}
function connection(text){$('connection').textContent=text;$('connection').classList.toggle('live',text==='ライブ観測中');}
async function json(url){const r=await fetch(url);if(!r.ok)throw new Error(await r.text());return r.json();}
function pause(){live=false;generation++;connection('一時停止');}
function draw(){
  const rows=requestRows(trace,$('search').value),ids=$('search').value?new Set(rows.map(r=>r.id)):null;
  const events=traceEvents(trace,mode,selected,ids),range=visibleRange(events,Number($('zoom').value),Number($('pan').value));
  const lanes=[...new Set(events.map(e=>e.tid))].sort().slice(0,mode==='workers'?256:60),canvas=$('timeline'),width=canvas.parentElement.clientWidth,height=Math.max(200,lanes.length*34+56),dpr=window.devicePixelRatio||1;
  canvas.width=width*dpr;canvas.height=height*dpr;canvas.style.height=`${height}px`;const c=canvas.getContext('2d');c.scale(dpr,dpr);c.font='10px ui-monospace,monospace';
  const left=width<600?88:132,right=16,w=Math.max(1,width-left-right),laneIndex=new Map(lanes.map((lane,i)=>[lane,i]));hitboxes=[];
  c.fillStyle='#91a0b8';
  for(let i=0;i<5;i++){const x=left+w*i/4;c.strokeStyle='#263043';c.beginPath();c.moveTo(x,25);c.lineTo(x,height-20);c.stroke();c.fillText(`${((range.end-range.start)*i/4/1000).toFixed(1)}ms`,Math.min(x,width-56),15);}
  for(const [i,lane] of lanes.entries()){c.fillStyle='#91a0b8';c.fillText(lane.length>15?`${lane.slice(0,12)}…`:lane,12,47+i*34);}
  c.save();c.beginPath();c.rect(left,25,w,height);c.clip();
  for(const e of events){const index=laneIndex.get(e.tid);if(index==null||e.ts+e.dur<range.start||e.ts>range.end)continue;
    const x=left+(e.ts-range.start)/(range.end-range.start)*w,end=left+(e.ts+e.dur-range.start)/(range.end-range.start)*w,y=34+index*34;
    c.fillStyle=e.cat==='executor'?'#68e7b7':e.cat==='request'?'#66b9fa':e.cat==='handler'?'#b8a3ff':'#ffb477';
    const h=e.cat==='request'?22:e.cat==='handler'?13:6;c.globalAlpha=mode==='requests'?.7:.85;c.fillRect(x,y,Math.max(1,end-x),h);
    hitboxes.push({x:Math.max(left,x),end:Math.min(left+w,Math.max(x+2,end)),y,h,event:e});
  }c.restore();c.globalAlpha=1;
  if(!events.length){c.fillStyle='#91a0b8';c.textAlign='center';c.fillText('表示できる実行区間がありません',width/2,110);}
  $('trace-note').textContent=selected?`選択中: ${selected} · ${events.length}区間`:`${events.length}区間 · ${lanes.length}レーン · 開始位置 ${(range.start/1000).toFixed(1)} ms（サーバー起動基準）`;
}
function render(){
  const rows=requestRows(trace),jobs=traceEvents(trace);
  $('metric-requests').textContent=trace?rows.length.toLocaleString():'—';$('metric-p95').textContent=rows.length?ms(percentile(rows.map(r=>r.durationMS))):'—';
  $('metric-queue').textContent=jobs.length?ms(percentile(jobs.map(e=>Number(e.args.queueUS)||0))/1000):'—';$('metric-overlap').textContent=trace?maxOverlap(rows):'—';
  const visible=requestRows(trace,$('search').value);$('row-count').textContent=`${visible.length}件`;$('empty').hidden=visible.length>0;
  const fragment=document.createDocumentFragment();
  for(const r of visible.slice(0,200)){const tr=document.createElement('tr');tr.tabIndex=0;tr.classList.toggle('selected',selected===r.id);tr.setAttribute('aria-label',`${r.path} ${r.id}`);
    for(const text of [`${r.method} ${r.path}`.trim(),r.id,r.status,ms(r.durationMS),ms(r.queueMS)]){const td=document.createElement('td');td.textContent=text;tr.append(td);}
    const select=()=>{selected=r.id;render();};tr.addEventListener('click',select);tr.addEventListener('keydown',e=>{if(e.key==='Enter'||e.key===' '){e.preventDefault();select();}});fragment.append(tr);
  }$('request-rows').replaceChildren(fragment);$('export').disabled=!trace;
  $('request-note').textContent=visible.length>200?'最新200件を表示しています。検索で絞り込めます。':'リクエストを選ぶと、ワーカー上の実行区間を関連付けて表示します。';
  $('retention').textContent=`保持 ${trace?.traceEvents.length??0}イベント / 20,000 · サーバーで上書き ${trace?.droppedEvents??0} · 取得間隔中の欠落 ${skipped}`;draw();
}
async function poll(){
  if(!live||inFlight)return;inFlight=true;const current=generation;
  try{
    const query=new URLSearchParams();if(trace?.sessionID&&trace.nextCursor!=null){query.set('session',trace.sessionID);query.set('after',trace.nextCursor);}
    const incoming=await json(`/api/trace?${query}`);if(current!==generation||!live)return;
    const merged=mergeTrace(trace,incoming);trace=merged.trace;skipped+=merged.skipped;if(merged.restarted)selected='';
    connection('ライブ観測中');$('source').textContent=target;notice(merged.skipped?'取得間隔中に記録が上書きされました。表示中のデータは直近の区間です。':'');render();
  }catch(e){if(current===generation){connection('接続エラー');notice(e.message,true);}}finally{inFlight=false;}
}
$('live').onclick=()=>{trace=null;selected='';skipped=0;generation++;live=true;connection('接続中');poll();};
$('pause').onclick=pause;
async function openTrace(value,label){pause();trace=mergeTrace(null,validateTrace(value)).trace;selected='';skipped=0;$('source').textContent=label;connection('ファイル表示');notice('');render();}
$('sample').onclick=async()=>{try{await openTrace(await json('/demo-trace.json'),'実測サンプル · ローカル開発サーバーの記録');}catch(e){notice(e.message,true);}};
$('import').onclick=()=>$('file').click();$('file').onchange=async()=>{try{const file=$('file').files[0];if(!file)return;if(file.size>64*1024*1024)throw new Error('64 MiB以下のJSONを指定してください。');await openTrace(JSON.parse(await file.text()),`インポート · ${file.name}`);}catch(e){notice(e.message,true);}finally{$('file').value='';}};
$('export').onclick=()=>{const url=URL.createObjectURL(new Blob([JSON.stringify(trace)],{type:'application/json'})),a=document.createElement('a');a.href=url;a.download='swiftpulse-trace.json';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);};
for(const name of ['workers','requests'])$(name).onclick=()=>{mode=name;for(const n of ['workers','requests'])$(n).classList.toggle('selected',n===name);draw();};
$('clear').onclick=()=>{selected='';render();};$('search').oninput=()=>{selected='';render();};$('zoom').oninput=draw;$('pan').oninput=draw;window.addEventListener('resize',draw);
$('timeline').onclick=e=>{const rect=$('timeline').getBoundingClientRect(),x=e.clientX-rect.left,y=e.clientY-rect.top,hit=hitboxes.findLast(h=>x>=h.x&&x<=h.end&&y>=h.y&&y<=h.y+h.h);if(hit){selected=hit.event.args.requestID??'';render();$('trace-note').textContent+=` · ${hit.event.name} · OS thread ${hit.event.args.osThreadID??'—'} · 待ち ${hit.event.args.queueUS??'—'} µs`;}};
json('/api/status').then(status=>{target=status.target;$('target').textContent=target;poll();}).catch(e=>notice(e.message,true));
setInterval(poll,1000);render();
