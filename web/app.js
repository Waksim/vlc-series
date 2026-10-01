'use strict';
const $ = id => document.getElementById(id);
const pictures = {dragon:'🐉',moon:'🌙',popcorn:'🍿',cat:'🐈',sofa:'🛋️',crown:'👑'};
const storage = {get(){try{return localStorage.getItem('sofa-session')||''}catch{return ''}},set(v){try{v?localStorage.setItem('sofa-session',v):localStorage.removeItem('sofa-session')}catch{}}};
let token=storage.get(), pattern=[], loginBusy=false, state=null, online=false, changingVolume=false, changingSystemVolume=false, systemDragDevice=null;
let pollTimer,toastTimer,queue=Promise.resolve(),pending=0,revision=0,failures=0;
let libraryData=null,libraryLoading=false,libraryUpdated=0,selectedSeason=null,selectedSeries=null,libraryRequest=0,view='player';
const time = n => {n=Math.max(0,Math.floor(n||0));return n>=3600?`${Math.floor(n/3600)}:${String(Math.floor(n/60)%60).padStart(2,'0')}:${String(n%60).padStart(2,'0')}`:`${Math.floor(n/60)}:${String(n%60).padStart(2,'0')}`};
function fill(el){el.style.setProperty('--fill',`${100*(Number(el.value)-Number(el.min))/(Number(el.max)-Number(el.min)||1)}%`)}
function vibrate(ms=12){if(navigator.vibrate)navigator.vibrate(ms)}
function toast(text){$('toast').textContent=text;$('toast').hidden=false;clearTimeout(toastTimer);toastTimer=setTimeout(()=>$('toast').hidden=true,2200)}
async function request(data){
  const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),3500);
  try{
    const res=await fetch('/api',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({...data,token}),cache:'no-store',signal:controller.signal});
    const body=await res.json();
    if(!res.ok){const e=new Error(body.error||'network');e.code=res.status;e.seconds=body.seconds;throw e}
    return body;
  }finally{clearTimeout(timer)}
}
function gateMessage(text,error=false){$('gate-message').textContent=text;$('gate-message').classList.toggle('error',error)}
function slots(){[...$('pattern-slots').children].forEach((el,i)=>{el.textContent=pattern[i]?pictures[pattern[i]]:'·';el.classList.toggle('filled',!!pattern[i])})}
function resetPattern(){pattern=[];slots()}
function showGate(message){clearTimeout(pollTimer);$('gate').hidden=false;$('remote').hidden=true;resetPattern();gateMessage(message||'Нажми три картинки по порядку')}
function showRemote(){$('gate').hidden=true;$('remote').hidden=false}
function connected(value){online=value;$('connection').classList.toggle('offline',!value);$('connection').querySelector('span').textContent=value?'На связи с MacBook':'Ищем твой VLC';$('offline-note').hidden=value;updateDisabled()}
function updateDisabled(){
  for(const id of ['toggle','mute','quieter','louder','volume','unity-volume','fullscreen','next','skip-intro','auto-next'])$(id).disabled=!online;
  for(const id of ['system-quieter','system-louder','system-volume'])$(id).disabled=!online||!state?.systemAudio?.controllable;
  $('system-mute').disabled=!online||!state?.systemAudio?.muteControllable;
  for(const id of ['back','forward'])$(id).disabled=!online||!state?.hasMedia||state.length<=0;
  for(const id of ['audio','subtitles'])$(id).disabled=!online||$(id).dataset.empty==='true';
  for(const button of $('library-view').querySelectorAll('button[data-episode],#continue-episode'))button.disabled=!online;
}
function mediaName(name){
  if(!name)return {title:'Твой вечер начинается здесь',detail:'Выбери фильм в VLC',episode:''};
  const match=name.match(/S(\d{1,2})E(\d{1,2})/i);
  const title=name.replace(/\.(mkv|mp4|avi|mov|webm|m4v|mp3|flac)$/i,'').replace(/[._]+/g,' ');
  return {title,detail:match?`Сезон ${Number(match[1])} · Серия ${Number(match[2])}`:'Кино уже на большом экране',episode:match?`S${match[1].padStart(2,'0')} / E${match[2].padStart(2,'0')}`:''};
}
function options(id,values,selected){
  const el=$(id),key=JSON.stringify(values||[]);
  if(el.dataset.options!==key){el.replaceChildren();for(const item of values||[]){const opt=document.createElement('option');opt.value=item.id;opt.textContent=item.id===-1?'Выключены':item.name;el.append(opt)}el.dataset.empty=String(!values?.length);if(!values?.length){const opt=document.createElement('option');opt.textContent=id==='audio'?'Нет дорожек':'Нет субтитров';el.append(opt)}el.dataset.options=key}
  if(document.activeElement!==el)el.value=String(selected);
}
function volumeReadout(value){
  $('volume').value=Math.min(Number($('volume').max),value);fill($('volume'));
  $('volume-value').replaceChildren(document.createTextNode(String(value)),node('span','','%'));
  $('volume-value').classList.toggle('boosted',value>100);$('gain-label').classList.toggle('boosted',value>100);
  $('gain-label').textContent=value>100?'Усиление':value===100?'Без усиления':value===0?'Без звука':'Тише исходного';
  $('volume').setAttribute('aria-valuetext',`${value} процентов${value>100?', усиление':''}`);
}
function systemReadout(value){
  $('system-volume').value=value;fill($('system-volume'));
  $('system-volume-value').replaceChildren(document.createTextNode(String(value)),node('span','','%'));
}
function renderAudio(s){
  $('volume').max=s.volumeMax||200;
  if(!changingVolume)volumeReadout(s.volume);
  $('volume-icon').setAttribute('href',s.muted?'#i-mute':'#i-volume');
  $('mute').setAttribute('aria-label',s.muted?'Включить звук VLC':'Выключить звук VLC');
  if(s.muted&&!changingVolume)$('gain-label').textContent='Звук VLC выключен';
  const audio=s.systemAudio;
  $('system-volume-section').hidden=!audio?.controllable;
  $('audio-device').textContent=audio?.available?`${audio.name}${['HDMI','DisplayPort'].includes(audio.transport)?' · '+audio.transport:''}`:'';
  if(audio?.controllable){
    if(!changingSystemVolume)systemReadout(audio.volume);
    $('system-volume-icon').setAttribute('href',audio.muted?'#i-mute':'#i-volume');
    $('system-mute').setAttribute('aria-label',audio.muted?'Включить звук macOS':'Выключить звук macOS');
    $('audio-advice').textContent=audio.muted?'Звук macOS выключен.':s.volume>100&&audio.volume<100?'Можно уменьшить усиление VLC и поднять громкость macOS.':'Для обычной настройки оставь VLC на 100% и регулируй громкость macOS.';
  }else if(audio?.available){
    $('audio-advice').textContent=['HDMI','DisplayPort'].includes(audio.transport)?'По HDMI громкость macOS недоступна. Основную громкость регулируй на телевизоре; VLC лучше оставить на 100% или ниже.':'У этого выхода нет регулятора macOS. Используй громкость самого устройства и VLC.';
  }else $('audio-advice').textContent='Регулятор macOS сейчас недоступен. Громкость VLC работает отдельно.';
}
function render(s){
  state=s;connected(true);failures=0;const name=mediaName(s.title);
  $('skip-intro').checked=s.playback?.skipIntro!==false;$('auto-next').checked=s.playback?.nextEpisode!==false;
  $('markers-note').textContent=s.marked?'Разметка проверена. Сцены перед заставкой сохраняются.':'Для этой серии разметки пока нет — автопропуск ждёт её.';
  $('media-title').textContent=s.episodeId?s.libraryTitle:name.title;$('media-detail').textContent=name.detail;$('episode').textContent=name.episode;$('episode').hidden=!name.episode;
  const playing=s.state==='playing';$('play-state').textContent=playing?'Смотрим':s.hasMedia?'Пауза':'Ждём кино';
  $('toggle-icon').setAttribute('href',playing?'#i-pause':'#i-play');$('toggle').setAttribute('aria-label',playing?'Пауза':'Продолжить');
  $('transport-hint').textContent=playing?'Самое время откинуться на спинку':'Никуда не спешим';
  $('position').max=Math.max(1,s.length);$('position').value=Math.max(0,Math.min(s.length,s.time));
  $('position').setAttribute('aria-valuetext',`${time(s.time)} из ${time(s.length)}`);
  $('elapsed').textContent=time(s.time);$('remaining').textContent='−'+time(s.length-s.time);
  renderAudio(s);
  options('audio',s.audio,s.audioId);options('subtitles',s.subtitles,s.subtitleId);updateDisabled();
  if(libraryData&&view==='library')renderLibrary();
  if(!libraryData||(view==='library'&&Date.now()-libraryUpdated>4000))loadLibrary();
}
function expired(){token='';storage.set('');showGate('Пора снова выбрать три картинки')}
function failure(e){if(e.code===401){expired();return}connected(false)}
function schedule(){clearTimeout(pollTimer);if(token)pollTimer=setTimeout(poll,document.hidden?5000:(online?1000:2500))}
async function poll(){
  if(!token)return;
  if(pending){schedule();return}
  const rev=revision;
  try{const s=await request({action:'status'});if(rev===revision){showRemote();render(s)}}
  catch(e){failures++;if(e.code===401)expired();else if(failures>=2||!state){showRemote();failure(e)}}
  finally{schedule()}
}
function act(action,extra={},notice){
  if(!token||!online)return;
  vibrate();pending++;revision++;
  // Serialize taps so multiple five-second skips add up in order.
  const id=`${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
  queue=queue.then(async()=>{
    if(!online||!token)return;
    try{await request({action,...extra,requestId:id});if(notice)toast(notice)}
    catch(e){if(e.code===400)toast(({last_episode:'Это последняя доступная серия',episode_missing:'Файл серии больше не найден',device_changed:'Аудиовыход сменился. Повтори настройку громкости',system_volume_unavailable:'У этого выхода нет регулятора macOS',system_volume_failed:'macOS не применила громкость'})[e.message]||'Не получилось отправить команду');else{failure(e);toast('Не получилось отправить команду')}}
  }).finally(()=>{pending--;if(!pending){clearTimeout(pollTimer);pollTimer=setTimeout(poll,130)}});
}
function node(tag,className,text){const el=document.createElement(tag);if(className)el.className=className;if(text!==undefined)el.textContent=text;return el}
function episodeLabel(e){return `Сезон ${e.season} · Серия ${e.episode}`}
function switchView(next){
  view=next;$('player-view').hidden=next!=='player';$('library-view').hidden=next!=='library';
  for(const name of ['player','library']){const tab=$(`tab-${name}`);tab.classList.toggle('selected',name===next);name===next?tab.setAttribute('aria-current','page'):tab.removeAttribute('aria-current')}
  if(next==='library'){if(libraryData)renderLibrary();loadLibrary()}
}
async function loadLibrary(force=false){
  if(!token||!online||(libraryLoading&&!force))return;
  libraryLoading=true;const requestId=++libraryRequest;
  try{const data=await request({action:'library',seriesId:selectedSeries});if(requestId!==libraryRequest)return;libraryData=data;selectedSeries=data.seriesId;libraryUpdated=Date.now();$('library-count').textContent=data.series.reduce((n,s)=>n+s.count,0);renderLibrary()}
  catch(e){if(e.code===401)expired();else if(view==='library')toast('Не удалось загрузить серии. Пробуем ещё раз')}
  finally{if(requestId===libraryRequest)libraryLoading=false}
}
function openEpisode(id,fromStart=false){
  const e=libraryData?.episodes.find(e=>e.id===id);if(!e||!online)return;
  act('play_episode',{id,fromStart},episodeLabel(e));switchView('player');libraryUpdated=0;
}
function renderLibrary(){
  const data=libraryData;if(!data)return;
  const picker=$('series-select'),seriesKey=JSON.stringify(data.series);
  if(picker.dataset.series!==seriesKey){picker.replaceChildren(...data.series.map(s=>{const option=node('option','',`${s.title} · ${s.count}`);option.value=s.id;return option}));picker.dataset.series=seriesKey}
  picker.value=data.seriesId||'';picker.disabled=!online||!data.series.length;
  $('library-title').textContent=data.title;$('library-empty').hidden=!!data.episodes.length;
  const current=data.episodes.find(e=>e.id===state?.episodeId);
  if(!data.seasons.includes(selectedSeason))selectedSeason=current?.season||data.seasons[0];
  const resume=data.episodes.find(e=>e.id===data.continueId);
  $('continue-episode').hidden=!resume;
  if(resume){
    $('continue-title').textContent=episodeLabel(resume);
    $('continue-detail').textContent=resume.progress.complete?'Посмотрена · можно пересмотреть':`С места ${time(resume.progress.resume)}`;
    $('continue-episode').dataset.episode=resume.id;
  }
  const seasonsKey=data.seasons.join(',');
  if($('season-tabs').dataset.key!==seasonsKey){
    $('season-tabs').replaceChildren(...data.seasons.map(season=>{const b=node('button','season-tab',String(season));b.dataset.season=season;b.setAttribute('aria-label',`Сезон ${season}`);return b}));
    $('season-tabs').dataset.key=seasonsKey;
  }
  for(const button of $('season-tabs').children){const selected=Number(button.dataset.season)===selectedSeason;button.classList.toggle('selected',selected);button.setAttribute('aria-pressed',String(selected))}
  const episodes=data.episodes.filter(e=>e.season===selectedSeason),complete=episodes.filter(e=>e.progress.complete).length;
  const duration=episodes.reduce((n,e)=>n+(e.progress.contentDuration??e.progress.duration),0),watched=episodes.reduce((n,e)=>n+(e.progress.contentWatched??e.progress.watched),0);
  $('season-title').textContent=selectedSeason?`Сезон ${selectedSeason}`:'';$('season-count').textContent=episodes.length?`${complete} / ${episodes.length} просмотрено`:'';
  $('season-fill').style.width=`${duration?100*watched/duration:0}%`;
  $('season-summary').textContent=complete===episodes.length&&episodes.length?'Все доступные серии просмотрены':watched?`Просмотрено ${time(watched)} в этом сезоне`:'Новые истории ждут';
  const key=episodes.map(e=>e.id).join(',');
  if($('episode-list').dataset.key!==key){
    $('episode-list').replaceChildren(...episodes.map(e=>{
      const card=node('article','episode-card');card.dataset.id=e.id;
      const play=node('button','episode-play');play.dataset.episode=e.id;
      const top=node('span','episode-top'),title=node('strong','episode-name',`Серия ${e.episode}`),badge=node('span','episode-badge');
      top.append(title,badge);const info=node('span','episode-info'),bar=node('span','watched-bar');
      play.append(top,info,bar);
      const restart=node('button','restart-episode','С начала');restart.dataset.episode=e.id;restart.dataset.restart='true';restart.setAttribute('aria-label',`Серия ${e.episode} с начала`);
      card.append(play,restart);return card;
    }));$('episode-list').dataset.key=key;
  }
  for(const e of episodes){
    const card=$('episode-list').querySelector(`[data-id="${e.id}"]`),p=e.progress,active=e.id===state?.episodeId;
    card.classList.toggle('current',active);card.classList.toggle('complete',p.complete);
    const badge=card.querySelector('.episode-badge');badge.textContent=active?'На экране':p.complete?'✓ Просмотрена':'';
    const info=card.querySelector('.episode-info');
    const watched=p.contentWatched??p.watched,duration=p.contentDuration??p.duration;
    info.textContent=watched>0?`${time(watched)} из ${time(duration)} просмотрено`:`Не начата${duration?' · '+Math.round(duration/60)+' мин':''}`;
    const play=card.querySelector('.episode-play');play.setAttribute('aria-label',`${episodeLabel(e)}. ${info.textContent}. ${active?'Продолжить':p.resume&&!p.complete?'Смотреть с '+time(p.resume):'Смотреть'}`);
    const bar=card.querySelector('.watched-bar'),rangeKey=JSON.stringify([p.ranges,p.excluded,p.duration]);
    if(bar.dataset.ranges!==rangeKey){
      const segments=(ranges,cls)=>ranges.map(([a,b])=>{const segment=node('span',cls);segment.style.left=`${100*a/(p.duration||1)}%`;segment.style.width=`${100*(b-a)/(p.duration||1)}%`;return segment});
      bar.replaceChildren(...segments(p.ranges,''),...segments(p.excluded||[],'excluded'));bar.dataset.ranges=rangeKey;
    }
    card.querySelector('.restart-episode').hidden=p.resume<=0||p.complete;
  }
  updateDisabled();
}
$('series-select').onchange=e=>{selectedSeries=e.target.value;selectedSeason=null;libraryData=null;$('episode-list').replaceChildren();$('episode-list').dataset.key='';$('continue-episode').hidden=true;loadLibrary(true)};
$('tab-player').onclick=()=>switchView('player');$('tab-library').onclick=()=>switchView('library');
$('season-tabs').onclick=e=>{const button=e.target.closest('[data-season]');if(button){selectedSeason=Number(button.dataset.season);renderLibrary()}};
$('episode-list').onclick=e=>{const button=e.target.closest('button[data-episode]');if(button)openEpisode(button.dataset.episode,button.dataset.restart==='true')};
$('continue-episode').onclick=()=>openEpisode($('continue-episode').dataset.episode);
$('pattern-grid').addEventListener('click',async e=>{
  const button=e.target.closest('button[data-picture]');if(!button||loginBusy)return;
  vibrate();pattern.push(button.dataset.picture);slots();gateMessage('Нажми три картинки по порядку');
  if(pattern.length!==3)return;
  loginBusy=true;gateMessage('Открываем твой кинозал…');
  try{const result=await request({action:'login',pattern:pattern.join('-')});token=result.token;storage.set(token);showRemote();render(result.status);schedule()}
  catch(e){vibrate([30,50,30]);gateMessage(e.code===403?'Картинки не совпали. Попробуй ещё раз':e.code===429?`Небольшой антракт: ${e.seconds||30} секунд`:'Нет связи. Проверь VLC и домашний Wi-Fi',true);resetPattern()}
  finally{loginBusy=false}
});
$('clear-pattern').onclick=()=>{if(!loginBusy){resetPattern();gateMessage('Нажми три картинки по порядку')}};
$('toggle').onclick=()=>act('toggle');$('back').onclick=()=>act('seek',{delta:-5},'Назад на 5 секунд');$('forward').onclick=()=>act('seek',{delta:5},'Вперёд на 5 секунд');
$('mute').onclick=()=>act('mute');$('quieter').onclick=()=>act('volume_step',{delta:-5});$('louder').onclick=()=>act('volume_step',{delta:5});
$('unity-volume').onclick=()=>act('volume',{value:100},'VLC · 100%, без усиления');
function systemVolume(value,deviceId=state?.systemAudio?.deviceId){
  act('system_volume',{value:Math.max(0,Math.min(100,Math.round(value))),deviceId});
}
$('system-quieter').onclick=()=>act('system_volume_step',{delta:-5,deviceId:state.systemAudio.deviceId});
$('system-louder').onclick=()=>act('system_volume_step',{delta:5,deviceId:state.systemAudio.deviceId});
$('system-mute').onclick=()=>act('system_mute',{value:state.systemAudio.muted?0:1,deviceId:state.systemAudio.deviceId});
$('fullscreen').onclick=()=>act('fullscreen');$('next').onclick=()=>act('next');
$('audio').onchange=e=>act('audio',{value:Number(e.target.value)});$('subtitles').onchange=e=>act('subtitle',{value:Number(e.target.value)});
$('skip-intro').onchange=e=>act('playback_preferences',{key:'skipIntro',value:e.target.checked});
$('auto-next').onchange=e=>act('playback_preferences',{key:'nextEpisode',value:e.target.checked});
$('volume').oninput=e=>{changingVolume=true;volumeReadout(Number(e.target.value))};
$('volume').onchange=e=>{changingVolume=false;act('volume',{value:Number(e.target.value)})};$('volume').onpointercancel=()=>{changingVolume=false};
$('system-volume').oninput=e=>{if(!changingSystemVolume)systemDragDevice=state?.systemAudio?.deviceId;changingSystemVolume=true;systemReadout(Number(e.target.value))};
$('system-volume').onchange=e=>{changingSystemVolume=false;systemVolume(Number(e.target.value),systemDragDevice);systemDragDevice=null};
$('system-volume').onpointercancel=()=>{changingSystemVolume=false;systemDragDevice=null};
$('lock').onclick=async()=>{if(pending)return;try{await request({action:'logout'})}catch{}token='';storage.set('');showGate()};
document.addEventListener('visibilitychange',()=>{if(!document.hidden&&token){clearTimeout(pollTimer);poll()}});
window.addEventListener('online',()=>{if(token)poll()});
fill($('volume'));if(token){showRemote();connected(false);poll()}else showGate();
