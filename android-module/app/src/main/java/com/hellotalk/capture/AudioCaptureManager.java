package com.hellotalk.capture;

import android.media.AudioFormat;
import android.media.AudioRecord;
import android.os.Handler;
import android.os.HandlerThread;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;
import java.util.WeakHashMap;

import de.robv.android.xposed.XposedBridge;

public class AudioCaptureManager {

    private static final String TAG = "HTCapture";
    private static final String OUTPUT_DIR = "/sdcard/HelloTalkCapture";
    private static final String FALLBACK_DIR = "/data/data/com.hellotalk/files/HelloTalkCapture";
    private static final long IDLE_TIMEOUT_MS = 3000; // Auto-finalize after 3s of no audio

    private static AudioCaptureManager sInstance;

    private final HandlerThread writerThread;
    private final Handler writerHandler;
    private final WeakHashMap<AudioRecord, RecordingSession> sessionMap = new WeakHashMap<>();

    private FileOutputStream currentPcmStream;
    private String currentPcmPath;
    private long totalBytesWritten;
    private boolean firstBufferLogged;
    private volatile boolean agoraHookActive = false;
    private Runnable idleFinalizerRunnable;

    private int lastSampleRate = 16000;
    private int lastChannelCount = 1;
    private int lastBitsPerSample = 16;

    public static class RecordingSession {
        public final int sampleRate;
        public final int channelCount;
        public final int bitsPerSample;

        public RecordingSession(int sampleRate, int channelConfig, int audioFormat) {
            this.sampleRate = sampleRate;
            this.channelCount = channelCountFromConfig(channelConfig);
            this.bitsPerSample = bitsFromFormat(audioFormat);
        }

        private static int channelCountFromConfig(int channelConfig) {
            switch (channelConfig) {
                case AudioFormat.CHANNEL_IN_MONO:
                    return 1;
                case AudioFormat.CHANNEL_IN_STEREO:
                    return 2;
                default:
                    return Integer.bitCount(channelConfig);
            }
        }

        private static int bitsFromFormat(int audioFormat) {
            switch (audioFormat) {
                case AudioFormat.ENCODING_PCM_8BIT:
                    return 8;
                case AudioFormat.ENCODING_PCM_16BIT:
                    return 16;
                case AudioFormat.ENCODING_PCM_FLOAT:
                    return 32;
                default:
                    return 16;
            }
        }
    }

    private AudioCaptureManager() {
        writerThread = new HandlerThread("HTCapture-Writer");
        writerThread.start();
        writerHandler = new Handler(writerThread.getLooper());
        idleFinalizerRunnable = () -> {
            XposedBridge.log(TAG + ": Idle timeout — auto-finalizing recording");
            doFinalize();
        };
    }

    public static synchronized AudioCaptureManager getInstance() {
        if (sInstance == null) {
            sInstance = new AudioCaptureManager();
        }
        return sInstance;
    }

    public void registerAudioRecord(AudioRecord record, int sampleRate,
                                    int channelConfig, int audioFormat) {
        RecordingSession session = new RecordingSession(sampleRate, channelConfig, audioFormat);
        synchronized (sessionMap) {
            sessionMap.put(record, session);
        }
        lastSampleRate = session.sampleRate;
        lastChannelCount = session.channelCount;
        lastBitsPerSample = session.bitsPerSample;
        XposedBridge.log(TAG + ": Registered AudioRecord — " +
                session.sampleRate + " Hz, " + session.channelCount + " ch, " +
                session.bitsPerSample + " bit");
    }

    public void setFallbackMetadata(int sampleRate, int channels, int bitsPerSample) {
        lastSampleRate = sampleRate;
        lastChannelCount = channels;
        lastBitsPerSample = bitsPerSample;
    }

    public boolean isAgoraHookActive() {
        return agoraHookActive;
    }

    public void writeAgoraAudioData(byte[] data, int offset, int bytesRead) {
        agoraHookActive = true;
        writeAudioData(null, data, offset, bytesRead);
    }

    public void writeAudioData(AudioRecord source, byte[] data, int offset, int bytesRead) {
        if (bytesRead <= 0) return;

        if (source != null) {
            RecordingSession session;
            synchronized (sessionMap) {
                session = sessionMap.get(source);
            }
            if (session != null) {
                lastSampleRate = session.sampleRate;
                lastChannelCount = session.channelCount;
                lastBitsPerSample = session.bitsPerSample;
            }
        }

        byte[] copy = new byte[bytesRead];
        System.arraycopy(data, offset, copy, 0, bytesRead);

        writerHandler.post(() -> {
            // Reset idle timer — audio is still flowing
            writerHandler.removeCallbacks(idleFinalizerRunnable);

            try {
                ensurePcmStream();
                currentPcmStream.write(copy);
                totalBytesWritten += copy.length;

                if (!firstBufferLogged) {
                    firstBufferLogged = true;
                    XposedBridge.log(TAG + ": First audio buffer received — " +
                            copy.length + " bytes, " + lastSampleRate + " Hz");
                }
            } catch (IOException e) {
                XposedBridge.log(TAG + ": Write error: " + e.getMessage());
            }

            // Schedule idle finalization
            writerHandler.postDelayed(idleFinalizerRunnable, IDLE_TIMEOUT_MS);
        });
    }

    private String resolveOutputDir() {
        File dir = new File(OUTPUT_DIR);
        if (!dir.exists()) dir.mkdirs();
        if (dir.canWrite()) return OUTPUT_DIR;

        File fallback = new File(FALLBACK_DIR);
        if (!fallback.exists()) fallback.mkdirs();
        return FALLBACK_DIR;
    }

    private void ensurePcmStream() throws IOException {
        if (currentPcmStream != null) return;

        String outputDir = resolveOutputDir();

        String timestamp = new SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(new Date());
        currentPcmPath = outputDir + "/hellotalk_mic_" + timestamp + ".pcm";
        currentPcmStream = new FileOutputStream(currentPcmPath);
        totalBytesWritten = 0;
        firstBufferLogged = false;

        XposedBridge.log(TAG + ": Started new PCM file: " + currentPcmPath);
    }

    public void finalizeRecording() {
        writerHandler.post(this::doFinalize);
    }

    private void doFinalize() {
        writerHandler.removeCallbacks(idleFinalizerRunnable);

        if (currentPcmStream == null) {
            return;
        }

        try {
            currentPcmStream.flush();
            currentPcmStream.close();
        } catch (IOException e) {
            XposedBridge.log(TAG + ": Error closing PCM: " + e.getMessage());
        }
        currentPcmStream = null;

        if (totalBytesWritten == 0) {
            new File(currentPcmPath).delete();
            return;
        }

        String wavPath = currentPcmPath.replace(".pcm", ".wav");
        try {
            convertPcmToWav(currentPcmPath, wavPath, lastSampleRate,
                    lastChannelCount, lastBitsPerSample);

            double durationSec = (double) totalBytesWritten /
                    (lastSampleRate * lastChannelCount * (lastBitsPerSample / 8));
            XposedBridge.log(TAG + ": Recording finalized — " + wavPath +
                    " (" + String.format(Locale.US, "%.1f", durationSec) + "s)");
        } catch (IOException e) {
            XposedBridge.log(TAG + ": WAV conversion error: " + e.getMessage());
        }
    }

    private void convertPcmToWav(String pcmPath, String wavPath,
                                 int sampleRate, int channels, int bitsPerSample)
            throws IOException {
        File pcmFile = new File(pcmPath);
        long pcmSize = pcmFile.length();

        FileOutputStream wavOut = new FileOutputStream(wavPath);
        try {
            wavOut.write(new byte[44]); // placeholder header

            FileInputStream pcmIn = new FileInputStream(pcmFile);
            try {
                byte[] buf = new byte[8192];
                int read;
                while ((read = pcmIn.read(buf)) != -1) {
                    wavOut.write(buf, 0, read);
                }
            } finally {
                pcmIn.close();
            }
        } finally {
            wavOut.close();
        }

        WavHeaderWriter.writeHeader(wavPath, pcmSize, sampleRate, channels, bitsPerSample);
    }
}
