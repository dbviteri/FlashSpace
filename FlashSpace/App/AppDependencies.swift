//
//  AppDependencies.swift
//
//  Stripped: only the minimal FocusFillManager is kept.
//

struct AppDependencies {
    static let shared = AppDependencies()

    let focusFillManager = FocusFillManager.shared

    private init() {}
}
