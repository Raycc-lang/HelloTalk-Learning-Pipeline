#!/usr/bin/env python3
"""Publish complete recordings atomically, retaining successful segment inputs."""
import hashlib, json, os, re, sys, tempfile
from pathlib import Path

def atomic(path, data):
    if path.exists() and path.read_bytes() == data: return
    fd, tmp = tempfile.mkstemp(prefix='.recording-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as f: f.write(data)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)

def main():
    pending, audio, transcripts = map(Path, sys.argv[1:])
    bases = {re.sub(r'_\d{3}$', '', p.stem) for p in transcripts.glob('*_[0-9][0-9][0-9].txt')}
    bases |= {p.stem for p in pending.glob('*.segments')}
    failed = False
    for base in sorted(bases):
        if (pending / (base+'.building')).exists():
            failed = True; continue
        manifest = pending / (base+'.segments')
        if manifest.exists():
            names = [Path(n).stem for n in manifest.read_text().splitlines()]
        else:
            # Legacy data: all known successful and pending segments must participate.
            names = sorted({p.stem for p in transcripts.glob(base+'_[0-9][0-9][0-9].txt')} |
                           {p.stem for p in pending.glob(base+'_[0-9][0-9][0-9].wav')} |
                           {p.stem for p in audio.glob('*/'+base+'_[0-9][0-9][0-9].wav')})
        records, parts, complete = [], [], True
        for name in names:
            path = transcripts / (name+'.txt')
            if path.exists() and len(path.read_bytes()) > 6 and path.read_text().strip() not in ('', '.'):
                data = path.read_bytes()
                records.append({'segment': name, 'sha256': hashlib.sha256(data).hexdigest()})
                parts.append(data.rstrip(b'\n')+b'\n')
            elif (transcripts / '.rejected' / name).exists():
                records.append({'segment': name, 'rejected': True})
            else:
                complete = False
        if not complete:
            print(f'{base}: incomplete; retry pending', file=sys.stderr)
            failed = True; continue
        if not parts: continue
        output = b''.join(parts)
        # Legacy successful segment files were deleted. Never replace a larger
        # existing recording with a lone historical retry lacking a manifest.
        dest = transcripts / (base+'.txt')
        marker = transcripts / (base+'.complete.json')
        recording_day = f'{base[14:18]}-{base[18:20]}-{base[20:22]}'
        archived = transcripts.parent / 'Cleansed_Originals' / recording_day / (base+'.txt')
        if not manifest.exists() and not marker.exists() and (dest.exists() or archived.exists()):
            print(f'{base}: legacy recording needs original segments before rebuild', file=sys.stderr)
            failed = True; continue
        atomic(dest, output)
        atomic(marker, (json.dumps({'segments': records, 'sha256': hashlib.sha256(output).hexdigest()}, sort_keys=True)+'\n').encode())
    return int(failed)

if __name__ == '__main__': sys.exit(main())
