import SwiftUI
import TipKit

enum MotionaryTipEvents {
    static let projectPicker = Tips.Event(id: "projectPickerOpened")
    static let previewSelection = Tips.Event(id: "previewObjectSelected")
    static let layerSelection = Tips.Event(id: "layerNameSelected")
    static let effectOpened = Tips.Event(id: "effectOpened")
    static let keyframeEdited = Tips.Event(id: "keyframeEdited")
    static let editorOpened = Tips.Event(id: "editorOpened")
}

struct ProjectOptionsTip: Tip {
    var title: Text { Text("Hold for more project options") }
    var rules: [Rule] {
        #Rule(MotionaryTipEvents.projectPicker) { $0.donations.count >= 2 }
    }
}

struct PreviewGesturesTip: Tip {
    var title: Text { Text("Drag, pinch or rotate here") }
    var rules: [Rule] {
        #Rule(MotionaryTipEvents.previewSelection) { $0.donations.count >= 2 }
    }
}

struct LayerOptionsTip: Tip {
    var title: Text { Text("Hold for options, double-tap to delete") }
    var rules: [Rule] {
        #Rule(MotionaryTipEvents.layerSelection) { $0.donations.count >= 3 }
    }
}

struct EffectOptionsTip: Tip {
    var title: Text { Text("Hold for more options") }
    var rules: [Rule] {
        #Rule(MotionaryTipEvents.effectOpened) { $0.donations.count >= 2 }
    }
}

struct GraphTip: Tip {
    var title: Text { Text("Edit the graph here") }
    var rules: [Rule] {
        #Rule(MotionaryTipEvents.keyframeEdited) { $0.donations.count >= 2 }
    }
}

struct RippleEditingTip: Tip {
    var title: Text { Text("Move later clips with your edits") }
    var rules: [Rule] {
        #Rule(MotionaryTipEvents.editorOpened) { $0.donations.count >= 3 }
    }
}
