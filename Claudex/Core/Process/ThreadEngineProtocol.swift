//
//  ThreadEngineProtocol.swift
//  Claudex
//
//  Protocol defining the thread engine interface, implemented by both
//  ThreadEngine (original) and ThreadEngineV2 (PTY + proxy).
//

import Foundation

protocol ThreadEngineProtocol: AnyObject {
    var thread: Thread { get }
    var project: Project { get }
    var messages: [Message] { get }
    var state: EngineState { get }
    var currentTokens: Int { get }
    var lastCostUsd: Double { get }
    var currentModel: String { get }

    func start() async throws
    func send(_ userText: String) async throws
    func interrupt()
    func terminate()
}

// Provide default implementations for shared properties
extension ThreadEngineProtocol {
    var currentTokens: Int { 0 }
    var lastCostUsd: Double { 0 }
}
