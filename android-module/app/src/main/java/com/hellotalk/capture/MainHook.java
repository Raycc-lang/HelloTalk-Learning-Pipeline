package com.hellotalk.capture;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.media.AudioRecord;
import android.media.MediaRecorder;

import java.lang.reflect.Method;
import java.nio.ByteBuffer;
import java.util.Set;

import de.robv.android.xposed.IXposedHookLoadPackage;
import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;
import de.robv.android.xposed.callbacks.XC_LoadPackage;

public class MainHook implements IXposedHookLoadPackage {

    private static final String TAG = "HTCapture";
    private static final String PACKAGE_NAME = "com.hellotalk";
    private static final String ACTION_STOP = "com.hellotalk.STOP_CAPTURE";

    private boolean broadcastRegistered = false;

    @Override
    public void handleLoadPackage(XC_LoadPackage.LoadPackageParam lpparam) {
        if (!lpparam.packageName.equals(PACKAGE_NAME)) return;

        XposedBridge.log(TAG + ": Module loaded in " + lpparam.packageName);

        // --- Standard AudioRecord hooks (for voice messages, non-RTC features) ---
        hookAudioRecordAll();

        // --- Agora RTC hooks (for voice rooms, calls) ---
        hookAgoraAudioFrameObserver(lpparam);
        hookAGEventHandler(lpparam);
        hookAgoraLeaveChannel(lpparam);

        // --- Tencent LiteAV hooks (for TRTC features) ---
        hookLiteavRead(lpparam);

        // --- MediaRecorder hooks (for voice messages) ---
        hookMediaRecorder();

        // --- Lifecycle ---
        hookApplicationOnCreate(lpparam);

        XposedBridge.log(TAG + ": All hooks registered");
    }

    // ===== AudioRecord hooks =====

    private void hookAudioRecordAll() {
        try {
            XposedBridge.hookAllConstructors(AudioRecord.class, new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    Object[] args = param.args;
                    XposedBridge.log(TAG + ": AudioRecord constructor (" + args.length + " args)");
                    try {
                        if (args.length >= 5) {
                            AudioCaptureManager.getInstance().registerAudioRecord(
                                    (AudioRecord) param.thisObject,
                                    (int) args[1], (int) args[2], (int) args[3]);
                        }
                    } catch (Throwable t) {
                        XposedBridge.log(TAG + ": constructor metadata error: " + t.getMessage());
                    }
                }
            });
        } catch (Throwable t) {
            XposedBridge.log(TAG + ": Failed to hook AudioRecord constructors: " + t.getMessage());
        }

        try {
            Set<XC_MethodHook.Unhook> unhooks = XposedBridge.hookAllMethods(AudioRecord.class, "read", new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    try {
                        int bytesRead = (int) param.getResult();
                        if (bytesRead <= 0) return;
                        Object[] args = param.args;
                        if (args[0] instanceof byte[]) {
                            AudioCaptureManager.getInstance().writeAudioData(
                                    (AudioRecord) param.thisObject, (byte[]) args[0], (int) args[1], bytesRead);
                        } else if (args[0] instanceof ByteBuffer) {
                            byte[] data = extractFromByteBuffer((ByteBuffer) args[0], bytesRead);
                            if (data != null) {
                                AudioCaptureManager.getInstance().writeAudioData(
                                        (AudioRecord) param.thisObject, data, 0, bytesRead);
                            }
                        } else if (args[0] instanceof short[]) {
                            short[] shortData = (short[]) args[0];
                            int offset = (int) args[1];
                            byte[] data = new byte[bytesRead * 2];
                            for (int i = 0; i < bytesRead; i++) {
                                short s = shortData[offset + i];
                                data[i * 2] = (byte) (s & 0xFF);
                                data[i * 2 + 1] = (byte) ((s >> 8) & 0xFF);
                            }
                            AudioCaptureManager.getInstance().writeAudioData(null, data, 0, data.length);
                        }
                    } catch (Throwable t) {
                        XposedBridge.log(TAG + ": read hook error: " + t.getMessage());
                    }
                }
            });
            XposedBridge.log(TAG + ": Hooked " + unhooks.size() + " AudioRecord.read() overloads");
        } catch (Throwable t) {
            XposedBridge.log(TAG + ": Failed to hook AudioRecord.read: " + t.getMessage());
        }

        try {
            Set<XC_MethodHook.Unhook> unhooks = XposedBridge.hookAllMethods(AudioRecord.class, "startRecording", new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    AudioRecord rec = (AudioRecord) param.thisObject;
                    XposedBridge.log(TAG + ": AudioRecord.startRecording() sampleRate=" +
                            rec.getSampleRate() + " ch=" + rec.getChannelCount());
                }
            });
            XposedBridge.log(TAG + ": Hooked " + unhooks.size() + " startRecording overloads");
        } catch (Throwable t) {
            XposedBridge.log(TAG + ": Failed to hook startRecording: " + t.getMessage());
        }
    }

    // ===== Agora RTC hooks =====

    /**
     * Hook HtAgoraAudioFrameObserver.onRecordAudioFrame (bo1.a)
     * This is the Agora IAudioFrameObserver implementation that receives raw audio from native.
     * Signature: onRecordAudioFrame(String, int, int, int, int, int, ByteBuffer, long, int) -> boolean
     */
    private void hookAgoraAudioFrameObserver(XC_LoadPackage.LoadPackageParam lpparam) {
        // Try the obfuscated class name first
        String[] classNames = {"rn1.a", "xq1.a", "bo1.a", "lib.hellotalk.live.agora.listener.HtAgoraAudioFrameObserver"};
        for (String className : classNames) {
            try {
                Class<?> clazz = XposedHelpers.findClass(className, lpparam.classLoader);
                Set<XC_MethodHook.Unhook> unhooks = XposedBridge.hookAllMethods(clazz, "onRecordAudioFrame", new XC_MethodHook() {
                    @Override
                    protected void afterHookedMethod(MethodHookParam param) {
                        try {
                            Object[] args = param.args;
                            // Find the ByteBuffer argument
                            ByteBuffer buffer = null;
                            int samplesPerChannel = 0;
                            int bytesPerSample = 0;
                            int channels = 0;
                            int samplesPerSec = 0;

                            for (Object arg : args) {
                                if (arg instanceof ByteBuffer) {
                                    buffer = (ByteBuffer) arg;
                                    break;
                                }
                            }

                            // Parse known Agora IAudioFrameObserver signature:
                            // onRecordAudioFrame(String channelId, int type, int samplesPerChannel,
                            //   int bytesPerSample, int channels, int samplesPerSec,
                            //   ByteBuffer buffer, long renderTimeMs, int avsync_type)
                            if (args.length >= 9) {
                                samplesPerChannel = (int) args[2];
                                bytesPerSample = (int) args[3];
                                channels = (int) args[4];
                                samplesPerSec = (int) args[5];
                                buffer = (ByteBuffer) args[6];
                            }

                            if (buffer == null || samplesPerChannel <= 0) return;

                            int totalBytes = samplesPerChannel * bytesPerSample * channels;
                            AudioCaptureManager.getInstance().setFallbackMetadata(
                                    samplesPerSec, channels, bytesPerSample * 8);

                            ByteBuffer dup = buffer.duplicate();
                            dup.rewind();
                            byte[] data = new byte[totalBytes];
                            dup.get(data);
                            AudioCaptureManager.getInstance().writeAgoraAudioData(data, 0, totalBytes);
                        } catch (Throwable t) {
                            XposedBridge.log(TAG + ": Agora onRecordAudioFrame error: " + t.getMessage());
                        }
                    }
                });
                XposedBridge.log(TAG + ": Hooked " + className + ".onRecordAudioFrame (" + unhooks.size() + " methods)");
                return; // Success, no need to try other class names
            } catch (Throwable t) {
                XposedBridge.log(TAG + ": " + className + " not found: " + t.getMessage());
            }
        }
    }

    /**
     * Hook AGEventHandler.l(byte[]) — the bridge that passes audio data
     * from HtAgoraAudioFrameObserver to HelloTalk's RtcEvent listeners.
     * Class: uc0.a, method: l
     */
    private void hookAGEventHandler(XC_LoadPackage.LoadPackageParam lpparam) {
        // uc0.a is the obfuscated AGEventHandler
        String[] classNames = {"l90.a", "od0.a", "uc0.a", "com.hellotalk.live.base.listener.AGEventHandler"};
        for (String className : classNames) {
            try {
                Class<?> clazz = XposedHelpers.findClass(className, lpparam.classLoader);
                XposedHelpers.findAndHookMethod(clazz, "l", byte[].class, new XC_MethodHook() {
                    @Override
                    protected void afterHookedMethod(MethodHookParam param) {
                        // Skip if Agora IAudioFrameObserver hook is already capturing
                        if (AudioCaptureManager.getInstance().isAgoraHookActive()) return;
                        byte[] audioData = (byte[]) param.args[0];
                        if (audioData != null && audioData.length > 0) {
                            AudioCaptureManager.getInstance().writeAgoraAudioData(
                                    audioData, 0, audioData.length);
                        }
                    }
                });
                XposedBridge.log(TAG + ": Hooked " + className + ".l(byte[])");
                return;
            } catch (Throwable t) {
                XposedBridge.log(TAG + ": " + className + ".l not found: " + t.getMessage());
            }
        }
    }

    /**
     * Hook Agora RtcEngine.leaveChannel to finalize recording when leaving a voice room.
     */
    private void hookAgoraLeaveChannel(XC_LoadPackage.LoadPackageParam lpparam) {
        try {
            Class<?> clazz = XposedHelpers.findClass("io.agora.rtc2.RtcEngineEx", lpparam.classLoader);
            XposedBridge.hookAllMethods(clazz, "leaveChannel", new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    XposedBridge.log(TAG + ": Agora leaveChannel — finalizing recording");
                    AudioCaptureManager.getInstance().finalizeRecording();
                }
            });
            XposedBridge.log(TAG + ": Hooked RtcEngineEx.leaveChannel()");
        } catch (Throwable t) {
            // Try base class
            try {
                Class<?> clazz = XposedHelpers.findClass("io.agora.rtc2.RtcEngine", lpparam.classLoader);
                XposedBridge.hookAllMethods(clazz, "leaveChannel", new XC_MethodHook() {
                    @Override
                    protected void afterHookedMethod(MethodHookParam param) {
                        XposedBridge.log(TAG + ": Agora leaveChannel — finalizing recording");
                        AudioCaptureManager.getInstance().finalizeRecording();
                    }
                });
                XposedBridge.log(TAG + ": Hooked RtcEngine.leaveChannel()");
            } catch (Throwable t2) {
                XposedBridge.log(TAG + ": Agora leaveChannel not found (OK, idle timeout will handle it)");
            }
        }
    }

    // ===== Tencent LiteAV hooks =====

    private void hookLiteavRead(XC_LoadPackage.LoadPackageParam lpparam) {
        String[] classes = {
                "com.tencent.liteav.audio2.LiteavAudioRecord2",
                "com.tencent.liteav.audio2.LiteavAudioRecord3"
        };
        for (String className : classes) {
            try {
                Class<?> clazz = XposedHelpers.findClass(className, lpparam.classLoader);
                XposedHelpers.findAndHookMethod(clazz, "read", ByteBuffer.class, int.class,
                        new XC_MethodHook() {
                            @Override
                            protected void afterHookedMethod(MethodHookParam param) {
                                int bytesRead = (int) param.getResult();
                                if (bytesRead <= 0) return;
                                byte[] data = extractFromByteBuffer((ByteBuffer) param.args[0], bytesRead);
                                if (data != null) {
                                    AudioCaptureManager.getInstance().writeAudioData(null, data, 0, bytesRead);
                                }
                            }
                        });
                XposedBridge.log(TAG + ": Hooked " + className + ".read()");
            } catch (Throwable t) {
                XposedBridge.log(TAG + ": " + className + " not found (OK)");
            }

            try {
                Class<?> clazz = XposedHelpers.findClass(className, lpparam.classLoader);
                XposedHelpers.findAndHookMethod(clazz, "startRecording",
                        int.class, int.class, int.class, int.class,
                        new XC_MethodHook() {
                            @Override
                            protected void afterHookedMethod(MethodHookParam param) {
                                int sampleRate = (int) param.args[1];
                                int channels = (int) param.args[2];
                                XposedBridge.log(TAG + ": LiteAV startRecording — " +
                                        sampleRate + " Hz, " + channels + " ch");
                                AudioCaptureManager.getInstance().setFallbackMetadata(sampleRate, channels, 16);
                            }
                        });
            } catch (Throwable t) {
                // OK if not found
            }
        }
    }

    // ===== MediaRecorder hooks =====

    private void hookMediaRecorder() {
        try {
            XposedBridge.hookAllMethods(MediaRecorder.class, "start", new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    XposedBridge.log(TAG + ": MediaRecorder.start() called");
                }
            });
            XposedBridge.log(TAG + ": Hooked MediaRecorder.start()");
        } catch (Throwable t) {
            XposedBridge.log(TAG + ": Failed to hook MediaRecorder: " + t.getMessage());
        }
    }

    // ===== Helpers =====

    private static byte[] extractFromByteBuffer(ByteBuffer buffer, int bytesRead) {
        try {
            ByteBuffer dup = buffer.duplicate();
            int pos = dup.position();
            if (pos >= bytesRead) {
                dup.position(pos - bytesRead);
            } else {
                dup.position(0);
            }
            byte[] data = new byte[bytesRead];
            dup.get(data);
            return data;
        } catch (Throwable t) {
            XposedBridge.log(TAG + ": ByteBuffer extract error: " + t.getMessage());
            return null;
        }
    }

    // ===== Lifecycle =====

    private void hookApplicationOnCreate(XC_LoadPackage.LoadPackageParam lpparam) {
        try {
            XposedHelpers.findAndHookMethod("android.app.Application", lpparam.classLoader,
                    "onCreate", new XC_MethodHook() {
                        @Override
                        protected void afterHookedMethod(MethodHookParam param) {
                            if (broadcastRegistered) return;
                            broadcastRegistered = true;
                            Context app = (Context) param.thisObject;
                            IntentFilter filter = new IntentFilter(ACTION_STOP);
                            app.registerReceiver(new BroadcastReceiver() {
                                @Override
                                public void onReceive(Context context, Intent intent) {
                                    XposedBridge.log(TAG + ": Stop broadcast received, finalizing…");
                                    AudioCaptureManager.getInstance().finalizeRecording();
                                }
                            }, filter, Context.RECEIVER_EXPORTED);
                            XposedBridge.log(TAG + ": Registered stop-capture broadcast receiver");
                        }
                    });
        } catch (Throwable t) {
            XposedBridge.log(TAG + ": Failed to hook Application.onCreate: " + t.getMessage());
        }

        try {
            XposedHelpers.findAndHookMethod("android.app.Application", lpparam.classLoader,
                    "onTerminate", new XC_MethodHook() {
                        @Override
                        protected void beforeHookedMethod(MethodHookParam param) {
                            AudioCaptureManager.getInstance().finalizeRecording();
                        }
                    });
        } catch (Throwable t) {
            // OK
        }
    }
}
