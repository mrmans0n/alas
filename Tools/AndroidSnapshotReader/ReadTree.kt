@file:JvmName("ReadTree")

package io.nlopez.alas.android

import android.accessibilityservice.AccessibilityServiceInfo
import android.app.UiAutomation
import android.graphics.Point
import android.graphics.Rect
import android.os.Looper
import android.os.SystemClock
import android.view.Display
import android.view.accessibility.AccessibilityNodeInfo
import java.io.IOException
import java.lang.reflect.InvocationTargetException
import java.lang.reflect.Method
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.system.exitProcess

private const val IDLE_MS = 5000L
private const val MAX_CHARS = 256 * 1024
private const val MAX_DEPTH = 128

/** Reads the active default-display tree over the adb shell's private stdio. */
@Suppress("DEPRECATION")
fun main() {
    // app_process doesn't create the looper used by AccessibilityInteractionClient.
    Looper.prepareMainLooper()
    Thread({
        try {
            serve()
            exitProcess(0)
        } catch (_: Exception) {
            // Do not send exception text that could contain screen data.
            exitProcess(1)
        }
    }, "alas-snapshot").start()
    Looper.loop()
}

@Suppress("DEPRECATION")
private fun serve() {
    val requests = ArrayBlockingQueue<Boolean>(1)
    Thread {
        try {
            while (System.`in`.read() == 'r'.code && System.`in`.read() == '\n'.code) {
                requests.put(true)
            }
            requests.put(false)
        } catch (_: IOException) {
            requests.offer(false)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }.apply {
        isDaemon = true
        start()
    }
    if (requests.poll(IDLE_MS, TimeUnit.MILLISECONDS) != true) return

    val automation: UiAutomation
    val connect: Method
    val disconnect: Method
    val display: Display?
    try {
        val connectionType = Class.forName("android.app.IUiAutomationConnection")
        val connection = Class.forName("android.app.UiAutomationConnection").getConstructor().newInstance()
        automation = UiAutomation::class.java.getConstructor(Looper::class.java, connectionType)
            .newInstance(Looper.getMainLooper(), connection)
        connect = UiAutomation::class.java.getMethod("connect", Int::class.javaPrimitiveType)
        disconnect = UiAutomation::class.java.getMethod("disconnect")
        val displays = Class.forName("android.hardware.display.DisplayManagerGlobal")
        display = displays.getMethod("getRealDisplay", Int::class.javaPrimitiveType)
            .invoke(displays.getMethod("getInstance").invoke(null), Display.DEFAULT_DISPLAY) as Display?
    } catch (_: ReflectiveOperationException) {
        System.out.println("!unsupported")
        return
    } catch (_: LinkageError) {
        System.out.println("!unsupported")
        return
    }
    if (display == null) {
        System.out.println("!unavailable")
        return
    }

    // Bound even a framework call that hangs after taking the automation slot.
    val watchdog = Executors.newSingleThreadScheduledExecutor()
    val abort = Runnable { exitProcess(1) }
    val startup = watchdog.schedule(abort, 6, TimeUnit.SECONDS)
    try {
        connect.invoke(automation, UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
    } catch (failure: InvocationTargetException) {
        if (failure.cause?.message?.contains("already registered") == true) {
            System.out.println("!busy")
            return
        }
        throw failure
    }
    try {
        val info = automation.serviceInfo
        val flags = AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS or
            AccessibilityServiceInfo.FLAG_INCLUDE_NOT_IMPORTANT_VIEWS
        if (info.flags and flags != flags) {
            info.flags = info.flags or flags
            automation.serviceInfo = info
        }
        startup.cancel(false)
        do {
            val deadline = watchdog.schedule(abort, 3, TimeUnit.SECONDS)
            try {
                System.out.println(readTree(automation, display))
                if (System.out.checkError()) break
            } finally {
                deadline.cancel(false)
            }
        } while (requests.poll(IDLE_MS, TimeUnit.MILLISECONDS) == true)
    } finally {
        val deadline = watchdog.schedule(abort, 3, TimeUnit.SECONDS)
        try {
            disconnect.invoke(automation)
        } finally {
            deadline.cancel(false)
            watchdog.shutdownNow()
        }
    }
}

@Suppress("DEPRECATION")
private fun readTree(automation: UiAutomation, display: Display): String {
    val deadline = SystemClock.uptimeMillis() + 240
    val size = Point()
    do {
        automation.clearCache()
        val rotation = display.rotation
        display.getRealSize(size)
        val root = automation.rootInActiveWindow
        if (root != null && size.x > 0 && size.y > 0) {
            val xml = StringBuilder(4096)
            xml.append("<hierarchy rotation=\"").append(rotation).append("\">")
            if (!appendNode(root, Rect(0, 0, size.x, size.y), Rect(), xml, 0)) return "!unavailable"
            if (rotation == display.rotation) return xml.append("</hierarchy>").toString()
        }
        SystemClock.sleep(30)
    } while (SystemClock.uptimeMillis() < deadline)
    return "!unavailable"
}

private fun appendNode(node: AccessibilityNodeInfo, display: Rect, bounds: Rect, xml: StringBuilder, depth: Int): Boolean {
    if (depth == MAX_DEPTH || xml.length >= MAX_CHARS) return false
    node.getBoundsInScreen(bounds)
    if (!bounds.intersect(display)) bounds.setEmpty()
    xml.append("<node bounds=\"[").append(bounds.left).append(',').append(bounds.top)
        .append("][").append(bounds.right).append(',').append(bounds.bottom).append("]\"")
    appendAttribute(xml, "class", node.className)
    appendAttribute(xml, "resource-id", node.viewIdResourceName)
    appendAttribute(xml, "enabled", node.isEnabled.toString())
    appendAttribute(xml, "clickable", node.isClickable.toString())
    appendAttribute(xml, "checkable", node.isCheckable.toString())
    if (node.isPassword) {
        appendAttribute(xml, "password", "true")
    } else {
        appendAttribute(xml, "text", node.text)
        appendAttribute(xml, "content-desc", node.contentDescription)
    }
    xml.append("/>")
    if (xml.length >= MAX_CHARS) return false
    for (i in 0 until node.childCount) {
        val child = node.getChild(i)
        if (child != null && child.isVisibleToUser && !appendNode(child, display, bounds, xml, depth + 1)) return false
    }
    return true
}

private fun appendAttribute(xml: StringBuilder, name: String, value: CharSequence?) {
    if (value.isNullOrEmpty() || xml.length >= MAX_CHARS) return
    xml.append(' ').append(name).append("=\"")
    for (i in 0 until value.length) {
        if (xml.length >= MAX_CHARS) break
        when (val c = value[i]) {
            '&' -> xml.append("&amp;")
            '<' -> xml.append("&lt;")
            '>' -> xml.append("&gt;")
            '"' -> xml.append("&quot;")
            '\r' -> xml.append("&#13;")
            '\n' -> xml.append("&#10;")
            else -> xml.append(if (c.code < 32 && c != '\t') '\uFFFD' else c)
        }
    }
    xml.append('"')
}
