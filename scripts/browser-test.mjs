// CI browser checks against real Swift processes started by browser_integration.py.
import assert from 'node:assert/strict';
import {chromium} from 'playwright';
import {mkdir} from 'node:fs/promises';
const browser=await chromium.launch({headless:true}),page=await browser.newPage({viewport:{width:1440,height:1050}}),errors=[];
page.on('pageerror',e=>errors.push(e.message));
try{
  await page.goto(process.env.PULSE_STUDIO_URL??'http://127.0.0.1:9090');
  await page.waitForFunction(()=>document.getElementById('connection').textContent==='ライブ観測中');
  assert.equal(await page.locator('#rate,#duration,#baseline-file').count(),0);
  assert.equal(await page.getByRole('button',{name:/テスト開始/}).count(),0);
  // Ordinary application traffic, no load-test report or run ID.
  await page.request.get('http://127.0.0.1:8080/work?delay=20&fanout=4',{headers:{'X-Pulse-Request-ID':'browser-observation'}});
  await page.waitForFunction(()=>document.getElementById('request-rows').textContent.includes('browser-observation'));
  await page.getByRole('button',{name:'一時停止',exact:true}).click();
  await page.getByRole('button',{name:'実測サンプル',exact:true}).click();
  await page.waitForFunction(()=>document.getElementById('source').textContent.includes('実測サンプル'));
  assert((await page.locator('#request-rows tr').count())>1);
  await page.locator('#file').setInputFiles('Studio/demo-trace.json');
  await page.waitForFunction(()=>document.getElementById('source').textContent.includes('インポート'));
  await page.locator('#search').fill('/work');assert((await page.locator('#request-rows tr').count())>0);
  await page.locator('#request-rows tr').first().click();assert((await page.locator('#trace-note').textContent()).includes('選択中'));
  await page.getByRole('button',{name:'リクエスト',exact:true}).click();
  await page.locator('#zoom').fill('5');await page.locator('#zoom').dispatchEvent('input');
  await page.getByRole('button',{name:'選択を解除',exact:true}).click();
  await page.getByRole('button',{name:'ワーカー',exact:true}).click();
  await page.locator('#zoom').fill('1');await page.locator('#zoom').dispatchEvent('input');
  const download=page.waitForEvent('download');await page.getByRole('button',{name:'JSONを保存',exact:true}).click();assert.equal((await download).suggestedFilename(),'swiftpulse-trace.json');
  await page.locator('#search').fill('does-not-exist');assert.equal(await page.locator('#request-rows tr').count(),0);
  await page.locator('#search').fill('');
  await mkdir('test-results',{recursive:true});await page.screenshot({path:'test-results/studio-desktop.png',fullPage:true});
  await page.setViewportSize({width:390,height:844});await page.waitForTimeout(150);
  assert(await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth));await page.screenshot({path:'test-results/studio-mobile.png',fullPage:true});
  await page.getByRole('button',{name:'ライブ観測',exact:true}).click();
  await page.waitForFunction(()=>document.getElementById('connection').textContent==='ライブ観測中');
  assert.deepEqual(errors,[]);console.log('PASS: ordinary traffic, live/pause, import/export, correlation, zoom/filter, mobile and desktop');
}finally{await browser.close();}
