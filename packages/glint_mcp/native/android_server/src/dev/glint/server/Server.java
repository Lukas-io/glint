package dev.glint.server;

import android.accessibilityservice.AccessibilityServiceInfo;
import android.app.UiAutomation;
import android.net.LocalServerSocket;
import android.net.LocalSocket;
import android.os.Build;
import android.os.HandlerThread;
import android.os.Looper;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import org.json.JSONObject;

/** glint's resident Android server: one UiAutomation connection, answering JSON lines on a local abstract socket. */
public final class Server {
    /** Bumped whenever a command's arguments or reply change; glint checks it before using the server. */
    static final int PROTOCOL = 1;

    public static void main(String[] args) {
        Looper.prepareMainLooper();
        new Thread(() -> {
            try {
                serve(args.length > 0 ? args[0] : "glint-server");
            } catch (Throwable t) {
                t.printStackTrace();
            }
            System.exit(0);
        }).start();
        Looper.loop();
    }

    private static void serve(String socketName) throws Exception {
        UiAutomation ua = connect();
        Commands commands = new Commands(ua);
        LocalServerSocket server = new LocalServerSocket(socketName);
        System.out.println("ready " + PROTOCOL);
        System.out.flush();
        while (true) {
            LocalSocket socket = server.accept();
            Thread t = new Thread(() -> session(socket, commands));
            t.setDaemon(true);
            t.start();
        }
    }

    private static void session(LocalSocket socket, Commands commands) {
        try (LocalSocket s = socket;
             BufferedReader in = new BufferedReader(new InputStreamReader(s.getInputStream(), StandardCharsets.UTF_8))) {
            OutputStream out = s.getOutputStream();
            String line;
            while ((line = in.readLine()) != null) {
                JSONObject reply;
                try {
                    JSONObject request = new JSONObject(line);
                    if ("quit".equals(request.optString("cmd"))) System.exit(0);
                    synchronized (commands) {
                        reply = commands.run(request);
                    }
                } catch (Throwable t) {
                    reply = new JSONObject().put("ok", false).put("error", "serverFailed").put("detail", String.valueOf(t));
                }
                out.write((reply.toString() + "\n").getBytes(StandardCharsets.UTF_8));
                out.flush();
            }
        } catch (Exception ignored) {
            // the client went away
        }
    }

    /** Connects UiAutomation the way `uiautomator` does, asking for every window and view id. */
    private static UiAutomation connect() throws Exception {
        HandlerThread thread = new HandlerThread("glint-ua");
        thread.start();
        Object connection = Class.forName("android.app.UiAutomationConnection").getDeclaredConstructor().newInstance();
        java.lang.reflect.Constructor<UiAutomation> ctor =
                UiAutomation.class.getDeclaredConstructor(Looper.class, Class.forName("android.app.IUiAutomationConnection"));
        ctor.setAccessible(true);
        UiAutomation ua = ctor.newInstance(thread.getLooper(), connection);
        if (Build.VERSION.SDK_INT >= 24) {
            UiAutomation.class.getMethod("connect", int.class).invoke(ua, 0);
        } else {
            UiAutomation.class.getMethod("connect").invoke(ua);
        }
        AccessibilityServiceInfo info = ua.getServiceInfo();
        info.flags |= AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
                | AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS
                | AccessibilityServiceInfo.FLAG_INCLUDE_NOT_IMPORTANT_VIEWS;
        ua.setServiceInfo(info);
        return ua;
    }
}
