#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import <AudioToolbox/AudioHardwareService.h>
#include <assert.h>
#include <math.h>
static UInt32 currentDevice=82, defaultReads=0, changeAfter=0, writes=0, lastSelector=0;
static Float32 volumeValue=.42;static UInt32 muteValue=0;static BOOL hasVirtual=YES;
static Boolean fakeHas(AudioObjectID o,const AudioObjectPropertyAddress *a){
 if(o!=77)return false;
 if(a->mSelector==kAudioHardwareServiceDeviceProperty_VirtualMainVolume)return hasVirtual;
 return a->mSelector==kAudioDevicePropertyVolumeScalar||a->mSelector==kAudioDevicePropertyMute;
}
static OSStatus fakeSettable(AudioObjectID o,const AudioObjectPropertyAddress *a,Boolean *s){*s=fakeHas(o,a);return noErr;}
static OSStatus fakeGet(AudioObjectID o,const AudioObjectPropertyAddress *a,UInt32 q,const void *v,UInt32 *size,void *out){
 (void)q;(void)v;(void)size;
 if(o==kAudioObjectSystemObject&&a->mSelector==kAudioHardwarePropertyDefaultOutputDevice){defaultReads++;*(UInt32*)out=(changeAfter&&defaultReads>=changeAfter)?82:currentDevice;return noErr;}
 if(a->mSelector==kAudioDevicePropertyDeviceIsAlive){*(UInt32*)out=(o==77||o==82);return noErr;}
 if(a->mSelector==kAudioDevicePropertyTransportType){*(UInt32*)out=o==82?kAudioDeviceTransportTypeHDMI:kAudioDeviceTransportTypeBuiltIn;return noErr;}
 if(a->mSelector==kAudioObjectPropertyName){*(CFStringRef*)out=CFRetain(o==82?CFSTR("HDMI Display"):CFSTR("Mac Speakers"));return noErr;}
 if(!fakeHas(o,a))return kAudioHardwareUnknownPropertyError;
 if(a->mSelector==kAudioDevicePropertyMute)*(UInt32*)out=muteValue;else *(Float32*)out=volumeValue;
 return noErr;
}
static OSStatus fakeSet(AudioObjectID o,const AudioObjectPropertyAddress *a,UInt32 q,const void *v,UInt32 size,const void *value){
 (void)q;(void)v;(void)size;assert(o==77);writes++;lastSelector=a->mSelector;
 if(a->mSelector==kAudioDevicePropertyMute)muteValue=*(UInt32*)value;else volumeValue=*(Float32*)value;
 return noErr;
}
#define AudioObjectGetPropertyData fakeGet
#define AudioObjectSetPropertyData fakeSet
#define AudioObjectHasProperty fakeHas
#define AudioObjectIsPropertySettable fakeSettable
#define main helper_main
#include "../audio.m"
#undef main
static int run(const char *command,const char *route,const char *expected,const char *value){
 const char *args[]={"helper",command,route,expected,value};return helper_main(expected?5:3,args);
}
int main(void){@autoreleasepool{
 freopen("/dev/null","w",stdout);
 NSDictionary *s=status(82);assert(![s[@"controllable"] boolValue]);assert(s[@"volume"]==[NSNull null]);assert(writes==0);
 assert(run("volume","0","82","60")==1);assert(writes==0);
 currentDevice=77;s=status(77);assert([s[@"controllable"] boolValue]);assert([s[@"volume"] intValue]==42);assert(writes==0);
 assert(run("volume","0","82","60")==1);assert(writes==0);
 assert(run("volume","0","77","101")==1);assert(writes==0);
 assert(run("volume","0","77","nan")==1);assert(writes==0);
 assert(run("volume","0","77","12;echo")==1);assert(writes==0);
 assert(run("volume","0","77","55")==0);assert(writes==1&&fabs(volumeValue-.55)<.001);assert(lastSelector==kAudioHardwareServiceDeviceProperty_VirtualMainVolume);
 assert(run("mute","0","77","1")==0);assert(writes==2&&muteValue==1&&fabs(volumeValue-.55)<.001);
 assert(run("volume","0","77","25")==0);assert(writes==3&&muteValue==1&&fabs(volumeValue-.25)<.001);
 assert(run("mute","0","77","0")==0);assert(writes==4&&muteValue==0);
 hasVirtual=NO;assert(run("volume","0","77","35")==0);assert(writes==5&&lastSelector==kAudioDevicePropertyVolumeScalar);
 defaultReads=0;changeAfter=2;assert(run("volume","0","77","75")==1);assert(writes==5);
 alarm(0);fprintf(stderr,"PASS 13 CoreAudio mock cases; no real output properties written\n");
}}
