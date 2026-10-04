#!/usr/bin/env python3
"""Rebuild daily inputs from immutable cleaned sources and durable assignments."""
import hashlib, json, os, sys, tempfile
from pathlib import Path

def publish(path, data):
    if path.exists() and path.read_bytes() == data:
        return
    fd, tmp = tempfile.mkstemp(prefix='.merge-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as f:
            f.write(data)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)

def main():
    cleaned, analysis, minimum = Path(sys.argv[1]), Path(sys.argv[2]), int(sys.argv[3])
    sources = {}
    # Legacy .consolidated folders remain readable; never move or delete sources.
    for folder in sorted(cleaned.glob('????-??-??*')):
        day = folder.name[:10]
        files = sorted(folder.glob('hellotalk_mic_*.txt'))
        if files: sources.setdefault(day, []).extend(files)
    # Late plain-folder transcripts replace same-named legacy archived copies.
    for day, files in sources.items():
        by_name = {}
        for path in sorted(files, key=lambda p: not p.parent.name.endswith('.consolidated')):
            by_name[path.name] = path
        sources[day] = list(by_name.values())
    state_path = analysis / 'consolidation-sources.json'
    state = json.loads(state_path.read_text()) if state_path.exists() else {}
    for day in sorted(sources):
        state.setdefault(day, day)
    # Follow assignments so chains remain idempotent even after interruption.
    def target(day):
        seen = set()
        while state.get(day, day) != day:
            if day in seen: raise ValueError('consolidation cycle')
            seen.add(day); day = state[day]
        return day
    days = sorted(sources)
    for i, day in enumerate(days[:-1]):
        if target(day) != day: continue
        folder = analysis / day
        if any((folder / f).is_file() for f in ('grammar.md', 'semantic.md')): continue
        group = [d for d in days if target(d) == day]
        lines = sum(len(p.read_text().splitlines()) for d in group for p in sources[d])
        if lines < minimum:
            state[day] = target(days[i+1])
    # Assignment checkpoint precedes rebuilding. A retry always reconstructs
    # the same inputs, even if the last run died between two renames.
    publish(state_path, (json.dumps(state, sort_keys=True, indent=2)+'\n').encode())
    groups = {}
    for day in days: groups.setdefault(target(day), []).append(day)
    for day in state:
        groups.setdefault(target(day), [])
    for dest, group in groups.items():
        folder = analysis / dest; folder.mkdir(exist_ok=True)
        records, content = [], []
        for day in group:
            if day != dest: content.append(f'# Merged from {day}\n'.encode())
            for path in sorted(set(sources[day])):
                data = path.read_bytes()
                records.append({'path': str(path), 'sha256': hashlib.sha256(data).hexdigest()})
                if content: content.append(b'\n')
                content.append(data)
        publish(folder / 'merged.txt', b''.join(content))
        publish(folder / 'merged.sources.json', (json.dumps(records, indent=2)+'\n').encode())
    for day in days:
        folder = analysis / day
        folder.mkdir(exist_ok=True)
        marker = folder / '.consolidated-to'
        if target(day) != day:
            publish(marker, (target(day)+'\n').encode())
        elif marker.exists(): marker.unlink()

if __name__ == '__main__': main()
