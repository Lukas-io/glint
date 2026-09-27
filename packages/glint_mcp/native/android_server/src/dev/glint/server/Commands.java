package dev.glint.server;

import android.app.UiAutomation;
import android.graphics.Rect;
import android.os.Build;
import android.os.Bundle;
import android.os.SystemClock;
import android.view.InputDevice;
import android.view.KeyCharacterMap;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.accessibility.AccessibilityWindowInfo;
import java.util.List;
import org.json.JSONArray;
import org.json.JSONObject;

/** The server's commands; every coordinate is in physical screen pixels. */
final class Commands {
    private final UiAutomation ua;
    private final KeyCharacterMap keyMap = KeyCharacterMap.load(KeyCharacterMap.VIRTUAL_KEYBOARD);

    Commands(UiAutomation ua) {
        this.ua = ua;
    }

    JSONObject run(JSONObject r) throws Exception {
        switch (r.optString("cmd")) {
            case "ping":
                return ok().put("server", Server.PROTOCOL).put("sdk", Build.VERSION.SDK_INT);
            case "tap":
                return touch(r.getDouble("x"), r.getDouble("y"), r.optLong("ms", 40));
            case "longpress":
                return touch(r.getDouble("x"), r.getDouble("y"), r.optLong("ms", 600));
            case "swipe":
                return swipe(r);
            case "text":
                return text(r.getString("text"));
            case "key":
                return key(r.getInt("code"), r.optInt("meta", 0), Math.max(1, r.optInt("count", 1)));
            case "focus":
                return focus();
            case "windows":
                return windows(r.optInt("maxNodes", 3000));
            default:
                return fail("unknownCommand", "no command " + r.optString("cmd"));
        }
    }

    private JSONObject touch(double x, double y, long holdMs) throws Exception {
        long down = SystemClock.uptimeMillis();
        boolean ok = inject(motion(down, MotionEvent.ACTION_DOWN, x, y));
        Thread.sleep(holdMs);
        ok &= inject(motion(down, MotionEvent.ACTION_UP, x, y));
        return ok ? ok() : fail("injectFailed", "the system refused the touch at " + x + "," + y);
    }

    private JSONObject swipe(JSONObject r) throws Exception {
        double x1 = r.getDouble("x1"), y1 = r.getDouble("y1"), x2 = r.getDouble("x2"), y2 = r.getDouble("y2");
        long ms = Math.max(16, r.optLong("ms", 300));
        long holdMs = Math.max(0, r.optLong("holdMs", 0));
        int steps = (int) Math.max(8, ms / 8);
        long down = SystemClock.uptimeMillis();
        boolean ok = inject(motion(down, MotionEvent.ACTION_DOWN, x1, y1));
        for (int i = 1; i <= steps && ok; i++) {
            double t = (double) i / steps;
            ok = inject(motion(down, MotionEvent.ACTION_MOVE, x1 + (x2 - x1) * t, y1 + (y2 - y1) * t));
            Thread.sleep(ms / steps);
        }
        // Resting at the end point drains the velocity tracker, so the lift starts no fling.
        for (long held = 0; held < holdMs && ok; held += 16) {
            ok = inject(motion(down, MotionEvent.ACTION_MOVE, x2, y2));
            Thread.sleep(16);
        }
        ok &= inject(motion(down, MotionEvent.ACTION_UP, x2, y2));
        return ok ? ok() : fail("injectFailed", "the system refused the swipe");
    }

    /** Types through key events when the keyboard map has every character, else sets the focused field's text at its cursor. */
    private JSONObject text(String text) throws Exception {
        KeyEvent[] events = keyMap.getEvents(text.toCharArray());
        if (events != null) {
            for (KeyEvent e : events) {
                if (!inject(KeyEvent.changeTimeRepeat(e, SystemClock.uptimeMillis(), 0))) {
                    return fail("injectFailed", "the system refused a key event");
                }
            }
            return ok().put("via", "keys");
        }
        AccessibilityNodeInfo field = ua.findFocus(AccessibilityNodeInfo.FOCUS_INPUT);
        if (field == null || !field.isEditable()) {
            return fail("noFocusedField", "no focused text field to type non-keyboard characters into");
        }
        String current = field.getText() == null ? "" : field.getText().toString();
        if (field.isShowingHintText()) current = "";
        int start = Math.max(0, Math.min(field.getTextSelectionStart(), current.length()));
        int end = Math.max(start, Math.min(field.getTextSelectionEnd(), current.length()));
        if (field.getTextSelectionStart() < 0) start = end = current.length();
        String next = current.substring(0, start) + text + current.substring(end);
        Bundle args = new Bundle();
        args.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, next);
        if (!field.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)) {
            return fail("setTextFailed", "the focused field refused the text");
        }
        Bundle sel = new Bundle();
        sel.putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, start + text.length());
        sel.putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, start + text.length());
        field.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, sel);
        return ok().put("via", "setText");
    }

    private JSONObject key(int code, int meta, int count) throws Exception {
        for (int i = 0; i < count; i++) {
            long now = SystemClock.uptimeMillis();
            boolean ok = inject(new KeyEvent(now, now, KeyEvent.ACTION_DOWN, code, 0, meta,
                    KeyCharacterMap.VIRTUAL_KEYBOARD, 0, 0, InputDevice.SOURCE_KEYBOARD))
                    && inject(new KeyEvent(now, SystemClock.uptimeMillis(), KeyEvent.ACTION_UP, code, 0, meta,
                    KeyCharacterMap.VIRTUAL_KEYBOARD, 0, 0, InputDevice.SOURCE_KEYBOARD));
            if (!ok) return fail("injectFailed", "the system refused key " + code);
        }
        return ok();
    }

    /** The window that has input focus: its package, title and type. */
    private JSONObject focus() throws Exception {
        for (AccessibilityWindowInfo w : ua.getWindows()) {
            if (!w.isFocused()) continue;
            AccessibilityNodeInfo root = w.getRoot();
            return ok().put("package", root == null || root.getPackageName() == null ? JSONObject.NULL : root.getPackageName().toString())
                    .put("title", w.getTitle() == null ? JSONObject.NULL : w.getTitle().toString())
                    .put("type", windowType(w.getType()));
        }
        return ok().put("package", JSONObject.NULL);
    }

    /** Every window on screen, top first, each with its node tree. */
    private JSONObject windows(int maxNodes) throws Exception {
        JSONArray out = new JSONArray();
        int[] budget = {maxNodes};
        List<AccessibilityWindowInfo> ws = ua.getWindows();
        for (AccessibilityWindowInfo w : ws) {
            Rect b = new Rect();
            w.getBoundsInScreen(b);
            AccessibilityNodeInfo root = w.getRoot();
            JSONObject win = new JSONObject()
                    .put("type", windowType(w.getType()))
                    .put("layer", w.getLayer())
                    .put("focused", w.isFocused())
                    .put("bounds", bounds(b));
            if (w.getTitle() != null) win.put("title", w.getTitle().toString());
            if (root != null && root.getPackageName() != null) win.put("package", root.getPackageName().toString());
            if (root != null) win.put("root", node(root, budget));
            out.put(win);
        }
        return ok().put("windows", out).put("truncated", budget[0] <= 0);
    }

    private JSONObject node(AccessibilityNodeInfo n, int[] budget) throws Exception {
        budget[0]--;
        Rect r = new Rect();
        n.getBoundsInScreen(r);
        JSONObject o = new JSONObject().put("bounds", bounds(r));
        if (n.getClassName() != null) o.put("class", n.getClassName().toString());
        if (n.getText() != null && n.getText().length() > 0) o.put("text", n.getText().toString());
        if (n.getContentDescription() != null && n.getContentDescription().length() > 0) o.put("desc", n.getContentDescription().toString());
        if (n.getViewIdResourceName() != null) o.put("id", n.getViewIdResourceName());
        if (n.isClickable()) o.put("clickable", true);
        if (n.isEditable()) o.put("editable", true);
        if (n.isFocused()) o.put("focused", true);
        if (n.isCheckable()) o.put("checked", n.isChecked());
        if (n.isSelected()) o.put("selected", true);
        if (!n.isEnabled()) o.put("enabled", false);
        if (n.isScrollable()) o.put("scrollable", true);
        JSONArray kids = new JSONArray();
        for (int i = 0; i < n.getChildCount() && budget[0] > 0; i++) {
            AccessibilityNodeInfo c = n.getChild(i);
            if (c != null) kids.put(node(c, budget));
        }
        if (kids.length() > 0) o.put("children", kids);
        return o;
    }

    private static JSONArray bounds(Rect r) {
        return new JSONArray().put(r.left).put(r.top).put(r.right).put(r.bottom);
    }

    private static String windowType(int type) {
        switch (type) {
            case AccessibilityWindowInfo.TYPE_APPLICATION: return "application";
            case AccessibilityWindowInfo.TYPE_INPUT_METHOD: return "inputMethod";
            case AccessibilityWindowInfo.TYPE_SYSTEM: return "system";
            case AccessibilityWindowInfo.TYPE_ACCESSIBILITY_OVERLAY: return "accessibilityOverlay";
            case AccessibilityWindowInfo.TYPE_SPLIT_SCREEN_DIVIDER: return "splitScreenDivider";
            default: return "type" + type;
        }
    }

    private MotionEvent motion(long down, int action, double x, double y) {
        MotionEvent.PointerProperties[] pp = {new MotionEvent.PointerProperties()};
        pp[0].id = 0;
        pp[0].toolType = MotionEvent.TOOL_TYPE_FINGER;
        MotionEvent.PointerCoords[] pc = {new MotionEvent.PointerCoords()};
        pc[0].x = (float) x;
        pc[0].y = (float) y;
        pc[0].pressure = 1;
        pc[0].size = 1;
        return MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, 1, pp, pc, 0, 0, 1, 1, 0, 0,
                InputDevice.SOURCE_TOUCHSCREEN, 0);
    }

    private boolean inject(android.view.InputEvent e) {
        return ua.injectInputEvent(e, true);
    }

    private static JSONObject ok() throws Exception {
        return new JSONObject().put("ok", true);
    }

    private static JSONObject fail(String kind, String detail) throws Exception {
        return new JSONObject().put("ok", false).put("error", kind).put("detail", detail);
    }
}
