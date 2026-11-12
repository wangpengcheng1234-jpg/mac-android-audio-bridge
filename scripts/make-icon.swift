#!/usr/bin/env swift
// 生成 App 图标：亮青→蔚蓝渐变底 + 白色手机与声波
// 用法：ICON_OUT=assets/icon.png swift scripts/make-icon.swift

import CoreGraphics
import Foundation
import ImageIO

let canvas: CGFloat = 1024
let outputPath = ProcessInfo.processInfo.environment["ICON_OUT"] ?? "assets/icon.png"

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

/// macOS 图标圆角近似：超椭圆 n≈4.6
func squircle(in rect: CGRect, exponent n: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2
    let b = rect.height / 2
    let steps = 1440
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t)
        let st = sin(t)
        let x = rect.midX + a * copysign(pow(abs(ct), 2 / n), ct)
        let y = rect.midY + b * copysign(pow(abs(st), 2 / n), st)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let ctx = CGContext(data: nil,
                          width: Int(canvas), height: Int(canvas),
                          bitsPerComponent: 8, bytesPerRow: 0,
                          space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("无法创建绘图上下文")
}

// 改为左上角原点，便于按设计稿坐标书写
ctx.translateBy(x: 0, y: canvas)
ctx.scaleBy(x: 1, y: -1)
ctx.setAllowsAntialiasing(true)
ctx.interpolationQuality = .high

// 圆角底板
let plate = squircle(in: CGRect(x: 0, y: 0, width: canvas, height: canvas), exponent: 4.6)
ctx.saveGState()
ctx.addPath(plate)
ctx.clip()

// 背景渐变：左上亮青 → 中间天蓝 → 右下宝蓝
let gradient = CGGradient(colorsSpace: space,
                          colors: [rgb(124, 247, 255), rgb(46, 211, 255), rgb(58, 107, 255)] as CFArray,
                          locations: [0, 0.52, 1])!
ctx.drawLinearGradient(gradient,
                       start: CGPoint(x: 60, y: 40),
                       end: CGPoint(x: 980, y: 1000),
                       options: [])

// 左上高光，增加通透感
let sheen = CGGradient(colorsSpace: space,
                       colors: [rgb(255, 255, 255, 0.26), rgb(255, 255, 255, 0)] as CFArray,
                       locations: [0, 1])!
ctx.drawRadialGradient(sheen,
                       startCenter: CGPoint(x: 210, y: 150), startRadius: 0,
                       endCenter: CGPoint(x: 210, y: 150), endRadius: 1150,
                       options: [])

ctx.restoreGState()

// 内描边高光
ctx.saveGState()
ctx.addPath(squircle(in: CGRect(x: 2, y: 2, width: canvas - 4, height: canvas - 4), exponent: 4.6))
ctx.setStrokeColor(rgb(255, 255, 255, 0.35))
ctx.setLineWidth(5)
ctx.strokePath()
ctx.restoreGState()

// 前景：白色手机 + 声波
let dot = rgb(255, 255, 255, 0.98)
let arcColors = [rgb(255, 255, 255, 1.0), rgb(255, 255, 255, 0.96), rgb(255, 255, 255, 0.92)]

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 22,
              color: rgb(12, 40, 110, 0.16))

// 手机外框
let phone = CGPath(roundedRect: CGRect(x: 176, y: 250, width: 306, height: 572),
                   cornerWidth: 66, cornerHeight: 66, transform: nil)
ctx.addPath(phone)
ctx.setStrokeColor(dot)
ctx.setLineWidth(38)
ctx.setLineJoin(.round)
ctx.strokePath()

// 听筒
let earpiece = CGMutablePath()
earpiece.move(to: CGPoint(x: 284, y: 318))
earpiece.addLine(to: CGPoint(x: 374, y: 318))
ctx.addPath(earpiece)
ctx.setLineCap(.round)
ctx.setLineWidth(22)
ctx.strokePath()

// 三道路由声波
let arcCenter = CGPoint(x: 512, y: 536)
let start = -48.0 * .pi / 180
let end = 48.0 * .pi / 180
for (index, radius) in [118.0, 210.0, 302.0].enumerated() {
    ctx.setStrokeColor(arcColors[index])
    ctx.setLineWidth(46)
    ctx.setLineCap(.round)
    ctx.addArc(center: arcCenter, radius: radius,
               startAngle: start, endAngle: end, clockwise: false)
    ctx.strokePath()
}
ctx.restoreGState()

guard let image = ctx.makeImage() else { fatalError("无法生成位图") }
let url = URL(fileURLWithPath: outputPath)
try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
    fatalError("无法写入 \(outputPath)")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("PNG 写入失败") }
print("已生成 \(outputPath)")
