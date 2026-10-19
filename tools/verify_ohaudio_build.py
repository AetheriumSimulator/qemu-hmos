#!/usr/bin/env python3
"""Verify compiled OHAudio registration/linkage; this is not a device audio test."""
import argparse
import json
from pathlib import Path
import subprocess


def verify(core, readelf='readelf'):
    def elf(*args):
        return subprocess.check_output([readelf, '--wide', *args, str(core)], text=True)
    symbols = elf('--symbols')
    dynamic = elf('--dynamic')
    # These are compiled C registration/implementation symbols, not source text.
    for symbol in ('register_audio_aether_soundkit_hmos', 'aether_audio_driver',
                   'aether_init_out', 'aether_init_in'):
        if not any(line.split()[-1:] == [symbol] and ' UND ' not in line for line in symbols.splitlines()):
            raise ValueError(f'Missing compiled OHAudio symbol: {symbol}')
    for api in ('OH_AudioStreamBuilder_SetRendererCallback', 'OH_AudioStreamBuilder_SetCapturerCallback',
                'OH_AudioRenderer_Start', 'OH_AudioCapturer_Start'):
        if not any(' UND ' in line and line.split()[-1].split('@')[0] == api for line in symbols.splitlines()):
            raise ValueError(f'Missing linked OHAudio API: {api}')
    if not any('NEEDED' in line and '[libohaudio.so]' in line for line in dynamic.splitlines()):
        raise ValueError('Core has no libohaudio.so dependency')
    return {'backend': 'aether-soundkit-hmos', 'compiledRegistration': 'verified',
            'nativeDependency': 'libohaudio.so', 'devicePlayback': 'not-executed',
            'deviceCapture': 'not-executed'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('core', type=Path)
    parser.add_argument('--readelf', default='readelf')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    result = json.dumps(verify(args.core, args.readelf), indent=2) + '\n'
    if args.output:
        args.output.write_text(result)
    print(result)
