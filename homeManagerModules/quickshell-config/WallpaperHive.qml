import QtQuick
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects
import Quickshell

Item {
  id: hive

  required property var model           
  property string accent: "#7b68ab"     
  property string muted: "#8b8bab"

  signal apply(string file)

  readonly property int cellD: 96
  readonly property double invSqrt2: 0.7071067811865476   
  readonly property double colPitch: cellD                
  readonly property double rowPitch: cellD * 0.55   
  readonly property double offX: cellD / 2

  property var clusterPos: []           
  property int contentW: 0
  property int contentH: 0

  function rebuild() {
    var count = hive.model.count;

    if (count === 0 || hive.width < hive.colPitch) { return; }
    var pts = [];

    var colsPerRow = Math.max(1, Math.floor(hive.width / hive.colPitch));
    
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

    hive.clusterPos = pts;
    
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

    contentWidth: Math.max(hive.width, hive.contentW)
    contentHeight: Math.max(hive.height, hive.contentH)

    Item {
      width: hive.contentW
      height: hive.contentH

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
          
          Component.onCompleted: console.log("tile DEBUG: idx", index, "x=", x, "y=", y)

        Item {
          id: crop
          anchors.centerIn: parent
          width: parent.width
          height: parent.height
          rotation: 45
          scale: hive.invSqrt2
          clip: true

          Image {

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
