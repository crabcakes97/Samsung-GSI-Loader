package com.test.avprobe;

import android.Manifest;
import android.app.Activity;
import android.content.Context;
import android.content.pm.PackageManager;
import android.graphics.ImageFormat;
import android.hardware.camera2.CameraAccessException;
import android.hardware.camera2.CameraCaptureSession;
import android.hardware.camera2.CameraCharacteristics;
import android.hardware.camera2.CameraDevice;
import android.hardware.camera2.CameraManager;
import android.hardware.camera2.CaptureRequest;
import android.hardware.camera2.params.StreamConfigurationMap;
import android.media.AudioFormat;
import android.media.AudioRecord;
import android.media.Image;
import android.media.ImageReader;
import android.media.MediaRecorder;
import android.os.Bundle;
import android.os.Handler;
import android.os.HandlerThread;
import android.util.Log;
import android.view.Surface;

import java.io.File;
import java.io.FileOutputStream;
import java.nio.ByteBuffer;
import java.util.Arrays;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/**
 * Headless probe: records 2 s of audio, then opens camera 0 and captures one
 * JPEG. Every result is logged under the AVPROBE tag and also written to
 * /sdcard/Android/data/com.test.avprobe/files/result.txt so it survives a
 * missing logcat.
 */
public class MainActivity extends Activity {
    private static final String T = "AVPROBE";
    private final StringBuilder report = new StringBuilder();

    private HandlerThread thread;
    private Handler handler;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        Log.i(T, "start uid=" + android.os.Process.myUid()
                + " pkg=" + getPackageName()
                + " camera=" + (checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED)
                + " mic=" + (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED));
        thread = new HandlerThread("avprobe");
        thread.start();
        handler = new Handler(thread.getLooper());
        new Thread(() -> {
            try {
                probeMic();
                probeCamera();
            } catch (Throwable t) {
                line("FATAL " + Log.getStackTraceString(t));
            }
            try {
                File f = new File(getExternalFilesDir(null), "result.txt");
                try (FileOutputStream out = new FileOutputStream(f)) {
                    out.write(report.toString().getBytes("UTF-8"));
                }
                line("report=" + f);
            } catch (Throwable t) {
                line("report write failed: " + t);
            }
            runOnUiThread(this::finish);
        }).start();
    }

    private void line(String s) {
        report.append(s).append('\n');
        Log.i(T, s);
    }

    private void probeMic() {
        line("--- MIC ---");
        int rate = 44100;
        int min = AudioRecord.getMinBufferSize(rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT);
        line("minBuffer=" + min);
        AudioRecord rec = null;
        try {
            rec = new AudioRecord(MediaRecorder.AudioSource.MIC, rate,
                    AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
                    Math.max(min, rate * 2));
            line("state=" + rec.getState() + " (3=INITIALIZED)");
            if (rec.getState() != AudioRecord.STATE_INITIALIZED) {
                line("MIC FAIL: record not initialized");
                return;
            }
            rec.startRecording();
            line("recording=" + rec.getRecordingState());
            short[] buf = new short[rate / 2];
            long sum = 0, peak = 0, frames = 0;
            long end = System.currentTimeMillis() + 2000;
            while (System.currentTimeMillis() < end) {
                int n = rec.read(buf, 0, buf.length);
                if (n > 0) {
                    for (int i = 0; i < n; i++) {
                        long v = Math.abs(buf[i]);
                        sum += (long) buf[i] * buf[i];
                        if (v > peak) peak = v;
                    }
                    frames += n;
                }
            }
            rec.stop();
            double rms = frames > 0 ? Math.sqrt((double) sum / frames) : 0;
            line("frames=" + frames + " rms=" + (long) rms + " peak=" + peak);
            line(frames > 0 && peak > 0 ? "MIC OK" : "MIC SILENT");
        } catch (Throwable t) {
            line("MIC FAIL " + Log.getStackTraceString(t));
        } finally {
            if (rec != null) rec.release();
        }
    }

    private void probeCamera() {
        line("--- CAMERA ---");
        CameraManager cm = (CameraManager) getSystemService(Context.CAMERA_SERVICE);
        try {
            String[] ids = cm.getCameraIdList();
            line("ids=" + Arrays.toString(ids));
            for (String id : ids) {
                CameraCharacteristics c = cm.getCameraCharacteristics(id);
                Integer facing = c.get(CameraCharacteristics.LENS_FACING);
                StreamConfigurationMap m = c.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP);
                line("id=" + id + " facing=" + facing
                        + " jpeg=" + (m != null ? Arrays.toString(m.getOutputSizes(ImageFormat.JPEG)) : "none"));
            }
            if (ids.length == 0) {
                line("CAMERA FAIL: no ids");
                return;
            }
            openAndCapture(cm, ids[0]);
        } catch (CameraAccessException e) {
            line("CAMERA ACCESS FAIL " + e);
        } catch (Throwable t) {
            line("CAMERA FAIL " + Log.getStackTraceString(t));
        }
    }

    private void openAndCapture(CameraManager cm, String id) throws Exception {
        CameraCharacteristics ch = cm.getCameraCharacteristics(id);
        StreamConfigurationMap map = ch.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP);
        android.util.Size[] sizes = map.getOutputSizes(ImageFormat.JPEG);
        android.util.Size size = sizes[0];
        for (android.util.Size s : sizes) {
            if (s.getWidth() <= 4000 && s.getHeight() <= 3000
                    && s.getWidth() * s.getHeight() > size.getWidth() * size.getHeight()) {
                size = s;
            }
        }
        line("capture size=" + size);
        final ImageReader reader = ImageReader.newInstance(size.getWidth(), size.getHeight(), ImageFormat.JPEG, 2);
        final CountDownLatch acquired = new CountDownLatch(1);
        final CountDownLatch opened = new CountDownLatch(1);
        final CountDownLatch configured = new CountDownLatch(1);
        final String[] result = new String[1];

        reader.setOnImageAvailableListener(r -> {
            try (Image img = r.acquireNextImage()) {
                ByteBuffer b = img.getPlanes()[0].getBuffer();
                byte[] data = new byte[b.remaining()];
                b.get(data);
                File f = new File(getExternalFilesDir(null), "capture.jpg");
                try (FileOutputStream out = new FileOutputStream(f)) {
                    out.write(data);
                }
                result[0] = "CAMERA OK bytes=" + data.length + " " + img.getWidth() + "x" + img.getHeight()
                        + " file=" + f.getAbsolutePath();
                acquired.countDown();
            } catch (Throwable t) {
                result[0] = "CAMERA CAPTURE FAIL " + t;
                acquired.countDown();
            }
        }, handler);

        CameraDevice.StateCallback cb = new CameraDevice.StateCallback() {
            @Override public void onOpened(CameraDevice d) {
                opened.countDown();
                try {
                    Surface s = reader.getSurface();
                    d.createCaptureSession(Arrays.asList(s), new CameraCaptureSession.StateCallback() {
                        @Override public void onConfigured(CameraCaptureSession session) {
                            configured.countDown();
                            try {
                                CaptureRequest.Builder b = d.createCaptureRequest(CameraDevice.TEMPLATE_STILL_CAPTURE);
                                b.addTarget(s);
                                session.capture(b.build(), new CameraCaptureSession.CaptureCallback() { }, handler);
                            } catch (Throwable t) {
                                result[0] = "CAMERA CAPTURE FAIL " + t;
                                acquired.countDown();
                            }
                        }
                        @Override public void onConfigureFailed(CameraCaptureSession session) {
                            configured.countDown();
                            result[0] = "CAMERA CONFIGURE FAIL";
                            acquired.countDown();
                        }
                    }, handler);
                } catch (Throwable t) {
                    result[0] = "CAMERA SESSION FAIL " + t;
                    acquired.countDown();
                }
            }
            @Override public void onDisconnected(CameraDevice d) {
                result[0] = "CAMERA DISCONNECTED";
                opened.countDown(); acquired.countDown();
            }
            @Override public void onError(CameraDevice d, int code) {
                result[0] = "CAMERA ERROR " + code;
                opened.countDown(); acquired.countDown();
            }
        };

        try {
            cm.openCamera(id, cb, handler);
        } catch (SecurityException se) {
            line("CAMERA SECURITY EXCEPTION " + se);
            return;
        }
        if (!opened.await(15, TimeUnit.SECONDS)) {
            line("CAMERA open timeout");
            reader.close();
            return;
        }
        line("opened=" + (result[0] == null) + " configured="
                + configured.await(10, TimeUnit.SECONDS));
        acquired.await(15, TimeUnit.SECONDS);
        line(result[0] != null ? result[0] : "CAMERA no image");
        reader.close();
    }
}
