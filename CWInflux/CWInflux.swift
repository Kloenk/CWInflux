//
//  main.swift
//  CWInflux
//
//  Created by Finn Behrens on 14.03.22.
//

import AppKit
import ArgumentParser
import Foundation
import InfluxDBSwift

@main
struct CWInfluxCommand: AsyncParsableCommand {
    @Option(name: .shortAndLong, help: "The name or id of the bucket destination.")
    var bucket: String

    @Option(name: .shortAndLong, help: "The name or id of the organisation destination.")
    var org: String

    @Option(name: .shortAndLong, help: "Authentication token.")
    var token: String

    @Option(name: .shortAndLong, help: "HTTP address of InfluxDB.")
    var url: String

    func run() async throws {
        _ = try await CWInflux(bucket: bucket, org: org, token: token, url: url)

        await NSApplication.shared.run()
    }
}

enum CWInfluxError: Error {
    case noInterfaceName
}
