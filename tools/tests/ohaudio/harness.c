/* Host-only OHAudio failure/privacy regression harness; never accesses a device. */
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <pthread.h>
#define MIN(a,b) ((a)<(b)?(a):(b))
#define MAX(a,b) ((a)>(b)?(a):(b))
#define g_malloc0(n) calloc(1,n)
#define g_free free
#define dolog(...) fprintf(stderr, __VA_ARGS__)
#define qatomic_read(p) __atomic_load_n((p), __ATOMIC_SEQ_CST)
#define qatomic_set(p,v) __atomic_store_n((p), (v), __ATOMIC_SEQ_CST)
typedef pthread_mutex_t QemuMutex;
static void qemu_mutex_init(QemuMutex *m) { assert(!pthread_mutex_init(m, NULL)); }
static void qemu_mutex_destroy(QemuMutex *m) { assert(!pthread_mutex_destroy(m)); }
static void qemu_mutex_lock(QemuMutex *m) { assert(!pthread_mutex_lock(m)); }
static void qemu_mutex_unlock(QemuMutex *m) { assert(!pthread_mutex_unlock(m)); }
typedef struct { int freq,nchannels,fmt,endianness; } audsettings;
#define AUDIO_FORMAT_S16 1
typedef struct { int bytes_per_frame; } Info;
struct audio_pcm_ops;
typedef struct Audiodev Audiodev;
typedef struct { Audiodev *dev; } AudioBackend;
typedef struct { Info info; size_t samples; bool enabled; AudioBackend *s; struct audio_pcm_ops *pcm_ops; } HWVoiceOut;
typedef HWVoiceOut HWVoiceIn;
static void audio_pcm_init_info(Info *i, audsettings *as) { i->bytes_per_frame=as->nchannels*2; }
static void audio_generic_run_buffer_out(HWVoiceOut *h) { (void)h; }
static void audio_generic_run_buffer_in(HWVoiceIn *h) { (void)h; }
static size_t audio_generic_buffer_get_free(HWVoiceOut *h) { return h->samples; }
typedef struct { bool mixing_engine; } AudiodevPerDirectionOptions;
struct Audiodev { int driver; AudiodevPerDirectionOptions in; };
static AudiodevPerDirectionOptions *audio_get_pdo_in(Audiodev *dev) { return &dev->in; }
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
typedef int OH_AudioInterrupt_ForceType;
typedef int OH_AudioInterrupt_Hint;
typedef int OH_AudioRenderer;
typedef struct OH_AudioCapturer OH_AudioCapturer;
#define AUDIOSTREAM_SUCCESS 0
#define AUDIOSTREAM_TYPE_RENDERER 1
#define AUDIOSTREAM_TYPE_CAPTURER 2
#define AUDIOSTREAM_SAMPLE_S16LE 1
#define AUDIOSTREAM_ENCODING_TYPE_RAW 0
#define AUDIOSTREAM_LATENCY_MODE_NORMAL 0
#define AUDIOSTREAM_USAGE_MUSIC 1
#define AUDIOSTREAM_SOURCE_TYPE_MIC 0
typedef struct { int32_t (*OH_AudioRenderer_OnWriteData)(OH_AudioRenderer*,void*,void*,int32_t); } OH_AudioRenderer_Callbacks;
typedef struct {
 int32_t (*OH_AudioCapturer_OnReadData)(OH_AudioCapturer*,void*,void*,int32_t);
 int32_t (*OH_AudioCapturer_OnInterruptEvent)(OH_AudioCapturer*,void*,OH_AudioInterrupt_ForceType,OH_AudioInterrupt_Hint);
 int32_t (*OH_AudioCapturer_OnError)(OH_AudioCapturer*,void*,OH_AudioStream_Result);
} OH_AudioCapturer_Callbacks;
struct OH_AudioCapturer { OH_AudioCapturer_Callbacks cb; void *user; };
typedef struct { OH_AudioCapturer_Callbacks cb; void *user; } OH_AudioStreamBuilder;
static int calls, fail_at, builders, streams, capture_starts;
static bool permission = true, revoke_on_generate, callback_on_start, callback_on_stop;
static bool revoke_on_stop;
/* 1 = interruption, 2 = error; both may arrive while Stop/Release completes. */
static int fault_on_stop, fault_on_release;
static bool OH_AT_CheckSelfPermission(const char *name) {
 assert(!strcmp(name,"ohos.permission.MICROPHONE")); return qatomic_read(&permission);
}
static int result(void) { return ++calls==fail_at ? -17 : 0; }
static int OH_AudioStreamBuilder_Create(OH_AudioStreamBuilder **b,int t) {
 (void)t; int r=result(); if (!r) { *b=calloc(1,sizeof(**b)); builders++; } return r;
}
static int OH_AudioStreamBuilder_Destroy(OH_AudioStreamBuilder *b) { free(b); builders--; return 0; }
#define SETTER(name) static int OH_AudioStreamBuilder_##name(OH_AudioStreamBuilder *b,int v) { (void)b;(void)v;return result(); }
SETTER(SetSamplingRate) SETTER(SetChannelCount) SETTER(SetSampleFormat) SETTER(SetEncodingType)
SETTER(SetLatencyMode) SETTER(SetRendererInfo) SETTER(SetCapturerInfo)
static int OH_AudioStreamBuilder_SetRendererCallback(OH_AudioStreamBuilder *b,OH_AudioRenderer_Callbacks cb,void *v) { (void)b;(void)cb;(void)v;return result(); }
static int OH_AudioStreamBuilder_GenerateRenderer(OH_AudioStreamBuilder *b,OH_AudioRenderer **s) { (void)b;int r=result();if(!r){*s=malloc(sizeof(**s));streams++;}return r; }
static int OH_AudioRenderer_Start(OH_AudioRenderer *s) {assert(s);return result();}
static int OH_AudioRenderer_Pause(OH_AudioRenderer *s) {assert(s);return result();}
static int OH_AudioRenderer_Stop(OH_AudioRenderer *s) {assert(s);return 0;}
static int OH_AudioRenderer_Release(OH_AudioRenderer *s) {free(s);streams--;return 0;}
static int OH_AudioStreamBuilder_SetCapturerCallback(OH_AudioStreamBuilder *b,OH_AudioCapturer_Callbacks cb,void *v) { b->cb=cb;b->user=v;return result(); }
static int OH_AudioStreamBuilder_GenerateCapturer(OH_AudioStreamBuilder *b,OH_AudioCapturer **s) {
 int r=result(); if (!r) { *s=malloc(sizeof(**s)); (*s)->cb=b->cb;(*s)->user=b->user;streams++; }
 if(revoke_on_generate) qatomic_set(&permission,false);
 return r;
}
static void callback_pcm(OH_AudioCapturer *s) {
 unsigned char pcm[16]; memset(pcm,7,sizeof(pcm));
 assert(s->cb.OH_AudioCapturer_OnReadData); s->cb.OH_AudioCapturer_OnReadData(s,s->user,pcm,sizeof(pcm));
}
static int OH_AudioCapturer_Start(OH_AudioCapturer *s) {
 assert(s); capture_starts++; int r=result(); if(!r && callback_on_start) callback_pcm(s); return r;
}
static void callback_fault(OH_AudioCapturer *s, int kind) {
 if(kind==1) {
  assert(s->cb.OH_AudioCapturer_OnInterruptEvent);
  s->cb.OH_AudioCapturer_OnInterruptEvent(s,s->user,0,1);
 } else if(kind==2) {
  assert(s->cb.OH_AudioCapturer_OnError);
  s->cb.OH_AudioCapturer_OnError(s,s->user,-17);
 }
}
static int OH_AudioCapturer_Stop(OH_AudioCapturer *s) {
 assert(s); if(revoke_on_stop) qatomic_set(&permission,false);
 if(callback_on_stop) callback_pcm(s);
 callback_fault(s,fault_on_stop); return 0;
}
static int OH_AudioCapturer_Release(OH_AudioCapturer *s) {
 callback_fault(s,fault_on_release);free(s);streams--;return 0;
}
#include "backend.c"
typedef struct { HWVoiceIn *hw; } SWVoiceIn;
#define SW_NAME(sw) "fixture"
static int mixed_reads;
static size_t audio_pcm_sw_read(SWVoiceIn *sw, void *buf, size_t size) {
 (void)sw; ++mixed_reads; memset(buf,0x5a,size); return size;
}
/* Unmodified public guest read dispatch, extracted from pinned QEMU sources. */
#include "aud_read.c"
static Audiodev capture_device={AUDIODEV_DRIVER_AETHER_SOUNDKIT_HMOS,{false}};
static AudioBackend capture_backend={&capture_device};
static size_t guest_read(AetherVoiceIn *in, void *buf, size_t size) {
 in->hw.enabled=true;in->hw.s=&capture_backend;in->hw.pcm_ops=&aether_pcm_ops;
 SWVoiceIn sw={&in->hw};return AUD_read(&sw,buf,size);
}

static void assert_erased(AetherVoiceIn *in) {
 assert(!in->rb.used); for(size_t i=0;i<in->rb.size;i++) assert(in->rb.buf[i]==0);
}
static void assert_playback(AetherVoiceOut *out) {
 unsigned char src[16], dst[16]; memset(src,9,sizeof(src));
 assert(out->renderer && out->enabled);
 assert(aether_write(&out->hw,src,sizeof(src))==sizeof(src));
 aether_renderer_on_write(out->renderer,out,dst,sizeof(dst)); assert(!memcmp(src,dst,sizeof(src)));
 aether_renderer_on_write(out->renderer,out,dst,sizeof(dst));
 for(size_t i=0;i<sizeof(dst);i++) assert(dst[i]==0);
}
static void assert_capture(AetherVoiceIn *in) {
 unsigned char dst[16]; assert(in->capturer && in->enabled);
 assert(qemu_hmos_get_microphone_status()==AETHER_MIC_CAPTURING);
 callback_pcm(in->capturer); assert(guest_read(in,dst,sizeof(dst))==sizeof(dst));
 for(size_t i=0;i<sizeof(dst);i++) assert(dst[i]==7);
}
static void assert_fault_survives_close(AetherVoiceIn *in, AetherVoiceOut *out, int fault) {
 unsigned char dst[16]; int starts=capture_starts;
 // Closing an already closed gate must preserve faults for explicit retry.
 for(int i=0;i<2;i++) {
  assert(qemu_hmos_set_microphone_enabled(false));
  assert(qemu_hmos_get_microphone_status()==fault);
  assert(!in->capturer && !in->enabled && streams==1);
  assert(guest_read(in,dst,sizeof(dst))==0);assert_erased(in);
 }
 aether_enable_in(&in->hw,false);aether_enable_in(&in->hw,true);
 assert(qemu_hmos_get_microphone_status()==fault);
 assert(guest_read(in,dst,sizeof(dst))==0 && capture_starts==starts);
 assert_erased(in);assert_playback(out);
}
static void *callback_worker(void *opaque) {
 AetherVoiceIn *in=opaque; unsigned char pcm[16]; memset(pcm,7,sizeof(pcm));
 for(int i=0;i<1000;i++) aether_capturer_on_read(NULL,in,pcm,sizeof(pcm));
 return NULL;
}
int main(void) {
 assert(registered && !strcmp(registered->name,"aether-soundkit-hmos"));
 audsettings as={48000,2,AUDIO_FORMAT_S16,0};
 for (int fail=1;fail<=9;fail++) {
  AetherVoiceOut out={0}; calls=0;fail_at=fail;
  assert(aether_init_out(&out.hw,&as,NULL)==-1);
  assert(!builders && !streams && !out.rb.buf);
 }
 fail_at=0;calls=0;
 AetherVoiceOut out={0}; AetherVoiceIn in={0}; unsigned char dst[16];
 assert(!aether_init_out(&out.hw,&as,NULL)); aether_enable_out(&out.hw,true);
 // Reject legacy/custom mixed input because its resampling queues bypass gating.
 Audiodev mixed_device={AUDIODEV_DRIVER_AETHER_SOUNDKIT_HMOS,{true}};
 assert(aether_init_in(&in.hw,&as,&mixed_device)==-1 && !in.rb.buf);
 assert(aether_init_in(&in.hw,&as,NULL)==-1 && !in.rb.buf);assert_playback(&out);
 // OS grant and guest activation alone must never even create a capturer.
 int before=calls;
 assert(!aether_init_in(&in.hw,&as,&capture_device)); aether_enable_in(&in.hw,true);
 assert(!in.capturer && !in.enabled && calls==before && capture_starts==0);
 assert(qemu_hmos_get_microphone_status()==AETHER_MIC_DISABLED);
 assert(guest_read(&in,dst,sizeof(dst))==0); assert_playback(&out);
 // Rejection leaves playback intact. Explicit retry starts already active guest.
 permission=false; assert(!qemu_hmos_set_microphone_enabled(true));
 assert(qemu_hmos_get_microphone_status()==AETHER_MIC_BLOCKED);
 assert(!in.capturer);assert_playback(&out);
 permission=true;callback_on_start=true;callback_on_stop=true;
 assert(qemu_hmos_set_microphone_enabled(true));assert_capture(&in);
 // Start/Stop callbacks must neither deadlock nor turn a local pause into denial.
 aether_enable_in(&in.hw,false);assert(!in.capturer);assert_erased(&in);
 assert(qemu_hmos_get_microphone_status()==AETHER_MIC_ARMED);
 aether_enable_in(&in.hw,true);assert_capture(&in);
 // Buffered PCM cannot leak after revoke, even before a JS permission poll.
 callback_pcm(in.capturer);permission=false;
 assert(guest_read(&in,dst,sizeof(dst))==0);assert_erased(&in);
 assert(!in.capturer && qemu_hmos_get_microphone_status()==AETHER_MIC_BLOCKED);
 permission=true; assert(guest_read(&in,dst,sizeof(dst))==0);
 assert(!in.capturer); assert(qemu_hmos_set_microphone_enabled(true));assert_capture(&in);
 // The platform callback also rejects revoked samples; status tears down safely.
 permission=false;callback_pcm(in.capturer);assert(!in.enabled);assert_erased(&in);
 assert(qemu_hmos_get_microphone_status()==AETHER_MIC_BLOCKED && !in.capturer);
 permission=true; assert(qemu_hmos_set_microphone_enabled(true));assert_capture(&in);
 // Errors and interruptions never auto resume merely because OS access persists.
 in.capturer->cb.OH_AudioCapturer_OnInterruptEvent(in.capturer,&in,0,1);
 assert_erased(&in);assert(qemu_hmos_get_microphone_status()==AETHER_MIC_BLOCKED);
 assert_fault_survives_close(&in,&out,AETHER_MIC_BLOCKED);
 aether_enable_in(&in.hw,false);aether_enable_in(&in.hw,true);assert(!in.capturer);
 assert(qemu_hmos_set_microphone_enabled(true));assert_capture(&in);
 in.capturer->cb.OH_AudioCapturer_OnError(in.capturer,&in,-17);
 assert_erased(&in);assert(qemu_hmos_get_microphone_status()==AETHER_MIC_ERROR);
 assert(!in.capturer);assert_playback(&out);
 assert_fault_survives_close(&in,&out,AETHER_MIC_ERROR);
 // Stop/Release may deliver an interruption/error after the gate has closed.
 for(int kind=1;kind<=2;kind++) {
  for(int during_release=0;during_release<=1;during_release++) {
   assert(qemu_hmos_set_microphone_enabled(true));assert_capture(&in);
   callback_pcm(in.capturer);
   fault_on_stop=during_release ? 0 : kind;
   fault_on_release=during_release ? kind : 0;
   assert_fault_survives_close(&in,&out,kind==1 ? AETHER_MIC_BLOCKED : AETHER_MIC_ERROR);
   fault_on_stop=fault_on_release=0;
   // Only a new affirmative control action may clear the latched fault.
   assert(qemu_hmos_set_microphone_enabled(true));assert_capture(&in);
  }
 }
 // A final PCM callback observes revoke even after false closed the gate.
 callback_pcm(in.capturer);revoke_on_stop=true;
 assert(qemu_hmos_set_microphone_enabled(false));revoke_on_stop=false;
 permission=true; // Restore before status: the teardown callback must latch it.
 assert_fault_survives_close(&in,&out,AETHER_MIC_BLOCKED);
 assert(qemu_hmos_set_microphone_enabled(true));assert_capture(&in);
 // False itself checks permission even with no capturer or callback remaining.
 assert(qemu_hmos_set_microphone_enabled(false));
 permission=false;assert(qemu_hmos_set_microphone_enabled(false));
 permission=true;assert_fault_survives_close(&in,&out,AETHER_MIC_BLOCKED);
 assert(qemu_hmos_set_microphone_enabled(true));assert_capture(&in);
 // A permission change while fully paused is still visible through status.
 assert(qemu_hmos_set_microphone_enabled(false));
 assert(qemu_hmos_get_microphone_status()==AETHER_MIC_DISABLED);
 permission=false;assert(qemu_hmos_get_microphone_status()==AETHER_MIC_BLOCKED);
 permission=true;assert_fault_survives_close(&in,&out,AETHER_MIC_BLOCKED);
 assert(qemu_hmos_set_microphone_enabled(true));assert_capture(&in);
 // Revoke between Generate and Start must prevent Start entirely.
 assert(qemu_hmos_set_microphone_enabled(false));revoke_on_generate=true;
 int starts=capture_starts;assert(!qemu_hmos_set_microphone_enabled(true));
 assert(capture_starts==starts && !in.capturer);assert_erased(&in);
 revoke_on_generate=false;permission=true;
 // Each builder call and Start failure must clean resources while output survives.
 for(int fail=1;fail<=10;fail++) {
  assert(qemu_hmos_set_microphone_enabled(false));calls=0;fail_at=fail;
  assert(!qemu_hmos_set_microphone_enabled(true));
  assert(!builders && streams==1 && !in.capturer && !in.enabled);assert_erased(&in);
  assert(qemu_hmos_get_microphone_status()==AETHER_MIC_ERROR);
  fail_at=0;assert_playback(&out);
 }
 // Rapid controls with concurrent callback delivery use actual pthread mutexes.
 pthread_t callbacks;assert(!pthread_create(&callbacks,NULL,callback_worker,&in));
 for(int i=0;i<100;i++) {
  assert(qemu_hmos_set_microphone_enabled(true));
  (void)guest_read(&in,dst,sizeof(dst));
  assert(qemu_hmos_set_microphone_enabled(false));
 }
 assert(!pthread_join(callbacks,NULL));assert_erased(&in);assert(!in.capturer);
 assert(qemu_hmos_get_microphone_status()==AETHER_MIC_DISABLED);assert_playback(&out);
 assert(!mixed_reads);
 aether_fini_in(&in.hw);aether_fini_out(&out.hw);assert(!builders && !streams && !aether_inputs);
 as.fmt=999;assert(aether_init_out(&out.hw,&as,NULL)==-1);assert(aether_init_in(&in.hw,&as,&capture_device)==-1);
 puts("OHAudio mock privacy/lifecycle/failure/PCM tests passed; no device test");
}
