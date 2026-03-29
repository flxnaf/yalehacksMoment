import CoreLocation
import GoogleMaps
import SwiftUI
import UIKit

private struct RouteDebugMapOverlaySnapshot: Equatable {
    let checkpointCount: Int
    let pingCount: Int
    let targetIndex: Int
    let isNavigating: Bool
    let showDots: Bool
    let showArrows: Bool
    let showRings: Bool
    let firstLat: Double?
    let firstLon: Double?
}

/// Read-only map of `NavigationController` checkpoints, ping targets, and live location (dev / demo).
struct RouteDebugMapView: View {
    @ObservedObject var navController: NavigationController
    @ObservedObject private var locationManager = LocationManager.shared
    @State private var showCheckpointDots = true
    @State private var showBearingArrows = false
    @State private var showGeofenceRings = true
    /// Bumped on tab appear so map overlays rebuild after switching away from Route.
    @State private var overlayRefreshEpoch = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("Dots", isOn: $showCheckpointDots)
                    .font(.caption)
                Toggle("Arrows", isOn: $showBearingArrows)
                    .font(.caption)
                Toggle("Rings", isOn: $showGeofenceRings)
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)

            Text("Markers: numbered stops in order · Goal = destination. Rings: green 8m arrival · purple 40m final zone · indigo 25m reroute at you.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)

            RouteDebugMapRepresentable(
                navController: navController,
                locationManager: locationManager,
                showCheckpointDots: showCheckpointDots,
                showBearingArrows: showBearingArrows,
                showGeofenceRings: showGeofenceRings,
                overlayRefreshEpoch: overlayRefreshEpoch
            )
            .ignoresSafeArea(edges: .bottom)
        }
        .onAppear { overlayRefreshEpoch += 1 }
        .navigationTitle("Route debug")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct RouteDebugMapRepresentable: UIViewRepresentable {
    @ObservedObject var navController: NavigationController
    @ObservedObject var locationManager: LocationManager
    var showCheckpointDots: Bool
    var showBearingArrows: Bool
    var showGeofenceRings: Bool
    var overlayRefreshEpoch: Int

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> GMSMapView {
        let camera = GMSCameraPosition.camera(
            withLatitude: 41.3083,
            longitude: -72.9279,
            zoom: 16
        )
        let mapView = GMSMapView(frame: .zero, camera: camera)
        mapView.isMyLocationEnabled = true
        mapView.settings.compassButton = true
        mapView.settings.myLocationButton = true
        mapView.delegate = context.coordinator
        context.coordinator.mapView = mapView
        return mapView
    }

    func updateUIView(_ mapView: GMSMapView, context: Context) {
        if context.coordinator.appliedOverlayRefreshEpoch != overlayRefreshEpoch {
            context.coordinator.appliedOverlayRefreshEpoch = overlayRefreshEpoch
            context.coordinator.lastSnapshot = nil
        }
        let snap = RouteDebugMapOverlaySnapshot(
            checkpointCount: navController.allCheckpoints.count,
            pingCount: navController.routePingTargets.count,
            targetIndex: navController.currentWaypointIndex,
            isNavigating: navController.isNavigating,
            showDots: showCheckpointDots,
            showArrows: showBearingArrows,
            showRings: showGeofenceRings,
            firstLat: navController.allCheckpoints.first?.coordinate.latitude,
            firstLon: navController.allCheckpoints.first?.coordinate.longitude
        )
        if context.coordinator.lastSnapshot != snap {
            context.coordinator.lastSnapshot = snap
            context.coordinator.rebuildOverlays(
                on: mapView,
                checkpoints: navController.allCheckpoints,
                pingTargets: navController.routePingTargets,
                currentIndex: navController.currentWaypointIndex,
                showCheckpointDots: showCheckpointDots,
                showBearingArrows: showBearingArrows,
                showGeofenceRings: showGeofenceRings,
                userCoordinate: locationManager.currentCoordinate
            )
        }
        let hasAnchoredRoute = navController.allCheckpoints.count >= 2
        context.coordinator.throttledFollowUser(
            coordinate: locationManager.currentCoordinate,
            isNavigating: navController.isNavigating,
            hasAnchoredRoute: hasAnchoredRoute
        )
    }

    final class Coordinator: NSObject, GMSMapViewDelegate {
        weak var mapView: GMSMapView?
        var lastSnapshot: RouteDebugMapOverlaySnapshot?
        var appliedOverlayRefreshEpoch: Int = -1
        private var polyline: GMSPolyline?
        private var checkpointOverlays: [GMSOverlay] = []
        private var pingMarkers: [GMSMarker] = []
        private var extraPolylines: [GMSPolyline] = []
        private var circles: [GMSCircle] = []
        private var lastCameraFollowAt: Date = .distantPast
        private var lastCameraCenter: CLLocationCoordinate2D?

        func mapView(_ mapView: GMSMapView, didTap marker: GMSMarker) -> Bool {
            mapView.selectedMarker = marker
            return true
        }

        func rebuildOverlays(
            on mapView: GMSMapView,
            checkpoints cps: [RouteCheckpoint],
            pingTargets pings: [PingTarget],
            currentIndex idx: Int,
            showCheckpointDots: Bool,
            showBearingArrows: Bool,
            showGeofenceRings: Bool,
            userCoordinate: CLLocationCoordinate2D?
        ) {
            clearAll(on: mapView)

            guard cps.count >= 2 else { return }

            let path = GMSMutablePath()
            for cp in cps {
                path.add(cp.coordinate)
            }
            let line = GMSPolyline(path: path)
            line.strokeWidth = 5
            line.strokeColor = UIColor.systemBlue.withAlphaComponent(0.85)
            line.map = mapView
            polyline = line

            if showCheckpointDots {
                for cp in cps {
                    let circle = GMSCircle(position: cp.coordinate, radius: 4)
                    circle.fillColor = UIColor.systemGray.withAlphaComponent(0.5)
                    circle.strokeColor = UIColor.systemGray
                    circle.strokeWidth = 1
                    circle.map = mapView
                    checkpointOverlays.append(circle)
                }
            }

            for (i, target) in pings.enumerated() {
                let marker = GMSMarker(position: target.coordinate)
                if target.isFinalDestination {
                    marker.title = "Goal"
                    marker.icon = RouteDebugMapMarkerImages.goalMarkerImage()
                } else {
                    marker.title = "Stop \(i + 1)"
                    marker.icon = RouteDebugMapMarkerImages.numberedPingImage(number: i + 1)
                }
                marker.snippet = target.instruction
                marker.groundAnchor = CGPoint(x: 0.5, y: 0.5)
                if i < idx {
                    marker.opacity = 0.35
                } else if i == idx {
                    marker.opacity = 1
                } else {
                    marker.opacity = 0.75
                }
                marker.map = mapView
                pingMarkers.append(marker)
            }

            if showBearingArrows {
                for target in pings where !target.isFinalDestination {
                    let tip = RouteGeometry.offsetCoordinate(
                        from: target.coordinate,
                        bearingDegrees: target.bearingAfterTurnDegrees,
                        distanceMeters: 15
                    )
                    let p = GMSMutablePath()
                    p.add(target.coordinate)
                    p.add(tip)
                    let seg = GMSPolyline(path: p)
                    seg.strokeWidth = 3
                    seg.strokeColor = UIColor.systemOrange.withAlphaComponent(0.9)
                    seg.map = mapView
                    extraPolylines.append(seg)
                }
            }

            if showGeofenceRings, idx < pings.count {
                let current = pings[idx]
                let arrival = GMSCircle(position: current.coordinate, radius: NavigationController.arrivalRadiusMeters)
                arrival.strokeColor = UIColor.systemGreen.withAlphaComponent(0.9)
                arrival.fillColor = UIColor.systemGreen.withAlphaComponent(0.12)
                arrival.strokeWidth = 2
                arrival.map = mapView
                circles.append(arrival)

                if let final = pings.last, final.isFinalDestination {
                    let vlm = GMSCircle(position: final.coordinate, radius: NavigationController.vlmHandoffDistanceMeters)
                    vlm.strokeColor = UIColor.systemPurple.withAlphaComponent(0.85)
                    vlm.fillColor = UIColor.clear
                    vlm.strokeWidth = 2
                    vlm.map = mapView
                    circles.append(vlm)
                }

                if let user = userCoordinate {
                    let rr = GMSCircle(position: user, radius: NavigationController.rerouteDistanceMeters)
                    rr.strokeColor = UIColor.systemIndigo.withAlphaComponent(0.6)
                    rr.fillColor = UIColor.clear
                    rr.strokeWidth = 1.5
                    rr.map = mapView
                    circles.append(rr)
                }
            }

            let bounds = GMSCoordinateBounds(path: path)
            let update = GMSCameraUpdate.fit(bounds, withPadding: 60)
            mapView.animate(with: update)
        }

        func clearAll(on mapView: GMSMapView) {
            polyline?.map = nil
            polyline = nil
            for o in checkpointOverlays { o.map = nil }
            checkpointOverlays.removeAll()
            for m in pingMarkers { m.map = nil }
            pingMarkers.removeAll()
            for p in extraPolylines { p.map = nil }
            extraPolylines.removeAll()
            for c in circles { c.map = nil }
            circles.removeAll()
        }

        func throttledFollowUser(coordinate: CLLocationCoordinate2D?, isNavigating: Bool, hasAnchoredRoute: Bool) {
            if isNavigating && hasAnchoredRoute { return }
            guard let coord = coordinate, let mapView else { return }
            let now = Date()
            let interval: TimeInterval = isNavigating ? 2.5 : 4
            if now.timeIntervalSince(lastCameraFollowAt) < interval { return }
            if let prev = lastCameraCenter {
                let d = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
                    .distance(from: CLLocation(latitude: prev.latitude, longitude: prev.longitude))
                if d < 12 { return }
            }
            lastCameraFollowAt = now
            lastCameraCenter = coord
            let camera = GMSCameraUpdate.setTarget(coord, zoom: mapView.camera.zoom)
            mapView.animate(with: camera)
        }
    }
}

// MARK: - Custom marker images (numbered pings + Goal)

private enum RouteDebugMapMarkerImages {
    private static let baseSize: CGFloat = 40

    static func numberedPingImage(number: Int) -> UIImage {
        let label = "\(number)"
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        let size = CGSize(width: baseSize, height: baseSize)
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
            let path = UIBezierPath(ovalIn: rect)
            UIColor.systemBlue.setFill()
            path.fill()
            UIColor.white.setStroke()
            path.lineWidth = 2
            path.stroke()
            let font = UIFont.systemFont(ofSize: number >= 10 ? 14 : 17, weight: .bold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.white
            ]
            let s = NSString(string: label)
            let textSize = s.size(withAttributes: attrs)
            let origin = CGPoint(
                x: (size.width - textSize.width) / 2,
                y: (size.height - textSize.height) / 2
            )
            s.draw(at: origin, withAttributes: attrs)
        }
    }

    static func goalMarkerImage() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        let size = CGSize(width: 52, height: 36)
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 6)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 8)
            UIColor.systemTeal.setFill()
            path.fill()
            UIColor.white.setStroke()
            path.lineWidth = 1.5
            path.stroke()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 13, weight: .bold),
                .foregroundColor: UIColor.white
            ]
            let text = "Goal"
            let s = NSString(string: text)
            let textSize = s.size(withAttributes: attrs)
            let origin = CGPoint(
                x: (size.width - textSize.width) / 2,
                y: (size.height - textSize.height) / 2
            )
            s.draw(at: origin, withAttributes: attrs)
        }
    }
}
