import SwiftUI
import WokintoshCore

struct WeatherWidgetSettings: View {
    @ObservedObject var store: DashboardStore
    let widget: DashboardWidget
    @State private var query = ""
    @State private var places: [PlaceResult] = []
    @State private var searchError: String?
    @State private var searching = false

    var body: some View {
        Form {
            Section("Location for this widget") {
                LabeledContent("Selected location") {
                    Text(widget.weatherOptions.place.isEmpty ? "None" : widget.weatherOptions.place).textSelection(.enabled)
                }
                HStack {
                    TextField("City or place", text: $query).onSubmit { search() }
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Search for this widget’s weather location")
                    Button(searching ? "Searching…" : "Search") { search() }
                        .disabled(searching || query.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
                }
                if !places.isEmpty {
                    List(places) { place in
                        Button { select(place) } label: {
                            HStack {
                                Text(place.label)
                                Spacer()
                                Image(systemName: "plus.circle")
                            }.contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Use \(place.label) for this weather widget")
                    }.frame(height: 155).accessibilityLabel("Matching weather locations")
                }
                if let searchError {
                    Text(searchError).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
                Text("Each Weather widget has its own location and units.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Temperature") {
                Picker("Units", selection: Binding(
                    get: { widget.weatherOptions.fahrenheit },
                    set: { fahrenheit in
                        store.change(widget.id) { $0.weatherOptions.fahrenheit = fahrenheit }
                        refreshWeather()
                    }
                )) {
                    Text("Celsius (°C)").tag(false)
                    Text("Fahrenheit (°F)").tag(true)
                }
                Text(store.native.weather(for: widget).status).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Link("Weather by Open-Meteo", destination: URL(string: "https://open-meteo.com/")!)
                    Text("•").foregroundStyle(.secondary)
                    Link("Place names by GeoNames", destination: URL(string: "https://www.geonames.org/")!)
                }.font(.caption)
            }
        }.formStyle(.grouped)
    }

    private func search() {
        guard !searching, query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else { return }
        searching = true
        searchError = nil
        Task {
            do {
                places = try await store.native.searchPlaces(query: query)
                if places.isEmpty { searchError = "No places found. Try a nearby city or another spelling." }
            } catch {
                searchError = error.localizedDescription
            }
            searching = false
        }
    }

    private func select(_ place: PlaceResult) {
        store.change(widget.id) {
            $0.weatherOptions.place = place.label
            $0.weatherOptions.latitude = place.latitude
            $0.weatherOptions.longitude = place.longitude
        }
        places = []
        searchError = nil
        refreshWeather()
    }

    private func refreshWeather() {
        Task { await store.native.refresh(document: store.document) }
    }
}
