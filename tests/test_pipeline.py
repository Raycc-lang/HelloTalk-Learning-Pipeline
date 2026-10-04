import importlib.util, json, os, shutil, subprocess, tempfile, unittest
from pathlib import Path
BIN = Path('/home/ray/.local/bin')

class Pipeline(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)
        (self.home/'.local').mkdir()
        (self.home/'.local/bin').symlink_to(BIN)
        self.env = dict(os.environ, HOME=str(self.home))
        self.capture = self.home/'Android/HelloTalkCapture'
        self.capture.mkdir(parents=True)
    def tearDown(self): self.tmp.cleanup()
    def shell(self, code, **env):
        return subprocess.run(['bash', '-c', 'set -euo pipefail\n'+code], env=dict(self.env, **env), capture_output=True, text=True)
    def runpy(self, name, *args):
        return subprocess.run(['python3', str(BIN/name), *map(str,args)], capture_output=True, text=True)
    def test_consolidation_resume_and_late_input(self):
        cleaned, analysis = self.home/'cleaned', self.home/'analysis'
        analysis.mkdir()
        for day, text in [('2026-01-01','earlier\n'),('2026-01-02','later\n'*90)]:
            folder=cleaned/day;folder.mkdir(parents=True);(folder/'hellotalk_mic_a.txt').write_text(text)
        def merge(): self.assertEqual(self.runpy('hellotalk-merge-days.py',cleaned,analysis,80).returncode,0)
        merge(); dest=analysis/'2026-01-02/merged.txt'; original=dest.read_bytes(); merge();self.assertEqual(original,dest.read_bytes())
        dest.write_text('interrupted build')
        merge();self.assertEqual(original,dest.read_bytes())
        (cleaned/'2026-01-02/hellotalk_mic_b.txt').write_text('new transcript\n')
        merge();self.assertEqual(dest.read_text().count('earlier'),1);self.assertIn('new transcript',dest.read_text());self.assertTrue((cleaned/'2026-01-01').is_dir())
    def test_recording_retry_preserves_all_segments(self):
        pending, audio, txt=[self.home/n for n in ('pending','audio','txt')]
        for d in (pending,audio,txt): d.mkdir()
        (txt/'.rejected').mkdir()
        base='hellotalk_mic_20260101_120000'
        (pending/(base+'.segments')).write_text(base+'_001.wav\n'+base+'_002.wav\n')
        (txt/(base+'_001.txt')).write_text('first successful transcript\n')
        self.assertEqual(self.runpy('hellotalk-merge-recordings.py',pending,audio,txt).returncode,1)
        (txt/(base+'_002.txt')).write_text('second successful transcript\n')
        self.assertEqual(self.runpy('hellotalk-merge-recordings.py',pending,audio,txt).returncode,0)
        (txt/(base+'_002.txt')).write_text('second retry transcript\n')
        self.assertEqual(self.runpy('hellotalk-merge-recordings.py',pending,audio,txt).returncode,0)
        self.assertIn('first successful', (txt/(base+'.txt')).read_text())
        self.assertTrue((txt/(base+'_001.txt')).exists())
    def test_legacy_archived_recording_is_not_replaced_by_one_retry(self):
        pending=self.capture/'Processed_audio'; audio=self.capture/'Transcribed_audio';txt=self.capture/'Transcripts'
        for d in (pending,audio,txt): d.mkdir()
        base='hellotalk_mic_20260101_120000'
        archived=self.capture/'Cleansed_Originals/2026-01-01';archived.mkdir(parents=True)
        (archived/(base+'.txt')).write_text('old full recording transcript')
        (txt/(base+'_001.txt')).write_text('one successful retry')
        result=self.runpy('hellotalk-merge-recordings.py',pending,audio,txt)
        self.assertEqual(result.returncode,1)
        self.assertFalse((txt/(base+'.txt')).exists())
    def variants(self, extra=''):
        return self.shell('''
. "$HOME/.local/bin/hellotalk-variants.sh"
_hv_call_slot() {
    printf '%s\\n' "$1" >> "$HOME/calls"
    if [ "$1" = JUDGE ] && [ -f "$HOME/fail-judge" ]; then return 1; fi
    printf 'PATTERN NAME: test\\n' > "$4"
}
rc=0
hellotalk_generate "$HOME/prompt" "$HOME/input" "$HOME/output" analysis test || rc=$?
'''+extra+'\nexit "$rc"',VARIANTS='1',VARIANT_SLOTS='PRIMARY SECONDARY JUDGE',PROVIDER='custom',MODEL='one',API_BASE='https://fake',API_KEY='fake',SECONDARY_PROVIDER='custom',SECONDARY_MODEL='two',CUSTOM_API_BASE='https://fake',CUSTOM_API_KEY='fake',JUDGE_PROVIDER='custom',JUDGE_MODEL='judge',JUDGE_PROMPT_DIR=str(self.home))
    def test_candidate_cache_and_judge_separation(self):
        for name in ('prompt','input','judge-analysis.md'): (self.home/name).write_text('test')
        (self.home/'fail-judge').touch()
        self.assertEqual(self.variants().returncode,1)
        (self.home/'fail-judge').unlink()
        result=self.variants();self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual((self.home/'calls').read_text().splitlines(),['PRIMARY','SECONDARY','JUDGE','JUDGE'])
        self.assertEqual(self.variants().returncode,0)
        self.assertEqual(len((self.home/'calls').read_text().splitlines()),4)
    def test_publication_failure_propagates(self):
        for name in ('prompt','input','judge-analysis.md'): (self.home/name).write_text('test')
        self.assertEqual(self.variants('cp() { return 17; }\nrc=0\nhellotalk_generate "$HOME/prompt" "$HOME/input" "$HOME/output" analysis test || rc=$?').returncode,1)
    def test_tsv_optional_and_required_fields(self):
        good=self.home/'good';good.write_text('CORRECT THE ERROR\tfront\tanswer\t\t\tnote\n')
        bad=self.home/'bad';bad.write_text('CORRECT THE ERROR\tfront\t\t\t\tnote\n')
        result=self.shell('. "$HOME/.local/bin/hellotalk-variants.sh"\n_hv_output_sane "$HOME/good" tsv\n! _hv_output_sane "$HOME/bad" tsv')
        self.assertEqual(result.returncode,0,result.stderr)
        good.write_text(good.read_text()+'junk\n'*20)
        self.assertNotEqual(self.shell('. "$HOME/.local/bin/hellotalk-variants.sh"\n_hv_output_sane "$HOME/good" tsv').returncode,0)
    def test_quota_account_isolation(self):
        result=self.shell('''
. "$HOME/.local/bin/hellotalk-quota-check.sh"
mkdir -p "$HELLOTALK_QUOTA_DIR"
f=$(hellotalk_quota_sentinel_path)
printf 'expires_at=%s\\nreason=rate\\nmessage=test\\n' "$(( $(date +%s)+600 ))" > "$f"
rc=0; hellotalk_quota_check || rc=$?; [ "$rc" = 75 ]
API_KEY=other
hellotalk_quota_check
''', PROVIDER='custom', API_BASE='https://fake', API_KEY='fake')
        self.assertEqual(result.returncode,0,result.stderr)
    def test_cleanse_config_refresh_and_empty(self):
        config=self.home/'.config/hellotalk';config.mkdir(parents=True)
        raw=self.capture/'Transcripts';raw.mkdir()
        base='hellotalk_mic_20260101_120000.txt'
        (raw/base).write_text('This is a private sentence.\n')
        def cleanse(): return self.shell('bash "$HOME/.local/bin/hellotalk-cleanse.sh"')
        self.assertEqual(cleanse().returncode,0)
        dest=self.capture/'Cleaned_Transcripts/2026-01-01'/base
        self.assertTrue(dest.exists())
        (config/'cleanse.conf').write_text('private\n')
        r=cleanse();self.assertEqual(r.returncode,0,r.stderr);self.assertFalse(dest.exists())
        (config/'cleanse.conf').write_text('[\n')
        self.assertNotEqual(cleanse().returncode,0)
    def test_analysis_recent_first_and_budget_exit(self):
        for day in ('2026-01-01','2026-01-02'):
            folder=self.capture/'Cleaned_Transcripts'/day;folder.mkdir(parents=True)
            (folder/'hellotalk_mic_x.txt').write_text(('This is enough transcript material.\n')*90)
        (self.capture/'analysis-grammar.md').write_text('test prompt')
        client=self.home/'llm.py'
        client.write_text("import pathlib,sys\npathlib.Path(sys.argv[3]).write_text('PATTERN NAME: generated\\n')\n")
        env=dict(PROVIDER='custom',MODEL='fake',API_BASE='https://fake',API_KEY='fake',LLM_CALL=str(client),BATCH_TIMEOUT='0',ARTIFACT_TIMEOUT='30')
        result=self.shell('bash "$HOME/.local/bin/hellotalk-analyze.sh"',**env)
        self.assertEqual(result.returncode,75,result.stderr)
        env['BATCH_TIMEOUT']='100'
        result=self.shell('bash "$HOME/.local/bin/hellotalk-analyze.sh"',**env)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertLess(result.stdout.index('Analyzing 2026-01-02'),result.stdout.index('Analyzing 2026-01-01'))
    def test_process_publishes_recording_manifest(self):
        originals=self.capture/'Original_audio';originals.mkdir()
        wav=originals/'hellotalk_mic_20260101_120000.wav'
        subprocess.run(['ffmpeg','-v','error','-f','lavfi','-i','sine=frequency=440:duration=3','-y',str(wav)],check=True)
        result=self.shell('bash "$HOME/.local/bin/hellotalk-process-audio.sh"')
        self.assertEqual(result.returncode,0,result.stderr)
        pending=self.capture/'Processed_audio'
        manifest=pending/'hellotalk_mic_20260101_120000.segments'
        self.assertEqual(manifest.read_text(),'hellotalk_mic_20260101_120000_001.wav\n')
        self.assertFalse((pending/'hellotalk_mic_20260101_120000.building').exists())
        self.assertFalse(wav.exists())
        self.assertTrue((pending/manifest.read_text().strip()).exists())
    def test_auth_keeps_audio_pending(self):
        config=self.home/'.config/hellotalk';config.mkdir(parents=True)
        (config/'env').write_text('NVIDIA_API_KEY=fake\n')
        fake=self.home/'client.py';fake.write_text("import sys\nprint('UNAUTHENTICATED')\nsys.exit(1)\n")
        mocks=self.home/'mocks';mocks.mkdir()
        for name,text in [('ffprobe','echo 5'),('ffmpeg',"echo 'Overall RMS level dB: -10' >&2")]:
            p=mocks/name;p.write_text('#!/bin/bash\n'+text);p.chmod(0o755)
        pending=self.capture/'Processed_audio';pending.mkdir()
        wav=pending/'hellotalk_mic_20260101_120000_001.wav';wav.write_bytes(b'x'*60000)
        result=self.shell('bash "$HOME/.local/bin/hellotalk-transcribe.sh"',PYTHON_CLIENT=str(fake),PATH=str(mocks)+':'+os.environ['PATH'])
        self.assertNotEqual(result.returncode,0);self.assertTrue(wav.exists());self.assertTrue(Path(str(wav)+'.retry').exists())

class LLM(unittest.TestCase):
    def setUp(self):
        spec=importlib.util.spec_from_file_location('llm',BIN/'hellotalk-llm-call.py');self.m=importlib.util.module_from_spec(spec);spec.loader.exec_module(self.m)
    def test_retry_hints_and_bounds(self):
        self.assertEqual(self.m._parse_retry_after('[retry-after=1.5s]'),1.5)
        self.assertGreater(self.m._parse_retry_after('[retry-after=Wed, 21 Oct 2099 07:28:00 GMTs]'),0)
        self.m.MAX_RETRIES=9;self.m.RETRY_DELAYS=[0];self.m.call_api=lambda *a:'';self.m.time.sleep=lambda *a:None
        self.assertIsNone(self.m.call_with_retry('p','i'))
    def test_failed_chunk_preserves_existing_output(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder); prompt=root/'prompt'; source=root/'source'; output=root/'output'
            prompt.write_text('p');source.write_text('a'*20);output.write_text('previous good output')
            self.m.CHUNK_THRESHOLD=10
            responses=iter(['successful partial output',None])
            self.m.call_with_retry=lambda *a: next(responses)
            old_args=self.m.sys.argv
            self.m.sys.argv=['llm',str(prompt),str(source),str(output)]
            try:
                with self.assertRaises(SystemExit) as result: self.m.main()
                self.assertEqual(result.exception.code,1)
                self.assertEqual(output.read_text(),'previous good output')
            finally: self.m.sys.argv=old_args
    def test_long_line_chunk_limit(self):
        chunks=self.m.split_text('a'*10001,1000)
        self.assertTrue(all(len(c)<=1000 for c in chunks));self.assertEqual(''.join(chunks),'a'*10001)

if __name__=='__main__': unittest.main()
