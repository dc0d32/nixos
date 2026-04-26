import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Layouts

import ".."

RowLayout {
  id: root
  spacing: 4

  property string temp: "—"
  property string code: "cloud"
  property bool loading: true
  property string location: ""

  Process {
    id: locFetcher
    command: ["curl", "-s", "https://ipapi.co/json/"]
    running: true
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          const j = JSON.parse(text)
          if (j.latitude && j.longitude) {
            root.location = j.city || ""
            fetchWeather(j.latitude, j.longitude)
          } else {
            defaultWeather()
          }
        } catch (e) {
          defaultWeather()
        }
      }
    }
  }

  function fetchWeather(lat, lon) {
    root.loading = true
    root.lat = lat
    root.lon = lon
    weatherFetcher.command = [
      "curl", "-s",
      "https://api.open-meteo.com/v1/forecast?latitude=" + lat
      + "&longitude=" + lon
      + "&current=temperature_2m,weather_code"
    ]
    weatherFetcher.running = true
  }

  property real lat: 0
  property real lon: 0

  function defaultWeather() {
    fetchWeather(47.62, -122.04)
  }

  Process {
    id: weatherFetcher
    command: ["true"]
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          const j = JSON.parse(text)
          if (j.current) {
            root.temp = Math.round(j.current.temperature_2m) + "°"
            const wcode = j.current.weather_code
            root.code = wcode === 0 ? "sunny"
                : wcode <= 3 ? "cloud"
                : wcode <= 48 ? "foggy"
                : wcode <= 67 ? "rainy"
                : wcode <= 82 ? "snowy"
                : "thunderstorm"
          }
        } catch (e) { console.log("weather parse error:", e) }
        root.loading = false
      }
    }
  }

  Timer {
    id: updateTimer
    interval: 900000
    running: true
    repeat: true
    onTriggered: {
      if (root.lat && root.lon) {
        fetchWeather(root.lat, root.lon)
      } else {
        defaultWeather()
      }
    }
  }

  Text {
    font.family: Theme.iconFont
    font.pixelSize: 16
    color: Theme.sky
    text: root.code
  }

  Text {
    font.family: Theme.font
    font.pixelSize: 12
    color: Theme.subtext
    text: root.temp
    visible: !root.loading
  }

  Text {
    font.family: Theme.font
    font.pixelSize: 12
    color: Theme.subtext
    text: "…"
    visible: root.loading
  }
}