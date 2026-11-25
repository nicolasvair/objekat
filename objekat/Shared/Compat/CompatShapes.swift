//
//  CompatShapes.swift
//  objekat
//
//  `UnevenRoundedRectangle` is macOS 13. The compat shape has the same initialiser (four radii and
//  a corner style); on 13+ it IS an `UnevenRoundedRectangle`, below it draws circular arcs.
//  To delete when the deployment target is >= 13.
//

import SwiftUI

struct UnevenRoundedRectangleCompat: Shape {
    var topLeadingRadius: CGFloat
    var bottomLeadingRadius: CGFloat
    var bottomTrailingRadius: CGFloat
    var topTrailingRadius: CGFloat
    var style: RoundedCornerStyle

    init(topLeadingRadius: CGFloat = 0, bottomLeadingRadius: CGFloat = 0,
         bottomTrailingRadius: CGFloat = 0, topTrailingRadius: CGFloat = 0,
         style: RoundedCornerStyle = .continuous) {
        self.topLeadingRadius = topLeadingRadius
        self.bottomLeadingRadius = bottomLeadingRadius
        self.bottomTrailingRadius = bottomTrailingRadius
        self.topTrailingRadius = topTrailingRadius
        self.style = style
    }

    func path(in rect: CGRect) -> Path {
        if #available(macOS 13, *) {
            return UnevenRoundedRectangle(topLeadingRadius: topLeadingRadius,
                                          bottomLeadingRadius: bottomLeadingRadius,
                                          bottomTrailingRadius: bottomTrailingRadius,
                                          topTrailingRadius: topTrailingRadius,
                                          style: style).path(in: rect)
        }
        // Radii clamped so that two neighbours never overlap on an edge.
        let w = rect.width, h = rect.height
        let half = min(w, h) / 2
        let tl = min(max(0, topLeadingRadius), half)
        let bl = min(max(0, bottomLeadingRadius), half)
        let br = min(max(0, bottomTrailingRadius), half)
        let tr = min(max(0, topTrailingRadius), half)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr), radius: tr,
                 startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        p.addArc(center: CGPoint(x: rect.maxX - br, y: rect.maxY - br), radius: br,
                 startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        p.addArc(center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl), radius: bl,
                 startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        p.addArc(center: CGPoint(x: rect.minX + tl, y: rect.minY + tl), radius: tl,
                 startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}
