/* Host-only failure/lifecycle regression harness, not a platform audio emulator. */
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#define MIN(a,b) ((a)<(b)?(a):(b))
#define MAX(a,b) ((a)>(b)?(a):(b))
#define g_malloc0(n) calloc(1,n)
#define g_free free
#define dolog(...) fprintf(stderr, __VA_ARGS__)
typedef int QemuMutex;
static void qemu_mutex_init(QemuMutex *m) { *m=1; }
static void qemu_mutex_destroy(QemuMutex *m) { assert(*m==1); *m=0; }
static void qemu_mutex_lock(QemuMutex *m) { assert(*m==1); }
static void qemu_mutex_unlock(QemuMutex *m) { assert(*m==1); }
typedef struct { int freq,nchannels,fmt,endianness; } audsettings;
#define AUDIO_FORMAT_S16 1
typedef struct { int bytes_per_frame; } Info;
typedef struct { Info info; size_t samples; } HWVoiceOut;
typedef HWVoiceOut HWVoiceIn;
static void audio_pcm_init_info(Info *i, audsettings *as) { i->bytes_per_frame=as->nchannels*2; }
static void audio_generic_run_buffer_out(HWVoiceOut *h) { (void)h; }
static void audio_generic_run_buffer_in(HWVoiceIn *h) { (void)h; }
static size_t audio_generic_buffer_get_free(HWVoiceOut *h) { return h->samples; }
typedef struct {int driver;} Audiodev;
typedef void Error;
#define AUDIODEV_DRIVER_AETHER_SOUNDKIT_HMOS 42
struct audio_pcm_ops {
 int (*init_out)(HWVoiceOut*,audsettings*,void*); void (*fini_out)(HWVoiceOut*);
 size_t (*write)(HWVoiceOut*,void*,size_t); size_t (*buffer_get_free)(HWVoiceOut*);
 void (*run_buffer_out)(HWVoiceOut*); void (*enable_out)(HWVoiceOut*,bool);
 int (*init_in)(HWVoiceIn*,audsettings*,void*); void (*fini_in)(HWVoiceIn*);
 size_t (*read)(HWVoiceIn*,void*,size_t); void (*run_buffer_in)(HWVoiceIn*); void (*enable_in)(HWVoiceIn*,bool);
};
struct audio_driver {
 const char *name; void *(*init)(Audiodev*,Error**); void (*fini)(void*);
 struct audio_pcm_ops *pcm_ops; int max_voices_out,max_voices_in; size_t voice_size_out,voice_size_in;
};
static struct audio_driver *registered;
static void audio_driver_register(struct audio_driver *d) { registered=d; }
#define type_init(fn) static void __attribute__((constructor)) register_fixture(void) { fn(); }
typedef int OH_AudioStream_Result;
typedef int OH_AudioStreamBuilder;
typedef int OH_AudioRenderer;
typedef int OH_AudioCapturer;
#define AUDIOSTREAM_SUCCESS 0
#define AUDIOSTREAM_TYPE_RENDERER 1
#define AUDIOSTREAM_TYPE_CAPTURER 2
#define AUDIOSTREAM_SAMPLE_S16LE 1
#define AUDIOSTREAM_ENCODING_TYPE_RAW 0
#define AUDIOSTREAM_LATENCY_MODE_NORMAL 0
#define AUDIOSTREAM_USAGE_MUSIC 1
#define AUDIOSTREAM_SOURCE_TYPE_MIC 0
typedef struct { int32_t (*OH_AudioRenderer_OnWriteData)(OH_AudioRenderer*,void*,void*,int32_t); } OH_AudioRenderer_Callbacks;
typedef struct { int32_t (*OH_AudioCapturer_OnReadData)(OH_AudioCapturer*,void*,void*,int32_t); } OH_AudioCapturer_Callbacks;
static int calls, fail_at, builders, streams;
static int result(void) { return ++calls==fail_at ? -17 : 0; }
static int OH_AudioStreamBuilder_Create(OH_AudioStreamBuilder **b,int t) { (void)t; int r=result(); if (!r) { *b=malloc(sizeof(int)); builders++; } return r; }
static int OH_AudioStreamBuilder_Destroy(OH_AudioStreamBuilder *b) { free(b); builders--; return 0; }
#define SETTER(name) static int OH_AudioStreamBuilder_##name(OH_AudioStreamBuilder *b,int v) { (void)b;(void)v;return result(); }
SETTER(SetSamplingRate) SETTER(SetChannelCount) SETTER(SetSampleFormat) SETTER(SetEncodingType)
SETTER(SetLatencyMode) SETTER(SetRendererInfo) SETTER(SetCapturerInfo)
#define STREAM(T) \
static int OH_AudioStreamBuilder_Set##T##Callback(OH_AudioStreamBuilder *b,OH_Audio##T##_Callbacks cb,void *v) { (void)b;(void)cb;(void)v;return result(); } \
static int OH_AudioStreamBuilder_Generate##T(OH_AudioStreamBuilder *b,OH_Audio##T **s) { (void)b;int r=result();if(!r){*s=malloc(sizeof(int));streams++;}return r;} \
static int OH_Audio##T##_Start(OH_Audio##T *s) {assert(s);return result();} \
static int OH_Audio##T##_Pause(OH_Audio##T *s) {assert(s);return result();} \
static int OH_Audio##T##_Stop(OH_Audio##T *s) {assert(s);return 0;} \
static int OH_Audio##T##_Release(OH_Audio##T *s) {free(s);streams--;return 0;}
STREAM(Renderer) STREAM(Capturer)
#include "backend.c"
int main(void) {
 assert(registered && !strcmp(registered->name,"aether-soundkit-hmos"));
 audsettings as={48000,2,AUDIO_FORMAT_S16,0};
 for (int fail=1;fail<=10;fail++) {
  AetherVoiceOut out={0}; AetherVoiceIn in={0};
  calls=0;fail_at=fail; assert(registered->pcm_ops->init_out(&out.hw,&as,NULL)==-1);
  assert(!builders && !streams && !out.rb.buf);
  calls=0;fail_at=fail; assert(registered->pcm_ops->init_in(&in.hw,&as,NULL)==-1);
  assert(!builders && !streams && !in.rb.buf);
 }
 fail_at=0; calls=0;
 AetherVoiceOut out={0}; AetherVoiceIn in={0};
 assert(!aether_init_out(&out.hw,&as,NULL)); assert(!aether_init_in(&in.hw,&as,NULL));
 unsigned char src[16], dst[16]; memset(src,7,sizeof(src));
 assert(aether_write(&out.hw,src,sizeof(src))==sizeof(src));
 aether_renderer_on_write(out.renderer,&out,dst,sizeof(dst)); assert(!memcmp(src,dst,sizeof(src)));
 aether_renderer_on_write(out.renderer,&out,dst,sizeof(dst)); for(int i=0;i<16;i++) assert(dst[i]==0);
 assert(aether_read(&in.hw,dst,sizeof(dst))==0);
 aether_capturer_on_read(in.capturer,&in,src,sizeof(src)); assert(aether_read(&in.hw,dst,sizeof(dst))==sizeof(dst)); assert(!memcmp(src,dst,sizeof(src)));
 fail_at=calls+1; aether_enable_in(&in.hw,true); assert(!in.enabled);
 aether_fini_in(&in.hw); aether_fini_out(&out.hw); assert(!builders && !streams);
 as.fmt=999; assert(aether_init_out(&out.hw,&as,NULL)==-1); assert(aether_init_in(&in.hw,&as,NULL)==-1);
 puts("OHAudio mock lifecycle/failure/PCM tests passed; no device test");
}
