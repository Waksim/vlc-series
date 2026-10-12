local realVlc = vlc
local base = config and config.source or "."
local checks = 0
local function check(value,message) assert(value,message); checks=checks+1 end
local P = dofile(base .. '/progress.lua')
local Markers = dofile(base .. '/markers.lua')
local Library = dofile(base .. '/library.lua')
local engine = P.new()
local function sample(id,position,clock,state,generation)
    engine:observe({id=id,position=position,clock=clock,timestamp=clock+1000,duration=100,
        state=state or 'playing',generation=generation or id,rate=1})
end
for t=0,40 do sample('one:s01e01',t,t) end
for t=0,3 do sample('two:s01e01',t,41+t) end
check(engine.data.continueId=='one:s01e01','accidental visit must preserve Continue')
check(engine.data.episodes['one:s01e01'].resume==40,'series have independent bookmarks')
check(engine.data.episodes['two:s01e01'].resume==0,'short visit does not become bookmark')
sample('one:s01e01',40,45);sample('one:s01e01',41,46);sample('one:s01e01',80,47);sample('one:s01e01',81,48)
check(P.summary(engine.data.episodes['one:s01e01']).watched==42,'seeking never fills skipped story')
local marker={intro={start=10,skipTo=27,finish=30},credits={start=90,nextAt=92},excluded={{10,30},{90,100}}}
local sum=P.summary({ranges={{0,10},{30,90}},resume=89},100,marker.excluded)
check(sum.complete and sum.contentWatched==70,'titles do not count as unwatched story')
local player=Markers.new_player();local prefs={skipIntro=true,nextEpisode=true}
local s={id='one:s01e01',generation=1,state='playing',position=3}
check(not player:plan(s,marker,prefs,'one:s01e02'),'cold open preserved')
s.position=12;s.state='paused';check(not player:plan(s,marker,prefs,'one:s01e02'),'paused media not skipped')
s.state='playing';local action=player:plan(s,marker,prefs,'one:s01e02');check(action.position==27,'safe intro tail');player:applied(action)
check(not player:plan(s,marker,prefs,'one:s01e02'),'seeking back does not loop')
s.position=92;check(not player:plan(s,marker,prefs,nil),'last episode cannot advance')
action=player:plan(s,marker,prefs,'one:s01e02');check(action.kind=='next','credits advance');player:applied(action)
check(not player:plan(s,marker,prefs,'one:s01e02'),'advance issued once')
local entry={relative='Example.S01E01.mp4',size=10,mtime=20,duration=100}
local v={file=entry.relative,size=10,mtime=20,duration=100,verified=true,intro=marker.intro,credits=marker.credits}
check(Markers.validate(v,entry)~=nil,'exact metadata binding')
v.size=11;check(Markers.validate(v,entry)==nil,'replacement rejected');v.size=10
v.intro=nil;check(Markers.validate(v,entry).intro==nil,'episode can have no opening');v.credits=nil
check(#Markers.validate(v,entry).excluded==0,'episode can have no skippable segments')
local names={['/one']={'Show.S01E01.mp4','Show.S01E02.mp4'},['/two']={'Other.S01E01.mp4'},['/duplicate']={'One.S01E01.mkv','Other.S01E01.mp4'}}
vlc={io={readdir=function(path)return names[path] or {}end},net={stat=function(path)return {type=names[path] and 'dir' or 'file',size=10,modification_time=20}end}}
local lib=Library.scan({libraries={{id='one',title='One',root='/one'},{id='two',title='Two',root='/two'}}},{})
check(#lib.series==2 and #lib.episodes==3,'independent catalogs combined')
check(lib.byId['one:s01e01'] and lib.byId['two:s01e01'],'same episode numbers do not collide')
check(Library.next(lib,'one:s01e01').id=='one:s01e02','next stays in same series')
check(Library.next(lib,'one:s01e02')==nil,'next never jumps into another series')
check(Library.previous(lib,'one:s01e02').id=='one:s01e01','previous stays in the same series')
check(Library.previous(lib,'two:s01e01')==nil,'previous never jumps into another series')
check(#Library.scan({libraries={{id='dup',root='/duplicate',title='Duplicate'}}},{}).episodes==0,'ambiguous duplicate is not playable')
local old=Library.scan({libraryRoot='/one',libraryTitle='Legacy'},{});check(old.byId.s01e01 and not old.byId['legacy:s01e01'],'legacy progress keys preserved')
local season,episode=Library.parse('Серия 07.mp4',2);check(season==2 and episode==7,'Russian episode pattern')
season,episode=Library.parse('Show.S02.E03.mkv');check(season==2 and episode==3,'separator in S/E pattern')
local Navigation=dofile(base .. '/navigation.lua')
vlc.strings={make_uri=function(path)return 'file://'..path end}
local navigation=Navigation.new(Library,P)
local watched={episodes={['one:s01e01']={ranges={{0,100}},resume=72,duration=100}}}
local episode={id='one:s01e01',path='/one/Show.S01E01.mp4',filename='Show.S01E01.mp4',duration=100}
check(navigation.item(episode,watched,{},false,false).options[1]=='start-time=0','completed next episode starts from the beginning')
check(navigation.item(episode,watched,{},false,true).options[1]=='start-time=72','previous resumes even a completed episode')
check(navigation.item(episode,watched,{},true,true).options[1]=='start-time=0','explicit start over always wins')
vlc=realVlc
local result='PASS '..checks..' Lua assertions'
if config and config.result then local f=assert(io.open(config.result,'w'));f:write(result);f:close()end
print(result)
if realVlc then realVlc.misc.quit() end
