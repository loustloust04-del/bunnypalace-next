//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Foundation
import SwiftUI

struct ThematicBreakView: View {

  var body: some View {
    // MP fork：0.5pt 浅薄荷绿 (#8EBD9F @ 0.4) 短横线，左右 padding 48 让线只在中间
    Rectangle()
      .fill(Color(red: 142.0/255.0, green: 189.0/255.0, blue: 159.0/255.0, opacity: 0.4))
      .frame(height: 0.5)
      .padding(.horizontal, 48)
      .padding([.top, .bottom], 12)
      .transition(.opacity)
  }
}
