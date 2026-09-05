import QtQuick
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects
import Quickshell

// WallpaperHive — the Phase 6 diamond wallpaper picker.
//
// Diamond CROP (fixed 08-29, restored from 1977c3e): each thumbnail is cropped
// to a diamond by a rotated+scaled `clip:true` container holding the Image.
// The Image counter-rotates -45° (upright) and is oversized by √2 so it fills
// the diamond's full height.
//
// LATTICE (Gage, 08-29): diamonds laid out in rows where alternating rows are
// OFFSET by half a cell and interlock (sides touching) — a honeycomb/lattice
// instead of a plain grid. Positions are computed explicitly per tile.
//
// ALL colors from the active theme (accent/muted props bound to root.barXxx in
// shell.qml). NO literals, NO gold ring — the active wallpaper is marked with
// the theme accent.
//
// Shared state: a separate component file — colors arrive as properties, the
// apply action as the `onApply` signal.

Item {
  id: hive

  // ---- inputs from shell.qml (bound to root.barXxx palette keys) ----
  required property var model           // ListModel { file, name, isActive }
  property string accent: "#7b68ab"     // theme accent (marks the current)
  property string muted: "#8b8bab"      // theme muted (hover border)

  // ---- emit to apply a wallpaper (shell.qml hides picker + runs wallust-apply) ----
  signal apply(string file)

  // Lattice tuning. cellD = diamond bounding-box size. Diamonds are placed on a
  // grid where the horizontal center spacing = cellD (adjacent row-mates touch
  // corner-to-corner) and the vertical row pitch = cellD/√2 (the diamond's side
  // length) so offset rows interlock with their sides touching.
  readonly property int cellD: 96
  readonly property double invSqrt2: 0.7071067811865476   // 1/√2 for the inscribed diamond
  readonly property double colPitch: cellD                // horizontal center spacing
  readonly property double rowPitch: cellD * 0.55   // vertical row pitch — tuned so offset rows interlock, sides touching (08-29)
  readonly property double offX: cellD / 2                // alternate-row horizontal offset

  // Precomputed cluster geometry (row/col positions), filled on rebuild.
  property var clusterPos: []           // [{x, y}] per model index, row-major
  property int contentW: 0
  property int contentH: 0

  function rebuild() {
    var count = hive.model.count;
    // Guard: if the width isn't resolved yet (< one column), keep the last good
    // positions. A transient width=0 pass would compute colsPerRow=1 and stack
    // every tile into a vertical column (the "snap from vertical" flash on
    // Mod+W, 08-29). Skip instead — the tiles stay put until width is stable.
    if (count === 0 || hive.width < hive.colPitch) { return; }
    var pts = [];   // build in a local array, assign ONCE at the end
    // Place in rows of `colsPerRow`; even rows start at x=0, odd rows offset by
    // offX so they interlock.
    var colsPerRow = Math.max(1, Math.floor(hive.width / hive.colPitch));
    // DEBUG: log the inputs that determine the lattice (is hive.width resolved?).
    console.log("hive DEBUG: width=", hive.width, "colPitch=", hive.colPitch, "-> colsPerRow=", colsPerRow)
    for (var i = 0; i < count; i++) {
      var row = Math.floor(i / colsPerRow);
      var col = i % colsPerRow;
      var x = col * hive.colPitch + (row % 2 === 1 ? hive.offX : 0);
      var y = row * hive.rowPitch;
      pts.push({ x: x, y: y });
    }
    var nrows = Math.ceil(count / colsPerRow);
    hive.contentW = Math.ceil(colsPerRow * hive.colPitch + hive.offX + hive.cellD);
    hive.contentH = Math.ceil(nrows * hive.rowPitch + hive.cellD);
    // Assign the fully-built array ONCE. QML `var` properties do NOT re-notify
    // on in-place mutation (push), so assigning `= []` then pushing leaves the
    // tiles bound to an empty array (all x=0 — the single-diamond regression,
    // 08-29). A single assignment of a populated array fires the change and the
    // tiles' x/y bindings re-evaluate to their real positions.
    hive.clusterPos = pts;
    // DEBUG: what did we actually compute for positions + content size?
    console.log("hive DEBUG: clusterPos.len=", hive.clusterPos.length, "contentW=", hive.contentW,
      "contentH=", hive.contentH, "first3=",
      hive.clusterPos.length > 0 ? hive.clusterPos[0].x + "," + hive.clusterPos[0].y : "none",
      hive.clusterPos.length > 1 ? hive.clusterPos[1].x + "," + hive.clusterPos[1].y : "",
      hive.clusterPos.length > 2 ? hive.clusterPos[2].x + "," + hive.clusterPos[2].y : "")
  }

  onModelChanged: Qt.callLater(hive.rebuild)
  onWidthChanged: Qt.callLater(hive.rebuild)
  Component.onCompleted: Qt.callLater(hive.rebuild)

  Flickable {
    id: flick
    anchors.fill: parent
    clip: true
    boundsBehavior: Flickable.DragAndOvershootBounds
    // Content area is AT LEAST the viewport, so the cluster can sit centered
    // inside it when it's small; when the cluster overflows, it grows past the
    // viewport and the user pans. This is what centers the cluster both ways.
    contentWidth: Math.max(hive.width, hive.contentW)
    contentHeight: Math.max(hive.height, hive.contentH)

    // EXPLICIT content container. A bare Repeater child of Flickable doesn't get
    // a sized contentItem — its delegates collapse to the origin (the
    // "single-diamond" regression, 08-29). Give the content an explicit Item of
    // the cluster size so tile x/y land in a real, sized area.
    Item {
      width: hive.contentW
      height: hive.contentH
      // Center the cluster in the content area by half the leftover on each
      // side. When the cluster overflows the viewport, contentW == viewport and
      // this is 0, so it hugs the top-left and pans instead of drifting.
      x: (flick.contentWidth - hive.contentW) / 2
      y: (flick.contentHeight - hive.contentH) / 2

      Repeater {
        model: hive.model
        delegate: Item {
          id: tile
          width: hive.cellD
          height: hive.cellD
          x: hive.clusterPos.length > index ? hive.clusterPos[index].x : 0
          y: hive.clusterPos.length > index ? hive.clusterPos[index].y : 0
          property bool hovered: false
          // DEBUG: log each tile's assigned position at instantiation.
          Component.onCompleted: console.log("tile DEBUG: idx", index, "x=", x, "y=", y)

        // Diamond crop — restored from 1977c3e: rotated+scaled `clip:true`
        // container (no OpacityMask — that painted a white diamond).
        Item {
          id: crop
          anchors.centerIn: parent
          width: parent.width
          height: parent.height
          rotation: 45
          scale: hive.invSqrt2
          clip: true

          Image {
            // Counter-rotate -45° (upright); oversize by √2 so the container's
            // 1/√2 scale leaves it exactly cellD — filling the diamond's full
            // height edge to edge.
            anchors.centerIn: parent
            width: parent.width / hive.invSqrt2
            height: parent.height / hive.invSqrt2
            rotation: -45
            source: "file://" + model.file
            sourceSize: { width: hive.cellD * 4; height: hive.cellD * 4 }
            fillMode: Image.PreserveAspectCrop
            cache: true
          }
        }
        // Diamond highlight ring. Current = theme accent; hover = accent.
        Rectangle {
          id: ring
          anchors.centerIn: parent
          width: parent.width
          height: parent.height
          rotation: 45
          scale: hive.invSqrt2
          color: "transparent"
          border.width: (model.isActive || tile.hovered) ? 2 : 0
          border.color: model.isActive ? hive.accent : hive.muted
          visible: model.isActive || tile.hovered
        }

        MouseArea {
          id: area
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onEntered: tile.hovered = true
          onExited: tile.hovered = false
          onClicked: hive.apply(model.file)
        }
        }
      }
    }
  }
}
