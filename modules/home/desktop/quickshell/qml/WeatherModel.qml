// Shared weather state. Fetches on startup and every 15 min.
// Both Weather.qml (bar chip) and WeatherFlyout read from here — no double fetch.
pragma Singleton
import Quickshell
import Quickshell.Io
import QtQuick

QtObject {
  id: root

  property string temp:          "—"
  property string code:          "cloud"       // icon name
  property string conditionText: "Unknown"     // human-readable
  property string location:      ""
  property bool   loading:       true
  property real   lat:           0
  property real   lon:           0

  // 3-day forecast: [{day, code, iconName, high, low}]
  property var dailyForecast: []

  // --- geolocation ---
  property var _locProc: Process {
    command: ["curl", "-s", "https://ipapi.co/json/"]
    running: true
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          const j = JSON.parse(text)
          if (j.latitude && j.longitude) {
            root.location = j.city || ""
            root._fetch(j.latitude, j.longitude)
          } else {
            root._fetch(47.62, -122.04)
          }
        } catch(e) {
          root._fetch(47.62, -122.04)
        }
      }
    }
  }

  function _fetch(la, lo) {
    root.loading = true
    root.lat = la
    root.lon = lo
    _weatherProc.command = [
      "curl", "-s",
      "https://api.open-meteo.com/v1/forecast"
      + "?latitude=" + la
      + "&longitude=" + lo
      + "&current=temperature_2m,weather_code"
      + "&daily=weather_code,temperature_2m_max,temperature_2m_min"
      + "&timezone=auto"
      + "&forecast_days=4"
    ]
    _weatherProc.running = true
  }

  function _codeToIcon(wcode) {
    return wcode === 0 ? "sunny"
         : wcode <= 3  ? "cloud"
         : wcode <= 48 ? "foggy"
         : wcode <= 67 ? "rainy"
         : wcode <= 82 ? "snowy"
         : "thunderstorm"
  }

  function _codeToText(wcode) {
    return wcode === 0 ? "Clear sky"
         : wcode === 1 ? "Mainly clear"
         : wcode === 2 ? "Partly cloudy"
         : wcode === 3 ? "Overcast"
         : wcode <= 48 ? "Foggy"
         : wcode <= 55 ? "Drizzle"
         : wcode <= 67 ? "Rainy"
         : wcode <= 77 ? "Snowy"
         : wcode <= 82 ? "Rain showers"
         : wcode <= 86 ? "Snow showers"
         : "Thunderstorm"
  }

  property var _weatherProc: Process {
    command: ["true"]
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          const j = JSON.parse(text)
          if (j.current) {
            root.temp = Math.round(j.current.temperature_2m) + "°"
            const wc = j.current.weather_code
            root.code = root._codeToIcon(wc)
            root.conditionText = root._codeToText(wc)
          }
          if (j.daily && j.daily.time) {
            const days = ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"]
            const fc = []
            // skip index 0 (today), take next 3
            for (let i = 1; i <= 3 && i < j.daily.time.length; i++) {
              const d = new Date(j.daily.time[i] + "T12:00:00")
              fc.push({
                day:      days[d.getDay()],
                code:     j.daily.weather_code[i],
                iconName: root._codeToIcon(j.daily.weather_code[i]),
                high:     Math.round(j.daily.temperature_2m_max[i]),
                low:      Math.round(j.daily.temperature_2m_min[i])
              })
            }
            root.dailyForecast = fc
          }
        } catch(e) { console.log("WeatherModel parse error:", e) }
        root.loading = false
      }
    }
  }

  property var _refreshTimer: Timer {
    interval: 900000
    running: true
    repeat: true
    onTriggered: {
      if (root.lat && root.lon) root._fetch(root.lat, root.lon)
      else root._locProc.running = true
    }
  }
}
