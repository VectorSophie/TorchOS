import QtQuick 2.0;
import calamares.slideshow 1.0;

Presentation {
    id: presentation
    Slide {
        Rectangle { anchors.fill: parent; color: "#2b0a00" }
        Text {
            anchors.centerIn: parent
            horizontalAlignment: Text.AlignHCenter
            color: "#ffffff"; font.pixelSize: 26
            text: "Installing TorchOS\n\nEvery important change gets a snapshot.\nExperiment freely."
        }
    }
}
