import QtQuick
import qs.Commons

// Moving neon border: a comet (bright head + fading tail) that travels around
// the rounded-rect perimeter. Pure Rectangle rendering — no Shape/Gradient
// fragility. Draws ONLY the comet; the host draws the static thin border so
// this overlay stays fully transparent (a transparent-fill border Rectangle
// here was painting a faint white wash over the host's interior).
Item {
  id: root

  property real radius: 0
  property color neonColor: Color.accent
  property real duration: 4500
  property real baseOpacity: 1.0
  property bool active: true

  property real glowLength: 26
  property real glowThickness: 3
  property int trailCount: 28
  property real trailStep: 0.014
  property real trailAlpha: 0.5
  property real trailLength: 28

  anchors.fill: parent
  visible: width > 0 && height > 0

  property real _t: 0

  NumberAnimation on _t {
    from: 0
    to: 1
    duration: root.duration
    loops: Animation.Infinite
    running: root.active
  }

  // Wrap a perimeter fraction into [0,1) so the tail stays continuous behind
  // the head when the comet crosses the start of the loop.
  function wrapT(f) {
    return ((f % 1) + 1) % 1
  }

  property var _point: root.perimeterPoint(root._t)

  // Comet head.
  Rectangle {
    id: head
    x: root._point.x - root.glowLength / 2
    y: root._point.y - root.glowThickness / 2
    width: root.glowLength
    height: root.glowThickness
    radius: root.glowThickness / 2
    color: Qt.rgba(root.neonColor.r, root.neonColor.g, root.neonColor.b, 0.95)
    transform: Rotation {
      origin.x: root.glowLength / 2
      origin.y: root.glowThickness / 2
      angle: root._point.rot
    }
  }

  // Comet tail: pills behind the head, shrinking and fading out.
  Repeater {
    id: trail
    model: root.trailCount

    delegate: Rectangle {
      required property int index
      readonly property real frac: root.wrapT(root._t - (index + 1) * root.trailStep)
      readonly property var p: root.perimeterPoint(frac)
      readonly property real decay: 1 - index / Math.max(1, root.trailCount)

      x: p.x - width / 2
      y: p.y - height / 2
      width: root.trailLength * (0.4 + 0.6 * decay)
      height: root.glowThickness
      radius: root.glowThickness / 2
      color: Qt.rgba(root.neonColor.r, root.neonColor.g, root.neonColor.b,
                     root.trailAlpha * decay * decay)
      transform: Rotation {
        origin.x: width / 2
        origin.y: height / 2
        angle: p.rot
      }
    }
  }

  opacity: root.baseOpacity
  Behavior on opacity { NumberAnimation { duration: 180 } }

  // Point + tangent angle at fraction [0,1) along the rounded-rect perimeter,
  // starting at the top edge and going clockwise.
  function perimeterPoint(frac) {
    var w = root.width
    var h = root.height
    var r = Math.max(0, Math.min(root.radius, w / 2, h / 2))
    var q = Math.PI / 2 * r
    var ws = Math.max(0, w - 2 * r)
    var hs = Math.max(0, h - 2 * r)
    var per = 2 * ws + 2 * hs + 4 * q
    var d = (((frac % 1) + 1) % 1) * per
    var x = 0, y = 0, rot = 0
    var rad = Math.PI / 180

    if (d < ws) {
      x = r + d; y = 0; rot = 0
    } else if ((d -= ws) < q) {
      var a1 = -90 + (d / q) * 90
      x = (w - r) + r * Math.cos(a1 * rad); y = r + r * Math.sin(a1 * rad); rot = a1 + 90
    } else if ((d -= q) < hs) {
      x = w; y = r + d; rot = 90
    } else if ((d -= hs) < q) {
      var a2 = (d / q) * 90
      x = (w - r) + r * Math.cos(a2 * rad); y = (h - r) + r * Math.sin(a2 * rad); rot = a2 + 90
    } else if ((d -= q) < ws) {
      x = w - r - d; y = h; rot = 180
    } else if ((d -= ws) < q) {
      var a3 = 90 + (d / q) * 90
      x = r + r * Math.cos(a3 * rad); y = (h - r) + r * Math.sin(a3 * rad); rot = a3 + 90
    } else if ((d -= q) < hs) {
      x = 0; y = h - r - d; rot = 270
    } else {
      d -= hs
      var a4 = 180 + (d / q) * 90
      x = r + r * Math.cos(a4 * rad); y = r + r * Math.sin(a4 * rad); rot = a4 + 90
    }
    return { x: x, y: y, rot: rot }
  }
}
