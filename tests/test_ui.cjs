const {chromium}=require('playwright');
const fs=require('fs'),http=require('http'),path=require('path'),assert=require('assert');
const root=path.resolve(__dirname,'../web');
const server=http.createServer((req,res)=>{
 const file=({'/':'index.html','/app.js':'app.js','/style.css':'style.css','/icon.svg':'icon.svg','/manifest.webmanifest':'manifest.webmanifest'})[req.url];
 if(!file){res.writeHead(404);res.end();return}
 res.setHeader('Content-Type',file.endsWith('.js')?'text/javascript':file.endsWith('.css')?'text/css':file.endsWith('.svg')?'image/svg+xml':file.endsWith('.html')?'text/html':'application/json');res.end(fs.readFileSync(path.join(root,file)));
});
const series=[{id:'one',title:'Северный маршрут',count:2},{id:'two',title:'Другой сериал',count:1}];
const bookmarks={one:{id:'one:s01e02',time:1200},two:{id:'two:s01e01',time:1200}};
function library(id){
 const show=series.find(s=>s.id===id)||series[0];
 return {title:show.title,series,seriesId:show.id,seasons:[1],continueId:bookmarks[show.id].id,episodes:Array.from({length:show.count},(_,i)=>({id:`${show.id}:s01e0${i+1}`,seriesId:show.id,season:1,episode:i+1,progress:{duration:3600,contentDuration:3300,watched:1200,contentWatched:1080,resume:bookmarks[show.id].time,complete:false,ranges:[[0,1200]],excluded:[[0,120],[3420,3600]]}}))};
}
(async()=>{
 await new Promise(r=>server.listen(0,'127.0.0.1',r));let browser;
 try{
  browser=await chromium.launch({headless:true,...(process.env.SOFA_CHROME?{channel:'chrome'}:{})});
  const page=await browser.newPage({viewport:{width:390,height:760},isMobile:true,hasTouch:true});
  const errors=[],commands=[];let offline=false;page.on('pageerror',e=>errors.push(String(e)));
  const state={state:'playing',title:'Example.S01E01.mp4',time:1200,length:3600,volume:100,volumeMax:200,muted:false,hasMedia:true,episodeId:'one:s01e01',seriesId:'one',libraryTitle:series[0].title,audio:[],subtitles:[],playback:{skipIntro:true,nextEpisode:true},marked:true,systemAudio:{available:true,name:'Телевизор',transport:'HDMI',controllable:false}};
  await page.addInitScript(()=>localStorage.setItem('sofa-session','test'));
  await page.route('**/api',async route=>{
   if(offline){await route.abort();return}
   const data=route.request().postDataJSON();let body=state;
   if(data.action==='library'){
    body=library(data.seriesId);if(data.seriesId==='two')await new Promise(r=>setTimeout(r,200));
   }else if(data.action!=='status'){
    commands.push(data);
    if(data.action==='seek')state.time+=data.delta;
    if(data.action==='play_episode'){state.episodeId=data.id;state.seriesId=data.id.split(':')[0];state.libraryTitle=series.find(s=>s.id===state.seriesId).title}
    if(data.action==='volume')state.volume=data.value;
   }
   await route.fulfill({json:body});
  });
  await page.goto(`http://127.0.0.1:${server.address().port}`);await page.locator('#remote').waitFor({state:'visible'});
  await page.locator('#resume-playback').waitFor({state:'visible'});
  assert.equal(await page.locator('#resume-title').textContent(),'Северный маршрут · Сезон 1 · Серия 2');
  assert.equal(await page.locator('#resume-detail').textContent(),'С места 20:00');
  for(const width of [320,360,390,470]){await page.setViewportSize({width,height:760});assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth))}
  await page.setViewportSize({width:390,height:760});
  const box=await page.locator('#position').boundingBox();await page.touchscreen.tap(box.x+box.width*.9,box.y+2);
  await page.locator('#position').evaluate(e=>e.dispatchEvent(new Event('change',{bubbles:true})));
  assert.equal(commands.length,0);assert.equal(await page.locator('#position').evaluate(e=>e.tagName),'PROGRESS');
  const resumed=page.waitForResponse(response=>response.url().endsWith('/api')&&response.request().postDataJSON().action==='play_episode');
  await page.locator('#resume-playback').click();await resumed;assert.equal(commands.length,1);
  assert.equal(commands[0].action,'play_episode');assert.equal(commands[0].id,'one:s01e02');assert.equal(commands[0].fromStart,false);
  commands.length=0;
  bookmarks.one.time=1500;
  await page.waitForFunction(()=>document.querySelector('#resume-detail').textContent==='С места 25:00',null,{timeout:10000});
  await page.locator('#tab-library').click();await page.locator('#series-select option').first().waitFor({state:'attached'});
  assert.equal(await page.locator('#episode-list .episode-card').count(),2);
  await page.locator('#series-select').selectOption('two');await page.locator('#series-select').selectOption('one');
  await page.waitForTimeout(400);assert.equal(await page.locator('#library-title').textContent(),series[0].title);
  assert.equal(await page.locator('#resume-playback').getAttribute('data-episode'),'one:s01e02');
  await page.locator('#series-select').selectOption('two');await page.waitForFunction(()=>document.querySelector('#library-title').textContent==='Другой сериал');
  assert.equal(await page.locator('#episode-list .episode-card').count(),1);assert.equal(commands.length,0,'browsing series never starts playback');
  await page.locator('#continue-episode').click();await page.waitForFunction(()=>document.querySelector('#media-title').textContent==='Другой сериал');
  assert.equal(commands.at(-1).id,'two:s01e01');
  state.volume=175;await page.waitForFunction(()=>document.querySelector('#volume-value').textContent==='175%');
  assert.equal(await page.locator('#volume').inputValue(),'175');assert.equal(await page.locator('#system-volume-section').isVisible(),false);
  await page.locator('#unity-volume').click();await page.waitForFunction(()=>document.querySelector('#volume-value').textContent==='100%');
  state.systemAudio={available:true,name:'Динамики MacBook',controllable:true,deviceId:10,volume:55,muteControllable:true,muted:false};
  await page.locator('#system-volume-section').waitFor({state:'visible'});assert.equal(await page.locator('#system-volume').inputValue(),'55');
  state.libraryTitle=series[0].title;state.seriesId='one';state.episodeId='one:s01e01';state.systemAudio={available:true,name:'Телевизор',transport:'HDMI',controllable:false};
  await page.waitForFunction(()=>document.querySelector('#media-title').textContent==='Северный маршрут');
  if(process.env.SOFA_SCREENSHOT){await page.locator('#toast').waitFor({state:'hidden'});await page.screenshot({path:process.env.SOFA_SCREENSHOT,fullPage:true});await page.locator('#tab-library').click();await page.locator('#series-select').selectOption('one');await page.waitForFunction(()=>document.querySelector('#library-title').textContent==='Северный маршрут');await page.screenshot({path:path.join(path.dirname(process.env.SOFA_SCREENSHOT),'library.png'),fullPage:true})}
  await page.locator('#tab-player').click();
  offline=true;await page.evaluate(()=>window.dispatchEvent(new Event('online')));
  await page.waitForFunction(()=>document.querySelector('#resume-playback').disabled,null,{timeout:10000});
  offline=false;await page.evaluate(()=>window.dispatchEvent(new Event('online')));
  await page.waitForFunction(()=>!document.querySelector('#resume-playback').disabled);
  bookmarks.one.id=undefined;bookmarks.two.id=undefined;
  await page.waitForFunction(()=>document.querySelector('#resume-playback').hidden,null,{timeout:10000});
  assert.equal(await page.locator('#continue-episode').getAttribute('data-episode'),null);
  assert.equal(errors.length,0,errors.join('\n'));
  console.log('PASS mobile layout, saved-episode Continue on player, live bookmark refresh, offline/empty history, read-only timeline, independent series/Continue, stale catalog responses, volume 175/200%, conditional system slider; no JS errors');
 }finally{if(browser)await browser.close();await new Promise(r=>server.close(r))}
})().catch(e=>{console.error(e);process.exitCode=1});
