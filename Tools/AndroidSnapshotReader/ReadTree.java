package io.nlopez.alas.android;

import android.accessibilityservice.AccessibilityServiceInfo;
import android.app.UiAutomation;
import android.graphics.Point;
import android.graphics.Rect;
import android.os.Looper;
import android.os.SystemClock;
import android.view.Display;
import android.view.accessibility.AccessibilityNodeInfo;
import java.io.IOException;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

/** Reads the active default-display tree over the adb shell's private stdio. */
public final class ReadTree {
    private static final int IDLE_MS = 5000;
    private static final int MAX_CHARS = 256 * 1024;
    private static final int MAX_DEPTH = 128;

    @SuppressWarnings("deprecation")
    public static void main(String[] args) {
        // app_process doesn't create the looper used by AccessibilityInteractionClient.
        Looper.prepareMainLooper();
        new Thread(() -> {
            try {
                run();
                System.exit(0);
            } catch (Exception failure) {
                // Do not send exception text that could contain screen data.
                System.exit(1);
            }
        }, "alas-snapshot").start();
        Looper.loop();
    }

    private static void run() throws Exception {
        var requests = new ArrayBlockingQueue<Integer>(1);
        Thread input = new Thread(() -> {
            try {
                while (System.in.read() == 'r' && System.in.read() == '\n') requests.put(1);
                requests.put(0);
            } catch (IOException failure) {
                requests.offer(0);
            } catch (InterruptedException cancelled) {
                Thread.currentThread().interrupt();
            }
        });
        input.setDaemon(true);
        input.start();
        if (!Integer.valueOf(1).equals(requests.poll(IDLE_MS, TimeUnit.MILLISECONDS))) return;

        UiAutomation automation;
        Method connect;
        Method disconnect;
        Display display;
        try {
            Class<?> connectionType = Class.forName("android.app.IUiAutomationConnection");
            Object connection = Class.forName("android.app.UiAutomationConnection").getConstructor().newInstance();
            automation = UiAutomation.class.getConstructor(Looper.class, connectionType)
                .newInstance(Looper.getMainLooper(), connection);
            connect = UiAutomation.class.getMethod("connect", int.class);
            disconnect = UiAutomation.class.getMethod("disconnect");
            Class<?> displays = Class.forName("android.hardware.display.DisplayManagerGlobal");
            display = (Display) displays.getMethod("getRealDisplay", int.class)
                .invoke(displays.getMethod("getInstance").invoke(null), Display.DEFAULT_DISPLAY);
        } catch (ReflectiveOperationException | LinkageError unsupported) {
            System.out.println("!unsupported");
            return;
        }
        if (display == null) {
            System.out.println("!unavailable");
            return;
        }

        // Bound even a framework call that hangs after taking the automation slot.
        var watchdog = Executors.newSingleThreadScheduledExecutor();
        var startup = watchdog.schedule(() -> System.exit(1), 6, TimeUnit.SECONDS);
        try {
            connect.invoke(automation, UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES);
        } catch (InvocationTargetException failure) {
            String message = failure.getCause().getMessage();
            if (message != null && message.contains("already registered")) {
                System.out.println("!busy");
                return;
            }
            throw failure;
        }
        try {
            AccessibilityServiceInfo info = automation.getServiceInfo();
            int flags = AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS | AccessibilityServiceInfo.FLAG_INCLUDE_NOT_IMPORTANT_VIEWS;
            if ((info.flags & flags) != flags) {
                info.flags |= flags;
                automation.setServiceInfo(info);
            }
            startup.cancel(false);
            do {
                var deadline = watchdog.schedule(() -> System.exit(1), 3, TimeUnit.SECONDS);
                try {
                    System.out.println(read(automation, display));
                    if (System.out.checkError()) break;
                } finally {
                    deadline.cancel(false);
                }
            } while (Integer.valueOf(1).equals(requests.poll(IDLE_MS, TimeUnit.MILLISECONDS)));
        } finally {
            var deadline = watchdog.schedule(() -> System.exit(1), 3, TimeUnit.SECONDS);
            try {
                disconnect.invoke(automation);
            } finally {
                deadline.cancel(false);
                watchdog.shutdownNow();
            }
        }
    }

    @SuppressWarnings("deprecation")
    private static String read(UiAutomation automation, Display display) {
        long deadline = SystemClock.uptimeMillis() + 240;
        do {
            automation.clearCache();
            int rotation = display.getRotation();
            var size = new Point();
            display.getRealSize(size);
            AccessibilityNodeInfo root = automation.getRootInActiveWindow();
            if (root != null && size.x > 0 && size.y > 0) {
                var xml = new StringBuilder(4096);
                xml.append("<hierarchy rotation=\"").append(rotation).append("\">");
                if (!appendNode(root, new Rect(0, 0, size.x, size.y), new Rect(), xml, 0)) return "!unavailable";
                if (rotation == display.getRotation()) return xml.append("</hierarchy>").toString();
            }
            SystemClock.sleep(30);
        } while (SystemClock.uptimeMillis() < deadline);
        return "!unavailable";
    }

    private static boolean appendNode(AccessibilityNodeInfo node, Rect display, Rect bounds, StringBuilder xml, int depth) {
        if (depth == MAX_DEPTH || xml.length() >= MAX_CHARS) return false;
        node.getBoundsInScreen(bounds);
        if (!bounds.intersect(display)) bounds.setEmpty();
        xml.append("<node bounds=\"[").append(bounds.left).append(',').append(bounds.top)
            .append("][").append(bounds.right).append(',').append(bounds.bottom).append("]\"");
        attr(xml, "class", node.getClassName());
        attr(xml, "resource-id", node.getViewIdResourceName());
        attr(xml, "enabled", node.isEnabled() ? "true" : "false");
        attr(xml, "clickable", node.isClickable() ? "true" : "false");
        attr(xml, "checkable", node.isCheckable() ? "true" : "false");
        if (node.isPassword()) {
            attr(xml, "password", "true");
        } else {
            attr(xml, "text", node.getText());
            attr(xml, "content-desc", node.getContentDescription());
        }
        xml.append("/>");
        if (xml.length() >= MAX_CHARS) return false;
        for (int i = 0, count = node.getChildCount(); i < count; i++) {
            AccessibilityNodeInfo child = node.getChild(i);
            if (child != null && child.isVisibleToUser() && !appendNode(child, display, bounds, xml, depth + 1)) return false;
        }
        return true;
    }

    private static void attr(StringBuilder xml, String name, CharSequence value) {
        if (value == null || value.length() == 0 || xml.length() >= MAX_CHARS) return;
        xml.append(' ').append(name).append("=\"");
        for (int i = 0; i < value.length() && xml.length() < MAX_CHARS; i++) {
            char c = value.charAt(i);
            switch (c) {
                case '&': xml.append("&amp;"); break;
                case '<': xml.append("&lt;"); break;
                case '>': xml.append("&gt;"); break;
                case '"': xml.append("&quot;"); break;
                case '\r': xml.append("&#13;"); break;
                case '\n': xml.append("&#10;"); break;
                default: xml.append(c < 32 && c != '\t' ? '\uFFFD' : c);
            }
        }
        xml.append('"');
    }
}
