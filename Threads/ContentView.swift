//
//  ContentView.swift
//  Threads
//
//  Created by Anmol  Jandaur on 8/16/26.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    
    var body: some View {
        VStack {
            Text("Hello, World!")
        }
    }

}

#Preview {
    ContentView()
}
