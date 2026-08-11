//
//  AppLog.swift
//  FormaCapture
//

import os

enum AppLog {
    private static let subsystem = "com.formaprojection.formacapture"

    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
    static let server    = Logger(subsystem: subsystem, category: "server")
    static let render    = Logger(subsystem: subsystem, category: "render")
    static let capture   = Logger(subsystem: subsystem, category: "capture")
    static let encode    = Logger(subsystem: subsystem, category: "encode")
}
