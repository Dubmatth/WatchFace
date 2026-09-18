import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.Position;
import Toybox.System;
import Toybox.Time;
import Toybox.Time.Gregorian;
import Toybox.WatchUi;
import Toybox.Weather;

// Colors lifted from the approved mockup (oklch -> nearest sRGB hex).
const COLOR_BG = 0x0F0D0A;
const COLOR_TEXT = 0xF5F2EC;
const COLOR_MUTED = 0x9C9891;
const COLOR_ACCENT = 0xD97A3F;   // burnt orange
const COLOR_OLIVE = 0x7C8F5A;
const COLOR_TICK_DIM = 0x3A362E;

class WatchFaceView extends WatchUi.WatchFace {

    private var _isSleeping as Boolean = false;
    private var _fontCache as Dictionary = {};

    // Slow-changing data (date, battery, temperature, altitude, sunrise/
    // sunset) is refreshed only every SLOW_REFRESH_INTERVAL onUpdate calls
    // (roughly that many seconds while the screen is awake) instead of on
    // every single frame - none of it needs 1Hz freshness. Heading is the
    // one exception and stays live every frame (see onUpdate).
    private const SLOW_REFRESH_INTERVAL = 30;
    private var _slowRefreshCounter as Number = 0;
    private var _cachedDateText as String = "";
    private var _cachedBatteryText as String = "";
    private var _cachedTempText as String = "";
    private var _cachedAltitudeText as String = "--";
    private var _cachedSunTimes as Array<String> = ["--:--", "--:--"];
    // The bezel ring and cardinal letters never change between frames, so
    // they're pre-rendered once here instead of being redrawn (120 line
    // segments + trig) on every onUpdate - same technique as Garmin's own
    // Analog sample watch face.
    private var _bezelBuffer as Graphics.BufferedBitmap?;

    function initialize() {
        WatchFace.initialize();
    }

    function onLayout(dc as Dc) as Void {
        var width = dc.getWidth();
        var height = dc.getHeight();
        var buffer = Graphics.createBufferedBitmap({ :width => width, :height => height }).get() as Graphics.BufferedBitmap;
        var bufferDc = buffer.getDc();

        bufferDc.setColor(COLOR_TEXT, COLOR_BG);
        bufferDc.clear();
        drawBezel(bufferDc, width / 2, height / 2);
        drawCardinalLetters(bufferDc, width / 2, height / 2);

        _bezelBuffer = buffer;
    }

    // RobotoCondensed{Bold,Regular} are the closest system TrueType faces to
    // the mockup's Oswald (verified available on fenix9pro51mm). Cached per
    // (face, size) since getVectorFont() is not free to call every frame;
    // falls back to a built-in bitmap font if the face is missing on a
    // device variant (e.g. a future product) that doesn't ship it.
    private function getFont(face as String, size as Number, fallback as Graphics.FontDefinition) as Graphics.FontDefinition {
        var key = face + ":" + size.toString();
        if (_fontCache.hasKey(key)) {
            return _fontCache[key];
        }
        var font = Graphics.getVectorFont({ :face => face, :size => size });
        if (font == null) {
            font = fallback;
        }
        _fontCache[key] = font;
        return font;
    }

    private function boldFont(size as Number) as Graphics.FontDefinition {
        return getFont("RobotoCondensedBold", size, Graphics.FONT_TINY);
    }

    private function regularFont(size as Number) as Graphics.FontDefinition {
        return getFont("RobotoCondensedRegular", size, Graphics.FONT_XTINY);
    }

    function onEnterSleep() as Void {
        _isSleeping = true;
        WatchUi.requestUpdate();
    }

    function onExitSleep() as Void {
        _isSleeping = false;
        WatchUi.requestUpdate();
    }

    function onUpdate(dc as Dc) as Void {
        var width = dc.getWidth();
        var height = dc.getHeight();
        var cx = width / 2;
        var cy = height / 2;

        var settings = System.getDeviceSettings();
        var burnInRisk = settings.requiresBurnInProtection;

        // In always-on / burn-in-risk sleep, draw a minimal, low-luminance
        // face: time only, no bezel, no fine detail. Everything else below
        // only renders when awake (or the device has no burn-in risk).
        if (_isSleeping && burnInRisk) {
            dc.setColor(COLOR_TEXT, COLOR_BG);
            dc.clear();
            drawTime(dc, cx, cy, COLOR_MUTED, settings);
            return;
        }

        // The static ring + cardinal letters come from the pre-rendered
        // buffer (see onLayout) - this single blit replaces a clear() plus
        // ~120 line draws every second.
        if (_bezelBuffer != null) {
            dc.drawBitmap(0, 0, _bezelBuffer);
        } else {
            dc.setColor(COLOR_TEXT, COLOR_BG);
            dc.clear();
            drawBezel(dc, cx, cy);
            drawCardinalLetters(dc, cx, cy);
        }

        // One Position fix per frame, reused everywhere instead of each
        // helper querying it again. Heading is drawn live every frame;
        // everything else derived from posInfo (altitude, sunrise/sunset)
        // only actually gets used when the slow-refresh cycle fires below.
        var posInfo = Position.getInfo();
        var headingRad = (posInfo != null) ? posInfo.heading : null;

        if (_slowRefreshCounter == 0) {
            refreshSlowData(posInfo, settings);
        }
        _slowRefreshCounter = (_slowRefreshCounter + 1) % SLOW_REFRESH_INTERVAL;

        drawHeadingMarker(dc, cx, cy, headingRad);
        drawDate(dc, cx, cy);
        drawTime(dc, cx, cy, COLOR_TEXT, settings);
        drawSubRow(dc, cx, cy, headingRad);
        drawDivider(dc, cx, cy);
        drawComplications(dc, cx, cy);
    }

    // Recomputes everything that doesn't need 1Hz freshness. Called at most
    // once every SLOW_REFRESH_INTERVAL onUpdate calls.
    private function refreshSlowData(posInfo as Position.Info?, settings as System.DeviceSettings) as Void {
        var today = Gregorian.info(Time.now(), Time.FORMAT_MEDIUM);
        _cachedDateText = Lang.format("$1$ $2$ $3$", [today.day_of_week, today.day, today.month]).toUpper();

        var battery = System.getSystemStats().battery;
        _cachedBatteryText = (battery != null) ? Lang.format("$1$%", [battery.toNumber()]) : "";

        var temp = getTemperatureCelsius();
        _cachedTempText = (temp != null) ? formatTemperature(temp, settings) : "";

        var altitude = (posInfo != null) ? posInfo.altitude : null;
        _cachedAltitudeText = (altitude != null) ? formatAltitude(altitude, settings) : "--";

        var location = (posInfo != null) ? posInfo.position : null;
        _cachedSunTimes = getSunriseSunsetLabels(location);
    }

    // -- Bezel: a faint base ring (continuous texture, like the mockup's
    // soft gradient) plus 120 minor ticks every 3 deg, majors every 30 deg.
    private function drawBezel(dc as Dc, cx as Number, cy as Number) as Void {
        var rOuter = 220;
        var minorLen = 5;
        var majorLen = 11;

        dc.setColor(COLOR_TICK_DIM, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(1);
        dc.drawCircle(cx, cy, rOuter - 3);

        for (var i = 0; i < 120; i += 1) {
            var isMajor = (i % 10 == 0);
            var angleRad = Math.toRadians(i * 3.0);
            var len = isMajor ? majorLen : minorLen;
            var rInner = rOuter - len;

            var x1 = cx + rInner * Math.sin(angleRad);
            var y1 = cy - rInner * Math.cos(angleRad);
            var x2 = cx + rOuter * Math.sin(angleRad);
            var y2 = cy - rOuter * Math.cos(angleRad);

            dc.setColor(isMajor ? COLOR_ACCENT : COLOR_TICK_DIM, Graphics.COLOR_TRANSPARENT);
            dc.setPenWidth(isMajor ? 2 : 1);
            dc.drawLine(x1, y1, x2, y2);
        }
    }

    // -- Compass rose N/E/S/O labels: static, pre-rendered into _bezelBuffer --
    private function drawCardinalLetters(dc as Dc, cx as Number, cy as Number) as Void {
        var r = 195;
        var cardinalFont = boldFont(22);

        dc.setColor(COLOR_ACCENT, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, cy - r, cardinalFont, "N", Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        dc.setColor(COLOR_MUTED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx + r, cy, cardinalFont, "E", Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(cx, cy + r, cardinalFont, "S", Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(cx - r, cy, cardinalFont, "O", Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // The only dynamic part of the compass rose - drawn live every frame,
    // on top of the static bezel buffer.
    private function drawHeadingMarker(dc as Dc, cx as Number, cy as Number, headingRad as Float?) as Void {
        if (headingRad == null) {
            return;
        }

        var rTip = 225;
        var rBase = 215;
        var halfWidthRad = Math.toRadians(1.8);

        var tipX = cx + rTip * Math.sin(headingRad);
        var tipY = cy - rTip * Math.cos(headingRad);
        var baseLX = cx + rBase * Math.sin(headingRad - halfWidthRad);
        var baseLY = cy - rBase * Math.cos(headingRad - halfWidthRad);
        var baseRX = cx + rBase * Math.sin(headingRad + halfWidthRad);
        var baseRY = cy - rBase * Math.cos(headingRad + halfWidthRad);

        dc.setColor(COLOR_ACCENT, Graphics.COLOR_TRANSPARENT);
        dc.fillPolygon([
            [tipX, tipY],
            [baseLX, baseLY],
            [baseRX, baseRY],
        ]);
    }

    private function drawDate(dc as Dc, cx as Number, cy as Number) as Void {
        dc.setColor(COLOR_MUTED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, cy - 149, regularFont(20), _cachedDateText, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    private function drawTime(dc as Dc, cx as Number, cy as Number, color as Number, settings as System.DeviceSettings) as Void {
        var clockTime = System.getClockTime();
        var hour = clockTime.hour;
        if (!settings.is24Hour) {
            hour = hour % 12;
            if (hour == 0) {
                hour = 12;
            }
        }
        var text = Lang.format("$1$:$2$", [hour.format("%02d"), clockTime.min.format("%02d")]);
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, cy, boldFont(112), text, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // Heading label is the one live piece here (redrawn from the current
    // frame's heading, not the cache) - battery/temp come from the slow
    // refresh cache.
    private function drawSubRow(dc as Dc, cx as Number, cy as Number, headingRad as Float?) as Void {
        var y = cy + 68;
        var parts = [] as Array<String>;

        if (headingRad != null) {
            parts.add(headingToCompassLabel(headingRad));
        }
        if (!_cachedBatteryText.equals("")) {
            parts.add(_cachedBatteryText);
        }
        if (!_cachedTempText.equals("")) {
            parts.add(_cachedTempText);
        }

        var text = joinWithDot(parts);
        dc.setColor(COLOR_TEXT, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, y, regularFont(20), text, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    private function drawDivider(dc as Dc, cx as Number, cy as Number) as Void {
        var y = cy + 96;
        dc.setColor(COLOR_ACCENT, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(2);
        dc.drawLine(cx - 45, y, cx + 45, y);
    }

    private function drawComplications(dc as Dc, cx as Number, cy as Number) as Void {
        var y = cy + 148;
        var gap = 96;

        drawChip(dc, cx - gap / 2, y, _cachedAltitudeText, "ALT");
        drawChip(dc, cx + gap / 2, y, _cachedSunTimes[0], _cachedSunTimes[1]);
    }

    private function drawChip(dc as Dc, x as Number, y as Number, valueText as String, subText as String) as Void {
        var valueFont = boldFont(24);
        var subFont = regularFont(18);
        var valueHeight = dc.getFontHeight(valueFont);
        var subHeight = dc.getFontHeight(subFont);
        var gap = 2;

        var valueY = y - valueHeight / 2 - gap / 2;
        var subY = y + subHeight / 2 + gap / 2;

        dc.setColor(COLOR_TEXT, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, valueY, valueFont, valueText, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(COLOR_MUTED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, subY, subFont, subText, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // -- Data sources ----------------------------------------------------
    // These read live sensor/weather data and degrade to null when the
    // device has no fix / no cached data yet - not yet verified against a
    // real simulator run, see handover notes.

    // -- Unit formatting --------------------------------------------------
    // Respects the user's device settings (Metric/Statute) rather than
    // hardcoding units - required for a store submission, and elevation
    // and temperature are independent settings on Garmin devices.

    private function formatTemperature(celsius as Float, settings as System.DeviceSettings) as String {
        if (settings.temperatureUnits == System.UNIT_STATUTE) {
            var fahrenheit = celsius * 9.0 / 5.0 + 32.0;
            return Lang.format("$1$°F", [fahrenheit.toNumber()]);
        }
        return Lang.format("$1$°C", [celsius.toNumber()]);
    }

    private function formatAltitude(meters as Float, settings as System.DeviceSettings) as String {
        if (settings.elevationUnits == System.UNIT_STATUTE) {
            var feet = meters * 3.28084;
            return Lang.format("$1$ft", [feet.toNumber()]);
        }
        return Lang.format("$1$m", [meters.toNumber()]);
    }

    private function getTemperatureCelsius() as Float? {
        var conditions = Weather.getCurrentConditions();
        if (conditions != null && conditions.temperature != null) {
            return conditions.temperature.toFloat();
        }
        return null;
    }

    private function getSunriseSunsetLabels(location as Position.Location?) as Array<String> {
        if (location == null) {
            return ["--:--", "--:--"];
        }
        var sunrise = Weather.getSunrise(location, Time.today());
        var sunset = Weather.getSunset(location, Time.today());
        if (sunrise == null || sunset == null) {
            return ["--:--", "--:--"];
        }
        return [formatMomentAsTime(sunrise), formatMomentAsTime(sunset)];
    }

    private function formatMomentAsTime(moment as Time.Moment) as String {
        var info = Gregorian.info(moment, Time.FORMAT_SHORT);
        return Lang.format("$1$:$2$", [info.hour.format("%02d"), info.min.format("%02d")]);
    }

    private function headingToCompassLabel(headingRad as Float) as String {
        var deg = Math.toDegrees(headingRad).toNumber() % 360;
        if (deg < 0) {
            deg += 360;
        }
        var labels = ["N", "NE", "E", "SE", "S", "SO", "O", "NO"];
        var index = ((deg + 22) / 45).toNumber() % 8;
        return Lang.format("$1$° $2$", [deg.format("%03d"), labels[index]]);
    }

    private function joinWithDot(parts as Array<String>) as String {
        var text = "";
        for (var i = 0; i < parts.size(); i += 1) {
            if (i > 0) {
                text += "  ·  ";
            }
            text += parts[i];
        }
        return text;
    }

}
