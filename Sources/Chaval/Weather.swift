import SwiftUI
import CoreLocation

/// Current weather and the next days from Open-Meteo (free, no account or key), for where the Mac is (Location
/// Services; the coordinates are rounded to ~1 km before they're sent). Refreshed every 30 minutes; the last reading
/// is kept so the card fills in at once.
final class Weather: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = Weather()

    struct Day: Codable, Identifiable { let date: Date; let code: Int; let high: Double; let low: Double; var id: Date { date } }
    struct Report: Codable {
        let temp: Double, feels: Double, code: Int, day: Bool, humidity: Double, wind: Double
        let high: Double, low: Double, days: [Day], place: String, unit: String, at: Date
    }

    @Published private(set) var report: Report? = UserDefaults.standard.data(forKey: "weather").flatMap { try? JSONDecoder().decode(Report.self, from: $0) }
    @Published private(set) var needsLocation = false
    private let location = CLLocationManager()
    private var timer: Timer?, fetching = false

    override init() {
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// Called when the dashboard shows: refreshes if the reading is older than 30 minutes.
    func start() {
        if timer == nil { timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in self?.refresh() } }
        if (report?.at.timeIntervalSinceNow ?? -9999) < -1800 { refresh() }
    }

    func refresh() {
        switch location.authorizationStatus {
        case .notDetermined: location.requestWhenInUseAuthorization()
        case .denied, .restricted: needsLocation = true
        default: needsLocation = false; location.requestLocation()
        }
    }

    func askForLocation() {
        if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
        else { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!) }
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        DispatchQueue.main.async { self.refresh() }
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let loc = locs.last, !fetching else { return }
        fetching = true
        let lat = (loc.coordinate.latitude * 100).rounded() / 100, lon = (loc.coordinate.longitude * 100).rounded() / 100
        let us = Locale.current.measurementSystem == .us
        var q = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        q.queryItems = [
            .init(name: "latitude", value: "\(lat)"), .init(name: "longitude", value: "\(lon)"),
            .init(name: "current", value: "temperature_2m,apparent_temperature,weather_code,is_day,relative_humidity_2m,wind_speed_10m"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min"),
            .init(name: "timezone", value: "auto"), .init(name: "forecast_days", value: "6"),
            .init(name: "temperature_unit", value: us ? "fahrenheit" : "celsius"), .init(name: "wind_speed_unit", value: us ? "mph" : "kmh"),
        ]
        // The place name comes from Apple's geocoder, alongside.
        CLGeocoder().reverseGeocodeLocation(loc) { [weak self] marks, _ in
            let place = marks?.first.flatMap { $0.locality ?? $0.subAdministrativeArea ?? $0.name } ?? ""
            URLSession.shared.dataTask(with: q.url!) { data, _, _ in
                defer { DispatchQueue.main.async { self?.fetching = false } }
                guard let data, let r = Weather.parse(data, place: place, unit: us ? "°F" : "°C") else { return }
                DispatchQueue.main.async {
                    self?.report = r
                    UserDefaults.standard.set(try? JSONEncoder().encode(r), forKey: "weather")
                }
            }.resume()
        }
    }

    private static func parse(_ data: Data, place: String, unit: String) -> Report? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let c = j["current"] as? [String: Any], let d = j["daily"] as? [String: Any],
              let times = d["time"] as? [String], let codes = d["weather_code"] as? [Int],
              let highs = d["temperature_2m_max"] as? [Double], let lows = d["temperature_2m_min"] as? [Double] else { return nil }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let days = times.indices.compactMap { i -> Day? in
            guard let date = f.date(from: times[i]), codes.indices.contains(i), highs.indices.contains(i), lows.indices.contains(i) else { return nil }
            return Day(date: date, code: codes[i], high: highs[i], low: lows[i])
        }
        func n(_ k: String) -> Double { (c[k] as? Double) ?? Double(c[k] as? Int ?? 0) }
        return Report(temp: n("temperature_2m"), feels: n("apparent_temperature"), code: c["weather_code"] as? Int ?? 0, day: (c["is_day"] as? Int ?? 1) == 1,
                      humidity: n("relative_humidity_2m"), wind: n("wind_speed_10m"), high: days.first?.high ?? 0, low: days.first?.low ?? 0,
                      days: Array(days.dropFirst()), place: place, unit: unit, at: Date())
    }

    /// WMO weather code → SF Symbol and words.
    static func describe(_ code: Int, day: Bool = true) -> (symbol: String, text: String) {
        switch code {
        case 0: return (day ? "sun.max.fill" : "moon.stars.fill", "Clear")
        case 1: return (day ? "sun.min.fill" : "moon.fill", "Mostly clear")
        case 2: return (day ? "cloud.sun.fill" : "cloud.moon.fill", "Partly cloudy")
        case 3: return ("cloud.fill", "Overcast")
        case 45, 48: return ("cloud.fog.fill", "Fog")
        case 51, 53, 55, 56, 57: return ("cloud.drizzle.fill", "Drizzle")
        case 61, 63, 66: return ("cloud.rain.fill", "Rain")
        case 65, 67: return ("cloud.heavyrain.fill", "Heavy rain")
        case 71, 73, 75, 77: return ("cloud.snow.fill", "Snow")
        case 80, 81, 82: return (day ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill", "Showers")
        case 85, 86: return ("cloud.snow.fill", "Snow showers")
        case 95, 96, 99: return ("cloud.bolt.rain.fill", "Thunderstorms")
        default: return ("cloud.fill", "—")
        }
    }
}

/// The dashboard's weather card: now, today's range, feels-like / humidity / wind, and the next five days. Stretches to
/// whatever height it's given, spreading the days out.
struct WeatherCard: View {
    let s: DashStyle
    @ObservedObject var w = Weather.shared

    var body: some View {
        s.card {
            if let r = w.report {
                let now = Weather.describe(r.code, day: r.day)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: now.symbol).symbolRenderingMode(.multicolor).font(.system(size: 34))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(Int(r.temp.rounded()))\(r.unit)").font(s.font(28, .bold)).foregroundStyle(s.accent)
                            Text(now.text).font(s.font(11, .medium))
                        }
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 2) {
                            if !r.place.isEmpty { Label(r.place, systemImage: "location.fill").font(s.font(10, .semibold)).lineLimit(1) }
                            Text("H \(Int(r.high.rounded()))°  L \(Int(r.low.rounded()))°").font(s.font(10)).opacity(0.7)
                        }
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 0) {
                        stat("thermometer.medium", "\(Int(r.feels.rounded()))°").help("Feels like")
                        stat("humidity.fill", "\(Int(r.humidity.rounded()))%")
                        stat("wind", "\(Int(r.wind.rounded())) \(r.unit == "°F" ? "mph" : "km/h")")
                    }
                    Spacer(minLength: 8)
                    VStack(spacing: 0) {
                        ForEach(r.days.prefix(5)) { d in
                            let x = Weather.describe(d.code)
                            HStack(spacing: 8) {
                                Text(d.date.formatted(.dateTime.weekday(.abbreviated))).font(s.font(11, .semibold)).frame(width: 34, alignment: .leading)
                                Image(systemName: x.symbol).symbolRenderingMode(.multicolor).font(.system(size: 13)).frame(width: 22).help(x.text)
                                Spacer(minLength: 4)
                                Text("\(Int(d.low.rounded()))°").font(s.font(11)).opacity(0.6).monospacedDigit()
                                Text("\(Int(d.high.rounded()))°").font(s.font(11, .bold)).monospacedDigit().frame(width: 30, alignment: .trailing)
                            }
                            .frame(maxHeight: .infinity) // the days share the card's height
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "cloud.sun.fill").symbolRenderingMode(.multicolor).font(.system(size: 30))
                    Text(w.needsLocation ? "Chaval needs Location to know where you are." : "Getting the weather…").font(s.font(11)).opacity(0.7)
                        .multilineTextAlignment(.center)
                    if w.needsLocation { s.pill("Allow Location", symbol: "location.fill", on: true) { w.askForLocation() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
        .onAppear { w.start() }
    }

    private func stat(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).font(s.font(10, .medium)).opacity(0.8).frame(maxWidth: .infinity, alignment: .leading)
    }
}
