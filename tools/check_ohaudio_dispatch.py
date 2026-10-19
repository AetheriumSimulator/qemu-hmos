#!/usr/bin/env python3
"""Execute actual patched QEMU PDO dispatch with small host-only type fixtures."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
qemu = root/'third_party/qemu'

def function(path, start, end):
    text = path.read_text()
    return text[text.index(start):text.index(end, text.index(start))]

create = function(qemu/'audio/audio.c', 'void audio_create_pdos(', '\nstatic void audio_validate_per_direction_opts')
get = function(qemu/'audio/audio_template.h', 'AudiodevPerDirectionOptions *glue(audio_get_pdo_', '\nstatic HW *glue(audio_pcm_hw_add_')
fixture = '''#include <stdlib.h>
#include <assert.h>
#define g_malloc0(n) calloc(1,n)
#define glue(a,b) join(a,b)
#define join(a,b) a##b
typedef struct { int marker; } AudiodevPerDirectionOptions;
typedef struct { AudiodevPerDirectionOptions *in,*out; } Options;
enum {AUDIODEV_DRIVER_NONE,AUDIODEV_DRIVER_AETHER_SOUNDKIT_HMOS,AUDIODEV_DRIVER_WAV,AUDIODEV_DRIVER__MAX};
typedef struct { int driver; union {Options none,aether_soundkit_hmos,wav;} u; } Audiodev;
'''
with tempfile.TemporaryDirectory() as tmp:
    p=Path(tmp)
    source=fixture+create+'\n#define TYPE out\n'+get+'\n#undef TYPE\n#define TYPE in\n'+get+'''
int main(void) {
 Audiodev dev={.driver=AUDIODEV_DRIVER_AETHER_SOUNDKIT_HMOS};
 audio_create_pdos(&dev);
 assert(dev.u.aether_soundkit_hmos.in && dev.u.aether_soundkit_hmos.out);
 assert(audio_get_pdo_in(&dev)==dev.u.aether_soundkit_hmos.in);
 assert(audio_get_pdo_out(&dev)==dev.u.aether_soundkit_hmos.out);
 free(dev.u.aether_soundkit_hmos.in); free(dev.u.aether_soundkit_hmos.out);
}
'''
    (p/'test.c').write_text(source)
    subprocess.run(['cc','-std=c11','-Wall','-Werror',str(p/'test.c'),'-o',str(p/'test')],check=True)
    subprocess.run([str(p/'test')],check=True)
print('Patched QEMU input/output PDO allocation and dispatch executed successfully')
