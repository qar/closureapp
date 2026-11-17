import SwiftUI
import UIKit

/// Move and scale a picked image inside a square, like choosing a contact photo. The
/// image always covers the square, so the result has no empty edges.
struct CoverCropView: View {
    /// Upright, at most 3000 px on the long edge.
    let image: UIImage
    let onChoose: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero

    private static let maxZoom: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width - Theme.horizontalMargin * 2, proxy.size.height * 0.6)
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let geometry = layout(side: side)
            let square = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
            // Image, shade and frame share one coordinate space, so the clear square and
            // the frame line always match.
            ZStack {
                Image(uiImage: image)
                    .resizable()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .position(x: center.x + geometry.offset.width, y: center.y + geometry.offset.height)
                Path { path in
                    path.addRect(CGRect(x: -2000, y: -2000, width: proxy.size.width + 4000, height: proxy.size.height + 4000))
                    path.addRect(square)
                }
                .fill(Theme.paper.opacity(0.88), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
                Rectangle()
                    .stroke(Theme.ink.opacity(0.6), lineWidth: 1)
                    .frame(width: side, height: side)
                    .position(center)
                    .allowsHitTesting(false)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture().updating($drag) { value, state, _ in state = value.translation }
                .onEnded { value in
                    offset = clamp(CGSize(width: offset.width + value.translation.width,
                                          height: offset.height + value.translation.height), side: side, zoom: zoom)
                }
                .simultaneously(with: MagnificationGesture().updating($pinch) { value, state, _ in state = value }
                    .onEnded { value in
                        zoom = min(Self.maxZoom, max(1, zoom * value))
                        offset = clamp(offset, side: side, zoom: zoom)
                    }))
            .overlay(alignment: .top) { topBar(side: side) }
            .overlay(alignment: .bottom) {
                MetaText("Drag to move · pinch to zoom", size: 10).padding(.bottom, 24)
            }
        }
        .background(Theme.paper.ignoresSafeArea())
    }

    private func topBar(side: CGFloat) -> some View {
        HStack {
            Button("Cancel") { dismiss() }
                .font(.system(size: 17))
                .foregroundStyle(Theme.muted)
                .frame(minHeight: 44)
            Spacer()
            MetaText("Move and Scale", size: 10.5, color: Theme.ink)
            Spacer()
            Button("Choose") {
                if let data = crop(side: side) { onChoose(data) }
                dismiss()
            }
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .frame(minHeight: 44)
        }
        .padding(.horizontal, Theme.horizontalMargin)
        .padding(.top, 8)
    }

    // MARK: - Geometry

    /// Points per image pixel at zoom 1: the short edge just fills the square.
    private func baseScale(side: CGFloat) -> CGFloat {
        side / min(image.size.width * image.scale, image.size.height * image.scale)
    }

    private func layout(side: CGFloat) -> (size: CGSize, offset: CGSize) {
        let liveZoom = min(Self.maxZoom, max(1, zoom * pinch))
        let scale = baseScale(side: side) * liveZoom
        let size = CGSize(width: image.size.width * image.scale * scale, height: image.size.height * image.scale * scale)
        let live = clamp(CGSize(width: offset.width + drag.width, height: offset.height + drag.height), side: side, zoom: liveZoom)
        return (size, live)
    }

    /// Keeps the square covered: the image edge never moves inside it.
    private func clamp(_ offset: CGSize, side: CGFloat, zoom: CGFloat) -> CGSize {
        let scale = baseScale(side: side) * zoom
        let width = image.size.width * image.scale * scale, height = image.size.height * image.scale * scale
        let maxX = max(0, (width - side) / 2), maxY = max(0, (height - side) / 2)
        return CGSize(width: min(maxX, max(-maxX, offset.width)), height: min(maxY, max(-maxY, offset.height)))
    }

    /// The part of the image inside the square, as JPEG.
    private func crop(side: CGFloat) -> Data? {
        guard let cgImage = image.cgImage else { return nil }
        let scale = baseScale(side: side) * zoom
        let pixelWidth = CGFloat(cgImage.width), pixelHeight = CGFloat(cgImage.height)
        let edge = side / scale
        let centerX = pixelWidth / 2 - offset.width / scale
        let centerY = pixelHeight / 2 - offset.height / scale
        let rect = CGRect(x: centerX - edge / 2, y: centerY - edge / 2, width: edge, height: edge).integral
            .intersection(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        guard let cropped = cgImage.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped).jpegData(compressionQuality: 0.92)
    }

    /// Redraws a picked image upright (EXIF orientation applied), at most 3000 px.
    static func prepare(_ data: Data) -> UIImage? {
        guard let picked = UIImage(data: data) else { return nil }
        let long = max(picked.size.width, picked.size.height) * picked.scale
        let factor = min(1, 3000 / long)
        let size = CGSize(width: (picked.size.width * picked.scale * factor).rounded(),
                          height: (picked.size.height * picked.scale * factor).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            picked.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
