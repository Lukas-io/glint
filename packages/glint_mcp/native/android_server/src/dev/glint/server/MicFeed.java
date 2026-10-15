package dev.glint.server;

import android.content.AttributionSource;
import android.content.Context;
import android.content.ContextWrapper;
import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioTrack;
import android.media.MediaRecorder;
import android.os.Looper;
import java.io.FileInputStream;
import java.io.InputStream;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.Method;

/** Feeds PCM into every app that records the microphone, through a loop-back audio policy (shell holds MODIFY_AUDIO_ROUTING), so no host audio or emulator control is involved. */
final class MicFeed {
    static final int SAMPLE_RATE = 48000;

    private final Object policy;
    private final AudioManager audio;
    private final AudioTrack track;

    private MicFeed(Object policy, AudioManager audio, AudioTrack track) {
        this.policy = policy;
        this.audio = audio;
        this.track = track;
    }

    private static android.os.HandlerThread looperThread;

    /** [open] on a thread of its own with a Looper, which the audio policy needs for its callbacks; socket threads have none. */
    static MicFeed openOnLooper() throws Exception {
        synchronized (MicFeed.class) {
            if (looperThread == null) {
                looperThread = new android.os.HandlerThread("glint-audio-policy");
                looperThread.start();
            }
        }
        java.util.concurrent.CountDownLatch done = new java.util.concurrent.CountDownLatch(1);
        Object[] result = new Object[1];
        new android.os.Handler(looperThread.getLooper()).post(() -> {
            try {
                result[0] = open();
            } catch (Throwable t) {
                result[0] = t;
            }
            done.countDown();
        });
        if (!done.await(10, java.util.concurrent.TimeUnit.SECONDS)) throw new IllegalStateException("the audio policy did not open within 10 s");
        if (result[0] instanceof Exception) throw (Exception) result[0];
        if (result[0] instanceof Throwable) throw new RuntimeException((Throwable) result[0]);
        return (MicFeed) result[0];
    }

    /** Registers the policy and returns a feed whose track writes into recorders of the usual capture presets. */
    static MicFeed open() throws Exception {
        Context context = new ShellContext(systemContext());
        Class<?> ruleClass = Class.forName("android.media.audiopolicy.AudioMixingRule");
        Class<?> ruleBuilder = Class.forName("android.media.audiopolicy.AudioMixingRule$Builder");
        Class<?> mixClass = Class.forName("android.media.audiopolicy.AudioMix");
        Class<?> mixBuilder = Class.forName("android.media.audiopolicy.AudioMix$Builder");
        Class<?> policyClass = Class.forName("android.media.audiopolicy.AudioPolicy");
        Class<?> policyBuilder = Class.forName("android.media.audiopolicy.AudioPolicy$Builder");

        int capturePreset = ruleClass.getField("RULE_MATCH_ATTRIBUTE_CAPTURE_PRESET").getInt(null);
        Object rules = ruleBuilder.getConstructor().newInstance();
        Method addMixRule = ruleBuilder.getMethod("addMixRule", int.class, Object.class);
        Method setCapturePreset = AudioAttributes.Builder.class.getMethod("setCapturePreset", int.class);
        for (int source : new int[] {
                MediaRecorder.AudioSource.MIC, MediaRecorder.AudioSource.VOICE_COMMUNICATION,
                MediaRecorder.AudioSource.VOICE_RECOGNITION, MediaRecorder.AudioSource.CAMCORDER,
                MediaRecorder.AudioSource.UNPROCESSED, MediaRecorder.AudioSource.DEFAULT}) {
            AudioAttributes.Builder attrs = new AudioAttributes.Builder();
            setCapturePreset.invoke(attrs, source);
            addMixRule.invoke(rules, capturePreset, attrs.build());
        }
        Object rule = ruleBuilder.getMethod("build").invoke(rules);

        AudioFormat format = new AudioFormat.Builder()
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(SAMPLE_RATE)
                .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                .build();
        Object mixes = mixBuilder.getConstructor(ruleClass).newInstance(rule);
        mixBuilder.getMethod("setFormat", AudioFormat.class).invoke(mixes, format);
        mixBuilder.getMethod("setRouteFlags", int.class).invoke(mixes, mixClass.getField("ROUTE_FLAG_LOOP_BACK").getInt(null));
        Object mix = mixBuilder.getMethod("build").invoke(mixes);

        Object builder = policyBuilder.getConstructor(Context.class).newInstance(context);
        policyBuilder.getMethod("addMix", mixClass).invoke(builder, mix);
        Object policy = policyBuilder.getMethod("build").invoke(builder);
        AudioManager audio = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
        int status = (int) AudioManager.class.getMethod("registerAudioPolicy", policyClass).invoke(audio, policy);
        if (status != 0) throw new IllegalStateException("registerAudioPolicy returned " + status);
        AudioTrack track = (AudioTrack) policyClass.getMethod("createAudioTrackSource", mixClass).invoke(policy, mix);
        track.play();
        return new MicFeed(policy, audio, track);
    }

    /** Writes 16-bit mono PCM; blocks at the playback rate. */
    int write(byte[] pcm, int length) {
        return track.write(pcm, 0, length);
    }

    /** Packages recording the microphone right now; empty when none, or when the system will not name them. */
    java.util.Set<String> recorders() {
        java.util.Set<String> out = new java.util.TreeSet<>();
        try {
            for (android.media.AudioRecordingConfiguration c : audio.getActiveRecordingConfigurations()) {
                Object name = c.getClass().getMethod("getClientPackageName").invoke(c);
                out.add(name == null ? "an app" : name.toString());
            }
        } catch (Exception e) {
            out.add("an app");
        }
        return out;
    }

    void close() {
        try {
            track.stop();
            track.release();
        } catch (Exception ignored) {
            // already gone
        }
        try {
            AudioManager.class.getMethod("unregisterAudioPolicy", Class.forName("android.media.audiopolicy.AudioPolicy")).invoke(audio, policy);
        } catch (Exception ignored) {
            // already gone
        }
    }

    /** The system context of a bare app_process, built the way the framework builds one for system_server. */
    private static Context systemContext;

    static synchronized Context systemContext() throws Exception {
        if (systemContext != null) return systemContext;
        if (Looper.getMainLooper() == null) Looper.prepareMainLooper();
        Class<?> activityThread = Class.forName("android.app.ActivityThread");
        Constructor<?> ctor = activityThread.getDeclaredConstructor();
        ctor.setAccessible(true);
        Object thread = ctor.newInstance();
        Field current = activityThread.getDeclaredField("sCurrentActivityThread");
        current.setAccessible(true);
        current.set(null, thread);
        Method getSystemContext = activityThread.getDeclaredMethod("getSystemContext");
        systemContext = (Context) getSystemContext.invoke(thread);
        return systemContext;
    }

    /** The system context speaking as the shell package, whose uid holds the audio routing permission. */
    static final class ShellContext extends ContextWrapper {
        ShellContext(Context base) {
            super(base);
        }

        @Override
        public String getPackageName() {
            return "com.android.shell";
        }

        @Override
        public String getOpPackageName() {
            return "com.android.shell";
        }

        @Override
        public AttributionSource getAttributionSource() {
            return new AttributionSource.Builder(2000).setPackageName("com.android.shell").build();
        }

        @Override
        public Context getApplicationContext() {
            return this;
        }
    }

    static byte[] readFile(String path) throws Exception {
        try (InputStream in = new FileInputStream(path)) {
            java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream();
            byte[] buf = new byte[65536];
            int n;
            while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
            return out.toByteArray();
        }
    }
}
