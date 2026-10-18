//
//  View+Dummy.swift
//  PbUtilities
//
//  Dummyable ships no AppKit/SwiftUI
//  dummies, so `AnyView` needs one here for previews and dummy coordinators/factories.
//

import Dummyable
import SwiftUI

#PublicDummy(of: AnyView.self) {
    AnyView(Text("Dummy View"))
}
