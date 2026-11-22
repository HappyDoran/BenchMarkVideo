//
//  BenchMarkVideoApp.swift
//  BenchMarkVideo
//
//  Created by Doran on 9/4/26.
//

import SwiftUI

/// 앱의 단일 SwiftUI scene을 만들고 최초 화면을 `ContentView`로 연결한다.
@main
struct BenchMarkVideoApp: App {
    var body: some Scene {
        // 앱의 각 window가 공간 스캔의 루트 화면에서 시작하도록 구성한다.
        WindowGroup {
            ContentView()
        }
    }
}
